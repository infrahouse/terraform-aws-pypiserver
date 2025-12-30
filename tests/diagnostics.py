"""
Diagnostic data collection for PyPI server stress tests.

This module collects real-time metrics from EC2 instances during stress tests
to help diagnose performance bottlenecks.
"""

import json
import time
from dataclasses import dataclass, asdict, field
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional

from infrahouse_core.aws.asg import ASG

from tests.conftest import LOG


@dataclass
class InstanceDiagnostics:
    """Diagnostics collected from a single EC2 instance."""

    instance_id: str
    timestamp: str

    # Container metrics (from docker stats)
    container_stats: Optional[str] = None

    # Memory metrics (from free -m)
    memory_stats: Optional[str] = None

    # CPU and load (from top)
    cpu_stats: Optional[str] = None

    # Disk I/O (from iostat)
    io_stats: Optional[str] = None

    # ECS task count (from docker ps)
    task_count: Optional[int] = None

    # Any errors during collection
    errors: List[str] = field(default_factory=list)


@dataclass
class ClusterDiagnostics:
    """Diagnostics collected from entire ECS cluster."""

    timestamp: str
    iteration: int
    is_burst: bool
    worker_count: int
    instances: List[InstanceDiagnostics]


class DiagnosticsCollector:
    """Collects diagnostic data from EC2 instances during stress tests."""

    def __init__(
        self, asg_name: str, region: str, role_arn: str = None, output_dir: Path = None
    ):
        """
        Initialize diagnostics collector.

        :param asg_name: Name of the Auto Scaling Group
        :type asg_name: str
        :param region: AWS region
        :type region: str
        :param role_arn: Optional IAM role ARN to assume
        :type role_arn: str
        :param output_dir: Directory to write diagnostics (required for multiprocessing)
        :type output_dir: Path
        """
        self.asg_name = asg_name
        self.region = region
        self.role_arn = role_arn
        self.output_dir = output_dir
        self.diagnostics: List[ClusterDiagnostics] = []

    def collect_snapshot(
        self, iteration: int, is_burst: bool, worker_count: int
    ) -> ClusterDiagnostics:
        """
        Collect diagnostic snapshot from all instances in the ASG.

        When output_dir is set, writes snapshot directly to disk (for multiprocessing).
        Otherwise, appends to self.diagnostics list.

        :param iteration: Current test iteration number
        :type iteration: int
        :param is_burst: Whether this is a burst iteration
        :type is_burst: bool
        :param worker_count: Number of concurrent workers in this iteration
        :type worker_count: int
        :returns: ClusterDiagnostics with data from all instances
        :rtype: ClusterDiagnostics
        """
        # Lazy-initialize ASG (needed for multiprocessing - can't pickle boto3 clients)
        asg = ASG(asg_name=self.asg_name, region=self.region, role_arn=self.role_arn)

        timestamp = datetime.now().isoformat()
        instances_diagnostics = []

        LOG.info(f"Collecting diagnostics from {len(asg.instances)} instances...")

        for instance in asg.instances:
            instance_diag = self._collect_instance_diagnostics(instance)
            instances_diagnostics.append(instance_diag)

        cluster_diag = ClusterDiagnostics(
            timestamp=timestamp,
            iteration=iteration,
            is_burst=is_burst,
            worker_count=worker_count,
            instances=instances_diagnostics,
        )

        # If output_dir is set, write immediately to disk (for multiprocessing)
        if self.output_dir:
            self._write_snapshot_to_disk(cluster_diag)
        else:
            # Otherwise, collect in memory
            self.diagnostics.append(cluster_diag)

        return cluster_diag

    def _collect_instance_diagnostics(self, instance) -> InstanceDiagnostics:
        """
        Collect diagnostics from a single EC2 instance.

        :param instance: ASGInstance object
        :returns: InstanceDiagnostics with collected metrics
        :rtype: InstanceDiagnostics
        """
        diag = InstanceDiagnostics(
            instance_id=instance.instance_id,
            timestamp=datetime.now().isoformat(),
        )

        # Collect container stats (let real errors propagate)
        _, stdout, stderr = instance.execute_command(
            "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'",
            execution_timeout=30,
        )
        diag.container_stats = stdout.strip() if stdout else None
        if stderr:
            diag.errors.append(f"docker stats stderr: {stderr}")

        # Count running tasks (let real errors propagate)
        _, stdout, _ = instance.execute_command(
            "docker ps --filter 'name=ecs-' -q | wc -l",
            execution_timeout=10,
        )
        diag.task_count = int(stdout.strip()) if stdout.strip() else 0

        # Collect memory stats (let real errors propagate)
        _, stdout, stderr = instance.execute_command(
            "free -m",
            execution_timeout=10,
        )
        diag.memory_stats = stdout.strip() if stdout else None
        if stderr:
            diag.errors.append(f"free stderr: {stderr}")

        # Collect CPU stats and load average (let real errors propagate)
        _, stdout, stderr = instance.execute_command(
            "top -bn1 | head -n 20",
            execution_timeout=10,
        )
        diag.cpu_stats = stdout.strip() if stdout else None
        if stderr:
            diag.errors.append(f"top stderr: {stderr}")

        # Collect disk I/O stats - ONLY catch if iostat not installed
        try:
            _, stdout, stderr = instance.execute_command(
                "iostat -x 1 2 | tail -n +4",
                execution_timeout=15,
            )
            diag.io_stats = stdout.strip() if stdout else None
            if stderr and "command not found" not in stderr:
                diag.errors.append(f"iostat stderr: {stderr}")
        except Exception as e:
            # Only acceptable if iostat not installed
            if "command not found" in str(e) or "No such file" in str(e):
                LOG.debug(f"iostat not available on {instance.instance_id}")
            else:
                raise  # Re-raise unexpected errors

        return diag

    def _write_snapshot_to_disk(self, cluster_diag: ClusterDiagnostics):
        """
        Write a single diagnostic snapshot to disk immediately.

        Used when running in multiprocessing mode to avoid memory sharing issues.

        :param cluster_diag: Cluster diagnostics to write
        :type cluster_diag: ClusterDiagnostics
        """
        self.output_dir.mkdir(parents=True, exist_ok=True)

        # Write individual snapshot file
        snapshot_file = (
            self.output_dir
            / f"diagnostics_iter{cluster_diag.iteration}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        )
        with open(snapshot_file, "w") as f:
            json.dump(asdict(cluster_diag), f, indent=2)

        LOG.info(f"✓ Diagnostics snapshot written: {snapshot_file.name}")

    def save_diagnostics(self, output_dir: Path):
        """
        Save collected diagnostics to files.

        If diagnostics were written to individual snapshot files (multiprocessing mode),
        consolidates them into a single report.

        :param output_dir: Directory to save diagnostics
        :type output_dir: Path
        """
        output_dir.mkdir(parents=True, exist_ok=True)

        # Check for individual snapshot files (written by child processes)
        snapshot_files = sorted(output_dir.glob("diagnostics_iter*.json"))

        if snapshot_files:
            # Load snapshots from files
            LOG.info(f"Loading {len(snapshot_files)} diagnostic snapshots from disk...")
            diagnostics_list = []
            for snapshot_file in snapshot_files:
                with open(snapshot_file, "r") as f:
                    snapshot_data = json.load(f)
                    # Reconstruct ClusterDiagnostics from dict
                    diagnostics_list.append(snapshot_data)
        elif self.diagnostics:
            # Use in-memory diagnostics
            diagnostics_list = [asdict(d) for d in self.diagnostics]
        else:
            LOG.warning("No diagnostics to save")
            return

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

        # Save consolidated JSON
        json_path = output_dir / f"diagnostics_{timestamp}.json"
        with open(json_path, "w") as f:
            json.dump(diagnostics_list, f, indent=2)

        # Save Markdown summary
        md_path = output_dir / f"diagnostics_{timestamp}.md"
        with open(md_path, "w") as f:
            f.write(f"# Diagnostics Report\n\n")
            f.write(f"**Generated**: {datetime.now().isoformat()}\n\n")
            f.write(f"**Total Snapshots**: {len(diagnostics_list)}\n\n")

            for cluster_diag in diagnostics_list:
                # Handle both dict and ClusterDiagnostics objects
                iteration = (
                    cluster_diag["iteration"]
                    if isinstance(cluster_diag, dict)
                    else cluster_diag.iteration
                )
                timestamp_str = (
                    cluster_diag["timestamp"]
                    if isinstance(cluster_diag, dict)
                    else cluster_diag.timestamp
                )
                is_burst = (
                    cluster_diag["is_burst"]
                    if isinstance(cluster_diag, dict)
                    else cluster_diag.is_burst
                )
                worker_count = (
                    cluster_diag["worker_count"]
                    if isinstance(cluster_diag, dict)
                    else cluster_diag.worker_count
                )
                instances = (
                    cluster_diag["instances"]
                    if isinstance(cluster_diag, dict)
                    else cluster_diag.instances
                )

                f.write(f"\n## Iteration {iteration}\n\n")
                f.write(f"- **Timestamp**: {timestamp_str}\n")
                f.write(f"- **Burst**: {'Yes' if is_burst else 'No'}\n")
                f.write(f"- **Workers**: {worker_count}\n")
                f.write(f"- **Instances**: {len(instances)}\n\n")

                for inst_diag in instances:
                    # Handle dict or InstanceDiagnostics object
                    if isinstance(inst_diag, dict):
                        instance_id = inst_diag["instance_id"]
                        task_count = inst_diag.get("task_count")
                        errors = inst_diag.get("errors", [])
                        container_stats = inst_diag.get("container_stats")
                        memory_stats = inst_diag.get("memory_stats")
                        cpu_stats = inst_diag.get("cpu_stats")
                        io_stats = inst_diag.get("io_stats")
                    else:
                        instance_id = inst_diag.instance_id
                        task_count = inst_diag.task_count
                        errors = inst_diag.errors
                        container_stats = inst_diag.container_stats
                        memory_stats = inst_diag.memory_stats
                        cpu_stats = inst_diag.cpu_stats
                        io_stats = inst_diag.io_stats

                    f.write(f"### Instance: {instance_id}\n\n")

                    if task_count is not None:
                        f.write(f"**Running Tasks**: {task_count}\n\n")

                    if errors:
                        f.write(f"**Errors**: {len(errors)}\n")
                        for err in errors:
                            f.write(f"- {err}\n")
                        f.write("\n")

                    if container_stats:
                        f.write(
                            f"**Container Stats**:\n```\n{container_stats}\n```\n\n"
                        )

                    if memory_stats:
                        f.write(f"**Memory**:\n```\n{memory_stats}\n```\n\n")

                    if cpu_stats:
                        f.write(f"**CPU & Load**:\n```\n{cpu_stats}\n```\n\n")

                    if io_stats:
                        f.write(f"**Disk I/O**:\n```\n{io_stats}\n```\n\n")

        LOG.info(f"Diagnostics saved:")
        LOG.info(f"  JSON: {json_path}")
        LOG.info(f"  Markdown: {md_path}")
