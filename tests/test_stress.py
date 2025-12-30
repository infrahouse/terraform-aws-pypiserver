"""
Pytest integration tests for stress testing.

These tests use the stress_test module to run load tests against
a deployed PyPI server.

Usage:
    make test-keep  # First, create PyPI server infrastructure
    make stress     # Then run stress tests

Requirements:
    - PyPI server must be deployed via terraform (use make test-keep first)
    - Test packages will be uploaded automatically
"""

import time
from os import path as osp
from pathlib import Path

import json
import pytest
from pytest_infrahouse import terraform_apply

from tests.conftest import LOG
from tests.diagnostics import DiagnosticsCollector
from tests.alb_diagnostics import ALBDiagnosticsCollector
from tests.stress_test import run_stress_test, save_results, TEST_PROFILES


@pytest.fixture
def results_dir():
    """Create directory for test results."""
    results = Path("tests/results")
    results.mkdir(exist_ok=True)
    return results


def log_stress_test_results(results, test_name: str, extra_notes: str = None):
    """
    Print formatted stress test results summary.

    :param results: StressTestResults object
    :param test_name: Name of the test (e.g., "Production Incident Simulation")
    :param extra_notes: Optional additional notes to display (e.g., upload conflict info)
    """
    LOG.info("\n" + "=" * 70)
    LOG.info(f"STRESS TEST RESULTS: {test_name}")
    LOG.info("=" * 70)
    LOG.info(f"Total Requests:     {results.total_requests}")
    LOG.info(
        f"Successful:         {results.successful_requests} ({100 * (1 - results.error_rate):.1f}%)"
    )
    LOG.info(
        f"Failed:             {results.failed_requests} ({100 * results.error_rate:.1f}%)"
    )
    LOG.info(f"Error Rate:         {100 * results.error_rate:.2f}%")
    LOG.info(f"\nLatency (P95):      {results.latency_p95:.2f} ms")
    LOG.info(f"Latency (P99):      {results.latency_p99:.2f} ms")
    LOG.info(f"Latency (Mean):     {results.latency_mean:.2f} ms")
    LOG.info(f"\n5xx Errors:         {results.error_5xx_count}")
    LOG.info(f"4xx Errors:         {results.error_4xx_count}")
    if extra_notes:
        LOG.info(f"  {extra_notes}")
    LOG.info(f"\nThroughput:         {results.requests_per_second:.2f} req/s")
    LOG.info("=" * 70)


def test_stress_production_incident(
    keep_after,
    results_dir,
    test_packages,
    upload_packages_to_pypi,
    aws_region,
    test_role_arn,
    boto3_session,
):
    """
    Reproduce production incident with stress test.

    This test:
    1. Connects to existing PyPI server (from make test-keep)
    2. Uploads test packages (300 wheels)
    3. Runs production incident simulation with diagnostics collection
    4. Validates performance criteria

    Performance Baseline (2 × c6a.xlarge, round_robin algorithm):
        - Error Rate: 0.05% (target: <1%)
        - P95 Latency: 14 seconds (target: <15s)
        - P99 Latency: 20 seconds
        - Throughput: 20 req/s
        - 5xx Errors: 3 (target: <10)

    Limitations:
        - High latency due to HTTP keep-alive connection stickiness
        - Round-robin distributes connections at establishment, not ongoing requests
        - Burst of 510 simultaneous requests often concentrates on one instance
        - Python + EFS + simple-dir (no caching) inherently slow

    Architecture Note:
        - Success achieved with "fewer, beefier instances" strategy
        - 2 × c6a.xlarge (4 vCPU each) provides enough headroom to absorb
          uneven load distribution without errors
        - Fewer ALB targets (6 vs 12) reduces statistical variance in distribution

    Workflow:
        make test-keep  # Create PyPI server infrastructure
        make stress     # Run this stress test
    """
    terraform_module_dir = osp.join("test_data", "pypiserver")

    # Connect to existing PyPI server infrastructure
    with terraform_apply(
        terraform_module_dir,
        destroy_after=not keep_after,
        json_output=True,
        enable_trace=False,
    ) as tf_output:

        LOG.info(json.dumps(tf_output, indent=4))

        # # TEMPORARY: Pause for manual experimentation
        # input("Press Enter to continue with stress test...")

        # Extract credentials and infrastructure details from terraform outputs
        pypi_url = tf_output["pypi_server_urls"]["value"][0]
        username = tf_output["pypi_username"]["value"]
        password = tf_output["pypi_password"]["value"]
        asg_name = tf_output["asg_name"]["value"]

        LOG.info("=" * 70)
        LOG.info("STRESS TEST: Production Incident Simulation")
        LOG.info("=" * 70)
        LOG.info(f"PyPI URL: {pypi_url}")
        LOG.info(f"ASG Name: {asg_name}")
        LOG.info(f"Test packages: {len(test_packages)} wheels")

        # Upload test packages
        LOG.info("\nUploading test packages...")
        num_uploaded = upload_packages_to_pypi(
            pypi_url=pypi_url,
            username=username,
            password=password,
        )

        LOG.info(f"✓ Uploaded {num_uploaded} test packages")

        # Wait a bit for indexing
        time.sleep(5)

        # Clean up old diagnostic snapshots from previous test runs
        for old_snapshot in results_dir.glob("diagnostics_iter*.json"):
            old_snapshot.unlink()
            LOG.debug(f"Cleaned up old EC2 snapshot: {old_snapshot.name}")

        for old_snapshot in results_dir.glob("alb_diagnostics_iter*.json"):
            old_snapshot.unlink()
            LOG.debug(f"Cleaned up old ALB snapshot: {old_snapshot.name}")

        # Initialize EC2 diagnostics collector
        diagnostics_collector = DiagnosticsCollector(
            asg_name=asg_name,
            region=aws_region,
            role_arn=test_role_arn,
            output_dir=results_dir,
        )

        # Initialize ALB/ECS diagnostics collector
        alb_diagnostics_collector = ALBDiagnosticsCollector(
            cluster_name=tf_output["ecs_cluster_name"]["value"],
            service_name=tf_output["ecs_service_name"]["value"],
            load_balancer_arn=tf_output["pypi_load_balancer_arn"]["value"],
            region=aws_region,
            boto3_session=boto3_session,
            output_dir=results_dir,
        )

        # Collect baseline infrastructure state BEFORE test
        LOG.info("\n" + "=" * 70)
        LOG.info("PRE-TEST INFRASTRUCTURE VALIDATION")
        LOG.info("=" * 70)

        alb_diagnostics_collector.collect_snapshot(
            iteration=-1,  # Special iteration number for baseline
            is_burst=False,
            worker_count=0,
        )

        # Wait a moment for collection to complete
        time.sleep(2)

        # Load and display the baseline snapshot
        baseline_snapshots = sorted(results_dir.glob("alb_diagnostics_iter-1_*.json"))
        if baseline_snapshots:
            with open(baseline_snapshots[0], "r") as f:
                baseline = json.load(f)

            LOG.info(
                f"ECS Service: {baseline['cluster_name']}/{baseline['service_name']}"
            )
            LOG.info(
                f"  Desired: {baseline['desired_count']}, Running: {baseline['running_count']}, Pending: {baseline['pending_count']}"
            )

            # Count targets by health state
            healthy = sum(1 for t in baseline["targets"] if t["state"] == "healthy")
            unhealthy = sum(1 for t in baseline["targets"] if t["state"] == "unhealthy")
            other = sum(
                1
                for t in baseline["targets"]
                if t["state"] not in ["healthy", "unhealthy"]
            )

            LOG.info(f"ALB Targets: {len(baseline['targets'])} total")
            LOG.info(f"  Healthy: {healthy}, Unhealthy: {unhealthy}, Other: {other}")
            LOG.info(f"ALB Algorithm: {baseline['load_balancer_algorithm']}")

            # Count tasks per instance
            from collections import Counter

            instance_counts = Counter(t["ec2_instance_id"] for t in baseline["tasks"])
            LOG.info(f"Task Distribution: {dict(instance_counts)}")

            # Validate everything is ready
            if baseline["running_count"] != baseline["desired_count"]:
                LOG.warning(
                    f"⚠️  Service not stable: {baseline['running_count']}/{baseline['desired_count']} running"
                )

            if unhealthy > 0:
                LOG.warning(f"⚠️  {unhealthy} unhealthy targets detected!")

            if baseline["pending_count"] > 0:
                LOG.warning(f"⚠️  {baseline['pending_count']} tasks pending")

            if (
                healthy == len(baseline["targets"])
                and baseline["running_count"] == baseline["desired_count"]
            ):
                LOG.info("✅ Infrastructure is healthy and ready for stress test")

        LOG.info("=" * 70 + "\n")

        # Run stress test
        profile_config = TEST_PROFILES["production_incident"]

        LOG.info(f"\nRunning stress test: production_incident")
        LOG.info(
            f"  Duration: {profile_config['test_duration_seconds']}s ({profile_config['test_duration_seconds'] // 60} min)"
        )
        LOG.info(f"  Concurrent clients: {profile_config['concurrent_clients']}")
        LOG.info(f"  Burst multiplier: {profile_config['burst_multiplier']}x\n")

        results = run_stress_test(
            profile="production_incident",
            pypi_url=pypi_url,
            username=username,
            password=password,
            diagnostics_collector=diagnostics_collector,
            alb_diagnostics_collector=alb_diagnostics_collector,
            **profile_config,
        )

        # Save results and diagnostics
        save_results(results, results_dir)
        diagnostics_collector.save_diagnostics(results_dir)
        alb_diagnostics_collector.save_diagnostics(results_dir)

        # Print summary
        log_stress_test_results(results, "Production Incident Simulation")

        # Assertions (success criteria based on baseline: 2 × c6a.xlarge, round_robin)
        assert (
            results.error_rate < 0.01
        ), f"Error rate {100 * results.error_rate:.2f}% exceeds 1%"
        assert (
            results.latency_p95 < 15000
        ), f"P95 latency {results.latency_p95:.2f}ms exceeds 15000ms (15s)"
        assert (
            results.error_5xx_count < 10
        ), f"Found {results.error_5xx_count} 5xx errors (threshold: <10)"

        LOG.info("\n✅ All performance criteria met!")


def test_stress_production_incident_with_uploads(
    keep_after,
    results_dir,
    test_packages,
    upload_packages_to_pypi,
):
    """
    Reproduce production incident with mixed upload/download workload.

    This test simulates the actual production incident where there was a mix
    of uploads and downloads happening simultaneously. The uploads trigger
    EFS write I/O which causes high iowait (84% in production).

    This test:
    1. Connects to existing PyPI server (from make test-keep)
    2. Uploads test packages (300 wheels)
    3. Runs production incident simulation with 30% uploads, 70% downloads
    4. Validates performance criteria

    Expected to FAIL on baseline (t3.micro + 128 MB) with high iowait.
    Expected to PASS on optimized configuration.

    Workflow:
        make test-keep  # Create PyPI server infrastructure
        pytest -xvvs --keep-after -k "test_stress_production_incident_with_uploads" tests/test_stress.py
    """
    terraform_module_dir = osp.join("test_data", "pypiserver")

    # Connect to existing PyPI server infrastructure
    with terraform_apply(
        terraform_module_dir,
        destroy_after=not keep_after,
        json_output=True,
        enable_trace=False,
    ) as tf_output:
        LOG.info(json.dumps(tf_output, indent=4))

        # Extract credentials from terraform outputs
        pypi_url = tf_output["pypi_server_urls"]["value"][0]
        username = tf_output["pypi_username"]["value"]
        password = tf_output["pypi_password"]["value"]

        LOG.info("=" * 70)
        LOG.info("STRESS TEST: Production Incident with Uploads")
        LOG.info("=" * 70)
        LOG.info(f"PyPI URL: {pypi_url}")
        LOG.info(f"Test packages: {len(test_packages)} wheels")

        # Upload test packages
        LOG.info("\nUploading test packages...")
        num_uploaded = upload_packages_to_pypi(
            pypi_url=pypi_url,
            username=username,
            password=password,
        )

        LOG.info(f"✓ Uploaded {num_uploaded} test packages")

        # Wait a bit for indexing
        time.sleep(5)

        # Run stress test with uploads
        profile_config = TEST_PROFILES["production_incident_with_uploads"]

        LOG.info(f"\nRunning stress test: production_incident_with_uploads")
        LOG.info(
            f"  Duration: {profile_config['test_duration_seconds']}s ({profile_config['test_duration_seconds'] // 60} min)"
        )
        LOG.info(f"  Concurrent clients: {profile_config['concurrent_clients']}")
        LOG.info(f"  Burst multiplier: {profile_config['burst_multiplier']}x")
        LOG.info(
            f"  Upload ratio: {profile_config['upload_ratio']:.0%} (reproduces high iowait)\n"
        )

        results = run_stress_test(
            profile="production_incident_with_uploads",
            pypi_url=pypi_url,
            username=username,
            password=password,
            package_paths=test_packages,  # Required for upload operations
            **profile_config,
        )

        # Save results
        save_results(results, results_dir)

        # Print summary
        log_stress_test_results(
            results,
            "Production Incident with Uploads",
            extra_notes="(Note: 409 Conflict is expected for upload tests)",
        )

        # Assertions (success criteria from plan)
        assert (
            results.error_rate < 0.01
        ), f"Error rate {100 * results.error_rate:.2f}% exceeds 1%"
        assert (
            results.latency_p95 < 2000
        ), f"P95 latency {results.latency_p95:.2f}ms exceeds 2000ms"
        assert (
            results.error_5xx_count == 0
        ), f"Found {results.error_5xx_count} 5xx errors"

        LOG.info("\n✅ All performance criteria met!")


def test_stress_light_load(
    keep_after, results_dir, test_packages, upload_packages_to_pypi
):
    """
    Light load test - quick smoke test.

    This is a shorter, lighter test for quick validation.
    Should pass even on minimal configuration.

    Workflow:
        make test-keep  # Create PyPI server infrastructure
        make stress     # Run this stress test
    """
    terraform_module_dir = osp.join("test_data", "pypiserver")

    with terraform_apply(
        terraform_module_dir,
        destroy_after=not keep_after,
        json_output=True,
        enable_trace=False,
    ) as tf_output:
        # Extract credentials from terraform outputs
        pypi_url = tf_output["pypi_server_urls"]["value"][0]
        username = tf_output["pypi_username"]["value"]
        password = tf_output["pypi_password"]["value"]

        # Upload test packages
        LOG.info("\nUploading test packages...")
        num_uploaded = upload_packages_to_pypi(
            pypi_url=pypi_url,
            username=username,
            password=password,
        )

        LOG.info(f"✓ Uploaded {num_uploaded} test packages")

        # Wait a bit for indexing
        time.sleep(5)

        profile_config = TEST_PROFILES["light_load"]

        LOG.info(f"\nRunning stress test: light_load")
        LOG.info(f"  Duration: {profile_config['test_duration_seconds']}s")
        LOG.info(f"  Concurrent clients: {profile_config['concurrent_clients']}\n")

        results = run_stress_test(
            profile="light_load",
            pypi_url=pypi_url,
            username=username,
            password=password,
            **profile_config,
        )

        save_results(results, results_dir)

        LOG.info(f"\n✓ Light load test complete")
        LOG.info(f"  Error rate: {100 * results.error_rate:.2f}%")
        LOG.info(f"  P95 latency: {results.latency_p95:.2f} ms")

        # Lighter criteria for quick test
        assert (
            results.error_rate < 0.05
        ), f"Error rate {100 * results.error_rate:.2f}% exceeds 5%"
        assert (
            results.error_5xx_count == 0
        ), f"Found {results.error_5xx_count} 5xx errors"


def test_stress_heavy_load(
    keep_after, results_dir, test_packages, upload_packages_to_pypi
):
    """
    Heavy load test - validates performance under extreme load.

    This test should only be run on optimized configuration.
    Expected to fail on baseline configuration.

    Workflow:
        make test-keep  # Create PyPI server infrastructure
        make stress     # Run this stress test
    """
    terraform_module_dir = osp.join("test_data", "pypiserver")

    with terraform_apply(
        terraform_module_dir,
        destroy_after=not keep_after,
        json_output=True,
        enable_trace=False,
    ) as tf_output:
        # Extract credentials from terraform outputs
        pypi_url = tf_output["pypi_server_urls"]["value"][0]
        username = tf_output["pypi_username"]["value"]
        password = tf_output["pypi_password"]["value"]

        # Upload test packages
        LOG.info("\nUploading test packages...")
        num_uploaded = upload_packages_to_pypi(
            pypi_url=pypi_url,
            username=username,
            password=password,
        )

        LOG.info(f"✓ Uploaded {num_uploaded} test packages")

        # Wait a bit for indexing
        time.sleep(5)

        profile_config = TEST_PROFILES["heavy_load"]

        LOG.info(f"\nRunning stress test: heavy_load")
        LOG.info(f"  Duration: {profile_config['test_duration_seconds']}s")
        LOG.info(f"  Concurrent clients: {profile_config['concurrent_clients']}")
        LOG.info(f"  Burst multiplier: {profile_config['burst_multiplier']}x\n")

        results = run_stress_test(
            profile="heavy_load",
            pypi_url=pypi_url,
            username=username,
            password=password,
            **profile_config,
        )

        save_results(results, results_dir)

        LOG.info(f"\n✓ Heavy load test complete")
        LOG.info(f"  Error rate: {100 * results.error_rate:.2f}%")
        LOG.info(f"  P95 latency: {results.latency_p95:.2f} ms")

        # Stricter criteria for heavy load
        assert (
            results.error_rate < 0.02
        ), f"Error rate {100 * results.error_rate:.2f}% exceeds 2%"
        assert (
            results.latency_p95 < 3000
        ), f"P95 latency {results.latency_p95:.2f}ms exceeds 3000ms"
        assert (
            results.error_5xx_count == 0
        ), f"Found {results.error_5xx_count} 5xx errors"
