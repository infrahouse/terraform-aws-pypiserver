"""Diagnostics for ALB and ECS service state during stress tests."""

import logging
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any
import json

LOG = logging.getLogger(__name__)


@dataclass
class TargetHealth:
    """Health status of a single ALB target."""

    target_id: str  # IP:port
    target_type: str  # ip or instance
    port: int
    availability_zone: str
    state: str  # initial, healthy, unhealthy, unused, draining, unavailable
    reason: str  # Optional reason code
    description: str  # Optional description


@dataclass
class TaskPlacement:
    """ECS task placement information."""

    task_arn: str
    container_instance_arn: str
    ec2_instance_id: str
    availability_zone: str
    last_status: str  # RUNNING, PENDING, etc.
    health_status: str  # HEALTHY, UNHEALTHY, UNKNOWN
    cpu_reserved: int
    memory_reserved: int


@dataclass
class ALBSnapshot:
    """Snapshot of ALB and ECS state at a point in time."""

    timestamp: str
    iteration: int
    is_burst: bool
    worker_count: int

    # ALB data
    target_group_arn: str
    load_balancer_algorithm: str
    deregistration_delay: int
    slow_start_duration: int
    targets: List[TargetHealth]

    # ECS data
    cluster_name: str
    service_name: str
    desired_count: int
    running_count: int
    pending_count: int
    tasks: List[TaskPlacement]


class ALBDiagnosticsCollector:
    """Collects ALB target health and ECS task placement during stress tests."""

    def __init__(
        self,
        cluster_name: str,
        service_name: str,
        load_balancer_arn: str,
        region: str,
        boto3_session,
        output_dir: Path = None,
    ):
        self.cluster_name = cluster_name
        self.service_name = service_name
        self.load_balancer_arn = load_balancer_arn
        self.region = region
        self.output_dir = output_dir
        self.snapshots: List[ALBSnapshot] = []
        self.target_group_arn = None  # Will be discovered from load balancer

        # Initialize clients
        self.elbv2 = boto3_session.client("elbv2", region_name=region)
        self.ecs = boto3_session.client("ecs", region_name=region)
        self.ec2 = boto3_session.client("ec2", region_name=region)

    def _discover_target_group_arn(self):
        """Discover target group ARN from load balancer ARN."""
        if self.target_group_arn:
            return  # Already discovered

        LOG.debug(
            f"Discovering target group ARN from load balancer: {self.load_balancer_arn}"
        )

        # List all target groups for this load balancer
        response = self.elbv2.describe_target_groups(
            LoadBalancerArn=self.load_balancer_arn
        )

        if not response["TargetGroups"]:
            raise ValueError(
                f"No target groups found for load balancer {self.load_balancer_arn}"
            )

        # Use the first target group (typically there's only one for pypiserver)
        self.target_group_arn = response["TargetGroups"][0]["TargetGroupArn"]
        LOG.debug(f"Discovered target group ARN: {self.target_group_arn}")

    def collect_snapshot(self, iteration: int, is_burst: bool, worker_count: int):
        """Collect a snapshot of ALB and ECS state."""
        LOG.info(f"Collecting ALB/ECS diagnostics (iteration {iteration})...")

        try:
            # Discover target group ARN if not already known
            self._discover_target_group_arn()

            # Get target group attributes
            tg_attrs = self._get_target_group_attributes()

            # Get target health
            targets = self._get_target_health()

            # Get ECS service info
            service_info = self._get_service_info()

            # Get task placement
            tasks = self._get_task_placement()

            # Get load balancer algorithm
            lb_algorithm = self._get_load_balancer_algorithm()

            snapshot = ALBSnapshot(
                timestamp=datetime.now().isoformat(),
                iteration=iteration,
                is_burst=is_burst,
                worker_count=worker_count,
                target_group_arn=self.target_group_arn,
                load_balancer_algorithm=lb_algorithm,
                deregistration_delay=tg_attrs["deregistration_delay"],
                slow_start_duration=tg_attrs["slow_start_duration"],
                targets=targets,
                cluster_name=self.cluster_name,
                service_name=self.service_name,
                desired_count=service_info["desired"],
                running_count=service_info["running"],
                pending_count=service_info["pending"],
                tasks=tasks,
            )

            # If output_dir is set, write immediately to disk (for multiprocessing)
            if self.output_dir:
                self._write_snapshot_to_disk(snapshot)
            else:
                self.snapshots.append(snapshot)

            LOG.info(
                f"✓ ALB/ECS diagnostics collected: {len(targets)} targets, {len(tasks)} tasks"
            )

        except Exception as e:
            LOG.error(f"Failed to collect ALB/ECS diagnostics: {e}", exc_info=True)

    def _get_target_group_attributes(self) -> Dict[str, Any]:
        """Get target group configuration attributes."""
        response = self.elbv2.describe_target_group_attributes(
            TargetGroupArn=self.target_group_arn
        )

        attrs = {attr["Key"]: attr["Value"] for attr in response["Attributes"]}

        return {
            "deregistration_delay": int(
                attrs.get("deregistration_delay.timeout_seconds", 300)
            ),
            "slow_start_duration": int(attrs.get("slow_start.duration_seconds", 0)),
        }

    def _get_load_balancer_algorithm(self) -> str:
        """Get the load balancing algorithm (round_robin or least_outstanding_requests)."""
        try:
            # Get target groups for this ALB
            response = self.elbv2.describe_target_groups(
                TargetGroupArns=[self.target_group_arn]
            )

            if response["TargetGroups"]:
                tg = response["TargetGroups"][0]
                # Get load balancer ARN from target group
                if tg.get("LoadBalancerArns"):
                    lb_arn = tg["LoadBalancerArns"][0]

                    # Get attributes
                    attrs_response = self.elbv2.describe_target_group_attributes(
                        TargetGroupArn=self.target_group_arn
                    )

                    for attr in attrs_response["Attributes"]:
                        if attr["Key"] == "load_balancing.algorithm.type":
                            return attr["Value"]

            return "round_robin"  # Default

        except Exception as e:
            LOG.warning(f"Could not determine load balancing algorithm: {e}")
            return "unknown"

    def _get_target_health(self) -> List[TargetHealth]:
        """Get health status of all targets in the target group."""
        response = self.elbv2.describe_target_health(
            TargetGroupArn=self.target_group_arn
        )

        targets = []
        for target_health in response["TargetHealthDescriptions"]:
            target = target_health["Target"]
            health = target_health["TargetHealth"]

            targets.append(
                TargetHealth(
                    target_id=f"{target['Id']}:{target['Port']}",
                    target_type="ip" if target["Id"].count(".") == 3 else "instance",
                    port=target["Port"],
                    availability_zone=target.get("AvailabilityZone", "unknown"),
                    state=health["State"],
                    reason=health.get("Reason", ""),
                    description=health.get("Description", ""),
                )
            )

        return targets

    def _get_service_info(self) -> Dict[str, int]:
        """Get ECS service task counts."""
        response = self.ecs.describe_services(
            cluster=self.cluster_name, services=[self.service_name]
        )

        if not response["services"]:
            raise ValueError(
                f"Service {self.service_name} not found in cluster {self.cluster_name}"
            )

        service = response["services"][0]

        return {
            "desired": service["desiredCount"],
            "running": service["runningCount"],
            "pending": service["pendingCount"],
        }

    def _get_task_placement(self) -> List[TaskPlacement]:
        """Get placement of all tasks in the service."""
        # List all tasks
        task_arns = []
        paginator = self.ecs.get_paginator("list_tasks")

        for page in paginator.paginate(
            cluster=self.cluster_name, serviceName=self.service_name
        ):
            task_arns.extend(page["taskArns"])

        if not task_arns:
            return []

        # Describe tasks
        response = self.ecs.describe_tasks(cluster=self.cluster_name, tasks=task_arns)

        # Get container instance details
        container_instance_arns = list(
            set(
                task["containerInstanceArn"]
                for task in response["tasks"]
                if "containerInstanceArn" in task
            )
        )

        instance_map = {}
        if container_instance_arns:
            ci_response = self.ecs.describe_container_instances(
                cluster=self.cluster_name, containerInstances=container_instance_arns
            )

            instance_map = {
                ci["containerInstanceArn"]: ci["ec2InstanceId"]
                for ci in ci_response["containerInstances"]
            }

        # Build task placement list
        tasks = []
        for task in response["tasks"]:
            container_instance_arn = task.get("containerInstanceArn", "unknown")
            ec2_instance_id = instance_map.get(container_instance_arn, "unknown")

            # Calculate reserved resources
            cpu_reserved = 0
            memory_reserved = 0

            if "containers" in task:
                for container in task["containers"]:
                    if (
                        container["name"] == "pypiserver"
                    ):  # Only count pypiserver containers
                        cpu_reserved = int(task.get("cpu", 0))
                        memory_reserved = int(task.get("memory", 0))
                        break

            tasks.append(
                TaskPlacement(
                    task_arn=task["taskArn"].split("/")[-1],  # Short ARN
                    container_instance_arn=container_instance_arn.split("/")[-1],
                    ec2_instance_id=ec2_instance_id,
                    availability_zone=task.get("availabilityZone", "unknown"),
                    last_status=task.get("lastStatus", "UNKNOWN"),
                    health_status=task.get("healthStatus", "UNKNOWN"),
                    cpu_reserved=cpu_reserved,
                    memory_reserved=memory_reserved,
                )
            )

        return tasks

    def _write_snapshot_to_disk(self, snapshot: ALBSnapshot):
        """Write a single snapshot to disk."""
        self.output_dir.mkdir(parents=True, exist_ok=True)

        snapshot_file = (
            self.output_dir
            / f"alb_diagnostics_iter{snapshot.iteration}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        )

        with open(snapshot_file, "w") as f:
            json.dump(asdict(snapshot), f, indent=2)

        LOG.info(f"✓ ALB/ECS snapshot written: {snapshot_file.name}")

    def save_diagnostics(self, output_dir: Path):
        """Save consolidated diagnostics to JSON and Markdown files."""
        # Check for individual snapshot files (written by child processes)
        snapshot_files = sorted(output_dir.glob("alb_diagnostics_iter*.json"))

        diagnostics_list = []

        if snapshot_files:
            LOG.info(f"Loading {len(snapshot_files)} ALB/ECS snapshots from disk...")
            for snapshot_file in snapshot_files:
                with open(snapshot_file, "r") as f:
                    diagnostics_list.append(json.load(f))
        else:
            # Use in-memory snapshots
            diagnostics_list = [asdict(s) for s in self.snapshots]

        if not diagnostics_list:
            LOG.warning("No ALB/ECS diagnostics to save")
            return

        # Save JSON
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        json_file = output_dir / f"alb_diagnostics_{timestamp}.json"

        consolidated = {
            "generated": datetime.now().isoformat(),
            "total_snapshots": len(diagnostics_list),
            "snapshots": diagnostics_list,
        }

        with open(json_file, "w") as f:
            json.dump(consolidated, f, indent=2)

        # Save Markdown
        md_file = output_dir / f"alb_diagnostics_{timestamp}.md"
        self._save_markdown(md_file, consolidated)

        LOG.info(f"ALB/ECS diagnostics saved:")
        LOG.info(f"  JSON: {json_file}")
        LOG.info(f"  Markdown: {md_file}")

    def _save_markdown(self, md_file: Path, data: Dict):
        """Save diagnostics as a readable Markdown report."""
        with open(md_file, "w") as f:
            f.write("# ALB and ECS Diagnostics Report\n\n")
            f.write(f"**Generated**: {data['generated']}\n\n")
            f.write(f"**Total Snapshots**: {data['total_snapshots']}\n\n")

            for snapshot in data["snapshots"]:
                f.write(f"\n## Iteration {snapshot['iteration']}\n\n")
                f.write(f"- **Timestamp**: {snapshot['timestamp']}\n")
                f.write(f"- **Burst**: {snapshot['is_burst']}\n")
                f.write(f"- **Workers**: {snapshot['worker_count']}\n\n")

                # ALB Configuration
                f.write("### ALB Configuration\n\n")
                f.write(f"- **Algorithm**: {snapshot['load_balancer_algorithm']}\n")
                f.write(
                    f"- **Deregistration Delay**: {snapshot['deregistration_delay']}s\n"
                )
                f.write(
                    f"- **Slow Start Duration**: {snapshot['slow_start_duration']}s\n\n"
                )

                # Target Health
                f.write("### Target Health\n\n")
                f.write(f"**Total Targets**: {len(snapshot['targets'])}\n\n")

                # Group by state
                healthy = [t for t in snapshot["targets"] if t["state"] == "healthy"]
                unhealthy = [
                    t for t in snapshot["targets"] if t["state"] == "unhealthy"
                ]
                draining = [t for t in snapshot["targets"] if t["state"] == "draining"]
                other = [
                    t
                    for t in snapshot["targets"]
                    if t["state"] not in ["healthy", "unhealthy", "draining"]
                ]

                f.write(f"- **Healthy**: {len(healthy)}\n")
                f.write(f"- **Unhealthy**: {len(unhealthy)}\n")
                f.write(f"- **Draining**: {len(draining)}\n")
                f.write(f"- **Other**: {len(other)}\n\n")

                if unhealthy or draining or other:
                    f.write("**Non-Healthy Targets**:\n```\n")
                    for target in unhealthy + draining + other:
                        f.write(
                            f"{target['target_id']} - {target['state']} - {target['reason']} - {target['description']}\n"
                        )
                    f.write("```\n\n")

                # ECS Service
                f.write("### ECS Service\n\n")
                f.write(f"- **Cluster**: {snapshot['cluster_name']}\n")
                f.write(f"- **Service**: {snapshot['service_name']}\n")
                f.write(f"- **Desired**: {snapshot['desired_count']}\n")
                f.write(f"- **Running**: {snapshot['running_count']}\n")
                f.write(f"- **Pending**: {snapshot['pending_count']}\n\n")

                # Task Placement
                f.write("### Task Placement\n\n")
                f.write(f"**Total Tasks**: {len(snapshot['tasks'])}\n\n")

                # Group by instance
                from collections import Counter

                instance_counts = Counter(
                    t["ec2_instance_id"] for t in snapshot["tasks"]
                )

                f.write("**Tasks per Instance**:\n```\n")
                for instance_id, count in sorted(instance_counts.items()):
                    f.write(f"{instance_id}: {count} tasks\n")
                f.write("```\n\n")

                # Show task details
                f.write("**Task Details**:\n```\n")
                for task in snapshot["tasks"]:
                    f.write(
                        f"{task['task_arn'][:12]}... - {task['ec2_instance_id']} - "
                        f"{task['last_status']} - {task['health_status']} - "
                        f"CPU:{task['cpu_reserved']} MEM:{task['memory_reserved']}\n"
                    )
                f.write("```\n\n")
