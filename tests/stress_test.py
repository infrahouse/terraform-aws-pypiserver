"""
Stress testing for PyPI server.

This module provides load testing capabilities to simulate concurrent
pip/poetry operations and measure performance under load.

Usage:
    As pytest: pytest tests/test_stress.py -v
    Standalone: python tests/stress_test.py --profile production_incident
"""

import json
import logging
import multiprocessing
import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional
from urllib.parse import urljoin

import requests
from requests.auth import HTTPBasicAuth

from tests.conftest import LOG


@dataclass
class RequestMetrics:
    """Metrics for a single request."""

    timestamp: float
    operation: str  # 'list_packages', 'get_package', 'download_wheel'
    package_name: Optional[str]
    latency_ms: float
    status_code: int
    success: bool
    error: Optional[str] = None
    error_detail: Optional[str] = None  # Full error message/response body
    url: Optional[str] = None  # Request URL for debugging


@dataclass
class StressTestResults:
    """Aggregated results from a stress test run."""

    profile: str
    start_time: str
    end_time: str
    duration_seconds: float
    total_requests: int
    successful_requests: int
    failed_requests: int
    error_rate: float

    # Latency metrics (milliseconds)
    latency_min: float
    latency_max: float
    latency_mean: float
    latency_median: float
    latency_p95: float
    latency_p99: float

    # Throughput
    requests_per_second: float

    # Error breakdown
    status_code_counts: Dict[int, int]
    error_5xx_count: int
    error_4xx_count: int

    # Per-operation metrics
    operations: Dict[str, dict]

    # Error samples for debugging (first 10 unique errors)
    error_samples: List[Dict[str, any]] = None


class PyPIStressTest:
    """Load testing client for PyPI server."""

    def __init__(
        self,
        pypi_url: str,
        username: str,
        password: str,
        timeout: int = 30,
        max_pool_connections: int = 300,
    ):
        """
        Initialize stress test client.

        :param pypi_url: Base URL of PyPI server
        :type pypi_url: str
        :param username: Authentication username
        :type username: str
        :param password: Authentication password
        :type password: str
        :param timeout: Request timeout in seconds
        :type timeout: int
        :param max_pool_connections: Maximum connection pool size
        :type max_pool_connections: int
        """
        self.pypi_url = pypi_url.rstrip("/")
        self.auth = HTTPBasicAuth(username, password)
        self.timeout = timeout

        # Configure session with larger connection pool for high concurrency
        self.session = requests.Session()
        self.session.auth = self.auth

        # Increase connection pool size to handle concurrent requests
        adapter = requests.adapters.HTTPAdapter(
            pool_connections=max_pool_connections,
            pool_maxsize=max_pool_connections,
            max_retries=0,
        )
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

        # Metrics storage
        self.metrics: List[RequestMetrics] = []

    def _make_request(
        self, method: str, path: str, operation: str, package_name: Optional[str] = None
    ) -> RequestMetrics:
        """
        Make HTTP request and record metrics.

        :param method: HTTP method (GET, POST, etc.)
        :type method: str
        :param path: URL path
        :type path: str
        :param operation: Operation name for metrics
        :type operation: str
        :param package_name: Optional package name
        :type package_name: Optional[str]
        :returns: RequestMetrics object
        :rtype: RequestMetrics
        """
        url = urljoin(self.pypi_url, path)
        start = time.time()

        try:
            response = self.session.request(
                method=method, url=url, timeout=self.timeout
            )
            latency_ms = (time.time() - start) * 1000

            success = response.status_code < 400
            error = None if success else response.reason
            error_detail = None

            if not success:
                # Capture response body for failed requests (limit to 1000 chars)
                try:
                    error_detail = response.text[:1000]
                except:
                    error_detail = f"Could not read response body"

            return RequestMetrics(
                timestamp=start,
                operation=operation,
                package_name=package_name,
                latency_ms=latency_ms,
                status_code=response.status_code,
                success=success,
                error=error,
                error_detail=error_detail,
                url=url,
            )

        except Exception as e:
            latency_ms = (time.time() - start) * 1000
            import traceback

            error_detail = f"{type(e).__name__}: {str(e)}\n{traceback.format_exc()}"

            return RequestMetrics(
                timestamp=start,
                operation=operation,
                package_name=package_name,
                latency_ms=latency_ms,
                status_code=0,
                success=False,
                error=str(e),
                error_detail=error_detail,
                url=url,
            )

    def list_all_packages(self) -> RequestMetrics:
        """List all packages (hits /simple/)."""
        return self._make_request("GET", "/simple/", "list_packages")

    def get_package_info(self, package_name: str) -> RequestMetrics:
        """Get package information (hits /simple/<package>/)."""
        return self._make_request(
            "GET", f"/simple/{package_name}/", "get_package", package_name
        )

    def download_wheel(self, package_name: str, version: str) -> RequestMetrics:
        """Download wheel file."""
        wheel_name = f"{package_name.replace('-', '_')}-{version}-py3-none-any.whl"
        return self._make_request(
            "GET", f"/packages/{wheel_name}", "download_wheel", package_name
        )

    def upload_package(self, package_path: str) -> RequestMetrics:
        """
        Simulate package upload (POST request).

        This will attempt to upload a package that already exists,
        triggering write I/O on EFS and getting 409 Conflict response.
        This simulates the production incident upload storm.

        :param package_path: Path to wheel file to upload
        :type package_path: str
        :returns: RequestMetrics object
        :rtype: RequestMetrics
        """
        from pathlib import Path

        wheel_file = Path(package_path)
        url = urljoin(self.pypi_url, "/")
        start = time.time()

        try:
            # Prepare multipart form data for upload
            with open(wheel_file, "rb") as f:
                files = {"content": (wheel_file.name, f, "application/octet-stream")}
                response = self.session.post(url, files=files, timeout=self.timeout)

            latency_ms = (time.time() - start) * 1000

            # 409 Conflict is "success" for this test - means server processed upload
            # Only real failures are timeouts, 500s, etc.
            success = response.status_code < 500
            error = None if success else response.reason
            error_detail = None

            if not success:
                try:
                    error_detail = response.text[:1000]
                except:
                    error_detail = "Could not read response body"

            return RequestMetrics(
                timestamp=start,
                operation="upload_package",
                package_name=wheel_file.stem,
                latency_ms=latency_ms,
                status_code=response.status_code,
                success=success,
                error=error,
                error_detail=error_detail,
                url=url,
            )

        except Exception as e:
            latency_ms = (time.time() - start) * 1000
            import traceback

            error_detail = f"{type(e).__name__}: {str(e)}\n{traceback.format_exc()}"

            return RequestMetrics(
                timestamp=start,
                operation="upload_package",
                package_name=wheel_file.stem,
                latency_ms=latency_ms,
                status_code=0,
                success=False,
                error=str(e),
                error_detail=error_detail,
                url=url,
            )

    def simulate_pip_install(self, package_name: str) -> List[RequestMetrics]:
        """
        Simulate a pip install operation.

        This mimics what real pip does, including the redirect behavior:
        1. Try /{package}/ first (gets 303 redirect)
        2. Follow redirect to /simple/{package}/ (gets 200)
        3. Download wheel

        This matches actual pip behavior observed in production logs.

        :param package_name: Name of the package to install
        :type package_name: str
        :returns: List of RequestMetrics for each step
        :rtype: List[RequestMetrics]
        """
        results = []

        # Step 1: Try package without /simple/ prefix (triggers 303 redirect)
        # This is what pip does first before trying the canonical path
        results.append(
            self._make_request(
                "GET", f"/{package_name}/", "get_package_redirect", package_name
            )
        )

        # Step 2: Get package info from canonical path (after following redirect)
        results.append(self.get_package_info(package_name))

        # Step 3: Download wheel (assume latest version for simplicity)
        # In real scenario, pip would parse HTML and choose version
        results.append(self.download_wheel(package_name, "2.0.0"))

        return results

    def run_concurrent_operations(
        self, operation_func, args_list: List[tuple], max_workers: int = 10
    ) -> List[RequestMetrics]:
        """
        Run operations concurrently.

        :param operation_func: Function to call (e.g., self.get_package_info)
        :param args_list: List of argument tuples for each call
        :type args_list: List[tuple]
        :param max_workers: Maximum concurrent workers
        :type max_workers: int
        :returns: List of all RequestMetrics
        :rtype: List[RequestMetrics]
        """
        results = []

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = [executor.submit(operation_func, *args) for args in args_list]

            for future in as_completed(futures):
                try:
                    result = future.result()
                    if isinstance(result, list):
                        results.extend(result)
                    else:
                        results.append(result)
                except Exception as e:
                    LOG.error(f"Operation failed: {e}")

        return results


def run_stress_test(
    pypi_url: str,
    username: str,
    password: str,
    profile: str = "production_incident",
    num_packages: int = 100,
    concurrent_clients: int = 10,
    test_duration_seconds: int = 1440,  # 24 minutes
    burst_interval_seconds: Optional[int] = None,
    burst_multiplier: float = 1.0,
    upload_ratio: float = 0.0,
    package_paths: Optional[List[Path]] = None,
    diagnostics_collector=None,
    alb_diagnostics_collector=None,
) -> StressTestResults:
    """
    Run stress test with specified profile.

    :param pypi_url: PyPI server URL
    :type pypi_url: str
    :param username: Auth username
    :type username: str
    :param password: Auth password
    :type password: str
    :param profile: Test profile name
    :type profile: str
    :param num_packages: Number of packages to test against
    :type num_packages: int
    :param concurrent_clients: Number of concurrent operations
    :type concurrent_clients: int
    :param test_duration_seconds: How long to run test
    :type test_duration_seconds: int
    :param burst_interval_seconds: Interval for burst spikes (None = no bursts)
    :type burst_interval_seconds: Optional[int]
    :param burst_multiplier: Multiplier for burst load
    :type burst_multiplier: float
    :param upload_ratio: Ratio of uploads to total operations (0.0=all downloads, 1.0=all uploads, 0.3=30% uploads)
    :type upload_ratio: float
    :param package_paths: List of package paths for upload testing
    :type package_paths: Optional[List[Path]]
    :returns: StressTestResults with aggregated metrics
    :rtype: StressTestResults
    """
    # Calculate maximum workers needed (for burst scenarios)
    # Add 20% headroom to avoid pool exhaustion
    max_workers = int(concurrent_clients * burst_multiplier * 1.2)

    client = PyPIStressTest(
        pypi_url, username, password, max_pool_connections=max_workers
    )

    LOG.info(
        f"Starting stress test: profile={profile}, duration={test_duration_seconds}s"
    )
    LOG.info(f"Concurrent clients: {concurrent_clients}, packages: {num_packages}")
    LOG.info(
        f"Connection pool size: {max_workers} (for {int(concurrent_clients * burst_multiplier)} burst workers)"
    )
    LOG.info(
        f"Upload ratio: {upload_ratio:.0%} uploads, {(1-upload_ratio):.0%} downloads"
    )

    start_time = datetime.now()
    all_metrics: List[RequestMetrics] = []

    # Generate package names to test
    package_names = [f"test-package-{i:03d}" for i in range(num_packages)]

    # Simulate load for duration
    elapsed = 0
    iteration = 0

    while elapsed < test_duration_seconds:
        iteration_start = time.time()

        # Determine if this is a burst interval
        is_burst = (
            burst_interval_seconds and iteration % (burst_interval_seconds // 10) == 0
        )
        workers = (
            int(concurrent_clients * burst_multiplier)
            if is_burst
            else concurrent_clients
        )

        # Calculate current error rate for progress tracking
        total_so_far = len(all_metrics)
        failed_so_far = sum(1 for m in all_metrics if not m.success)
        error_rate_pct = (100 * failed_so_far / total_so_far) if total_so_far > 0 else 0

        LOG.info(
            f"Iteration {iteration}: workers={workers}, elapsed={elapsed:.1f}s, "
            f"error_rate={error_rate_pct:.1f}% ({failed_so_far}/{total_so_far})"
        )

        # Start diagnostics collection in background process during burst
        # Use Process instead of Thread because signal.signal() doesn't work in threads
        diagnostics_process = None
        alb_diagnostics_process = None

        if is_burst and diagnostics_collector:
            LOG.info(
                f"🔍 Starting EC2 diagnostics collection in background (workers={workers})..."
            )
            diagnostics_process = multiprocessing.Process(
                target=diagnostics_collector.collect_snapshot,
                args=(iteration, is_burst, workers),
                daemon=True,
                name=f"diagnostics-iter{iteration}",
            )
            diagnostics_process.start()

        if is_burst and alb_diagnostics_collector:
            LOG.info(
                f"🔍 Starting ALB/ECS diagnostics collection in background (workers={workers})..."
            )
            alb_diagnostics_process = multiprocessing.Process(
                target=alb_diagnostics_collector.collect_snapshot,
                args=(iteration, is_burst, workers),
                daemon=True,
                name=f"alb-diagnostics-iter{iteration}",
            )
            alb_diagnostics_process.start()

        # Mix of download and upload operations based on upload_ratio
        import random

        # Determine how many uploads vs downloads
        num_uploads = int(workers * upload_ratio)
        num_downloads = workers - num_uploads

        metrics = []

        # Download operations (pip install simulation)
        if num_downloads > 0:
            download_ops = [
                (random.choice(package_names),) for _ in range(num_downloads)
            ]
            download_metrics = client.run_concurrent_operations(
                client.simulate_pip_install, download_ops, max_workers=num_downloads
            )
            metrics.extend(download_metrics)

        # Upload operations (package publish simulation)
        if num_uploads > 0 and package_paths:
            upload_ops = [
                (str(random.choice(package_paths)),) for _ in range(num_uploads)
            ]
            upload_metrics = client.run_concurrent_operations(
                client.upload_package, upload_ops, max_workers=num_uploads
            )
            metrics.extend(upload_metrics)

        all_metrics.extend(metrics)

        # Wait for diagnostics collection to complete if running
        if diagnostics_process and diagnostics_process.is_alive():
            LOG.info("Waiting for EC2 diagnostics collection to complete...")
            diagnostics_process.join(timeout=120)  # 2 minute max
            if diagnostics_process.is_alive():
                LOG.warning("EC2 diagnostics collection timed out after 120s")
            else:
                LOG.info("✓ EC2 diagnostics collection completed")

        if alb_diagnostics_process and alb_diagnostics_process.is_alive():
            LOG.info("Waiting for ALB/ECS diagnostics collection to complete...")
            alb_diagnostics_process.join(timeout=30)  # 30 second max (faster than EC2)
            if alb_diagnostics_process.is_alive():
                LOG.warning("ALB/ECS diagnostics collection timed out after 30s")
            else:
                LOG.info("✓ ALB/ECS diagnostics collection completed")

        # Sleep to simulate real-world pacing (10-second intervals)
        iteration_time = int(time.time() - iteration_start)
        sleep_time = max(0, 10 - iteration_time)
        time.sleep(sleep_time)

        elapsed = time.time() - start_time.timestamp()
        iteration += 1

    end_time = datetime.now()

    # Aggregate results
    return _aggregate_metrics(
        profile=profile, start_time=start_time, end_time=end_time, metrics=all_metrics
    )


def _aggregate_metrics(
    profile: str,
    start_time: datetime,
    end_time: datetime,
    metrics: List[RequestMetrics],
) -> StressTestResults:
    """
    Aggregate metrics into results.

    :param profile: Test profile name
    :type profile: str
    :param start_time: Test start time
    :type start_time: datetime
    :param end_time: Test end time
    :type end_time: datetime
    :param metrics: List of request metrics collected during test
    :type metrics: List[RequestMetrics]
    :returns: Aggregated test results
    :rtype: StressTestResults
    """
    duration = (end_time - start_time).total_seconds()

    total = len(metrics)
    successful = sum(1 for m in metrics if m.success)
    failed = total - successful

    # Latency stats (only for successful requests)
    successful_latencies = [m.latency_ms for m in metrics if m.success]

    if successful_latencies:
        sorted_latencies = sorted(successful_latencies)
        latency_min = min(successful_latencies)
        latency_max = max(successful_latencies)
        latency_mean = statistics.mean(successful_latencies)
        latency_median = statistics.median(successful_latencies)
        latency_p95 = sorted_latencies[int(len(sorted_latencies) * 0.95)]
        latency_p99 = sorted_latencies[int(len(sorted_latencies) * 0.99)]
    else:
        latency_min = latency_max = latency_mean = latency_median = 0
        latency_p95 = latency_p99 = 0

    # Status code counts
    status_codes = {}
    for m in metrics:
        status_codes[m.status_code] = status_codes.get(m.status_code, 0) + 1

    # Error counts
    error_5xx = sum(1 for m in metrics if 500 <= m.status_code < 600)
    error_4xx = sum(1 for m in metrics if 400 <= m.status_code < 500)

    # Per-operation breakdown
    operations = {}
    for op_name in set(m.operation for m in metrics):
        op_metrics = [m for m in metrics if m.operation == op_name]
        op_latencies = [m.latency_ms for m in op_metrics if m.success]

        operations[op_name] = {
            "count": len(op_metrics),
            "success_rate": sum(1 for m in op_metrics if m.success) / len(op_metrics),
            "mean_latency_ms": statistics.mean(op_latencies) if op_latencies else 0,
            "p95_latency_ms": (
                sorted(op_latencies)[int(len(op_latencies) * 0.95)]
                if op_latencies
                else 0
            ),
        }

    # Collect error samples (first 20 failures with details)
    error_samples = []
    failed_metrics = [m for m in metrics if not m.success]
    for m in failed_metrics[:20]:  # Limit to first 20 errors
        error_samples.append(
            {
                "timestamp": datetime.fromtimestamp(m.timestamp).isoformat(),
                "operation": m.operation,
                "package_name": m.package_name,
                "url": m.url,
                "status_code": m.status_code,
                "error": m.error,
                "error_detail": m.error_detail,
            }
        )

    return StressTestResults(
        profile=profile,
        start_time=start_time.isoformat(),
        end_time=end_time.isoformat(),
        duration_seconds=duration,
        total_requests=total,
        successful_requests=successful,
        failed_requests=failed,
        error_rate=failed / total if total > 0 else 0,
        latency_min=latency_min,
        latency_max=latency_max,
        latency_mean=latency_mean,
        latency_median=latency_median,
        latency_p95=latency_p95,
        latency_p99=latency_p99,
        requests_per_second=total / duration if duration > 0 else 0,
        status_code_counts=status_codes,
        error_5xx_count=error_5xx,
        error_4xx_count=error_4xx,
        operations=operations,
        error_samples=error_samples,
    )


def save_results(results: StressTestResults, output_dir: Path):
    """
    Save test results to files.

    :param results: Stress test results to save
    :type results: StressTestResults
    :param output_dir: Directory to save results in
    :type output_dir: Path
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    # Save JSON
    json_path = output_dir / f"stress_test_{timestamp}.json"
    with open(json_path, "w") as f:
        json.dump(asdict(results), f, indent=2)

    # Save Markdown summary
    md_path = output_dir / f"stress_test_{timestamp}.md"
    with open(md_path, "w") as f:
        f.write(f"# Stress Test Results: {results.profile}\n\n")
        f.write(f"**Date**: {results.start_time}\n\n")
        f.write(f"**Duration**: {results.duration_seconds:.1f}s\n\n")
        f.write(f"## Summary\n\n")
        f.write(f"- Total Requests: {results.total_requests}\n")
        f.write(
            f"- Successful: {results.successful_requests} ({100 * (1 - results.error_rate):.1f}%)\n"
        )
        f.write(
            f"- Failed: {results.failed_requests} ({100 * results.error_rate:.1f}%)\n"
        )
        f.write(f"- Throughput: {results.requests_per_second:.2f} req/s\n\n")

        f.write(f"## Latency (ms)\n\n")
        f.write(f"- Min: {results.latency_min:.2f}\n")
        f.write(f"- Mean: {results.latency_mean:.2f}\n")
        f.write(f"- Median: {results.latency_median:.2f}\n")
        f.write(f"- P95: {results.latency_p95:.2f}\n")
        f.write(f"- P99: {results.latency_p99:.2f}\n")
        f.write(f"- Max: {results.latency_max:.2f}\n\n")

        f.write(f"## Errors\n\n")
        f.write(f"- 5xx errors: {results.error_5xx_count}\n")
        f.write(f"- 4xx errors: {results.error_4xx_count}\n\n")

        f.write(f"## Per-Operation Metrics\n\n")
        for op_name, op_stats in results.operations.items():
            f.write(f"### {op_name}\n\n")
            f.write(f"- Count: {op_stats['count']}\n")
            f.write(f"- Success Rate: {100 * op_stats['success_rate']:.1f}%\n")
            f.write(f"- Mean Latency: {op_stats['mean_latency_ms']:.2f} ms\n")
            f.write(f"- P95 Latency: {op_stats['p95_latency_ms']:.2f} ms\n\n")

        # Write error samples for debugging
        if results.error_samples:
            f.write(
                f"## Error Samples (First {len(results.error_samples)} Failures)\n\n"
            )
            f.write(
                f"These are the first failed requests with full details for debugging.\n\n"
            )

            for i, err in enumerate(results.error_samples, 1):
                f.write(f"### Error {i}\n\n")
                f.write(f"- **Timestamp**: {err['timestamp']}\n")
                f.write(f"- **Operation**: {err['operation']}\n")
                if err["package_name"]:
                    f.write(f"- **Package**: {err['package_name']}\n")
                f.write(f"- **URL**: `{err['url']}`\n")
                f.write(f"- **Status Code**: {err['status_code']}\n")
                f.write(f"- **Error**: {err['error']}\n\n")
                if err["error_detail"]:
                    f.write(f"**Error Details**:\n```\n{err['error_detail']}\n```\n\n")

    LOG.info(f"Results saved to {output_dir}")
    LOG.info(f"  JSON: {json_path}")
    LOG.info(f"  Markdown: {md_path}")


# Pre-defined test profiles
TEST_PROFILES = {
    "production_incident": {
        "num_packages": 100,
        "concurrent_clients": 3,  # Baseline: ~54 req/min (low continuous load)
        # "test_duration_seconds": 1440,  # 24 minutes
        "test_duration_seconds": 300,  # 5 minutes - only for active development
        "burst_interval_seconds": 60,  # Burst every 60 seconds
        "burst_multiplier": 170.0,  # Peak spike: 3 × 170 = 510 workers (doubled to exhaust memory and trigger swap)
        "upload_ratio": 0.0,  # Read-only workload (no uploads, just downloads)
    },
    "production_incident_with_uploads": {
        "num_packages": 100,
        "concurrent_clients": 3,
        "test_duration_seconds": 1440,  # 24 minutes
        "burst_interval_seconds": 60,  # Burst every 60 seconds
        "burst_multiplier": 85.0,  # Peak spike: 255 concurrent operations
        "upload_ratio": 0.3,  # Mixed workload: 30% uploads, 70% downloads (reproduces high iowait)
    },
    "upload_storm": {
        "num_packages": 100,
        "concurrent_clients": 3,  # Baseline: ~18 req/min (uploads slower than downloads)
        "test_duration_seconds": 1440,  # 24 minutes
        "burst_interval_seconds": 60,  # Burst every 60 seconds
        "burst_multiplier": 85.0,  # Peak spike: 255 concurrent uploads
        "upload_ratio": 1.0,  # Write-only workload (all uploads, reproduces extreme iowait)
    },
    "light_load": {
        "num_packages": 50,
        "concurrent_clients": 3,
        "test_duration_seconds": 300,  # 5 minutes
        "burst_interval_seconds": None,
        "burst_multiplier": 1.0,
        "upload_ratio": 0.0,  # Read-only
    },
    "heavy_load": {
        "num_packages": 100,  # Same as available test packages (0-99)
        "concurrent_clients": 20,
        "test_duration_seconds": 600,  # 10 minutes
        "burst_interval_seconds": 30,
        "burst_multiplier": 5.0,
        "upload_ratio": 0.0,  # Read-only
    },
}


if __name__ == "__main__":
    import argparse
    import os

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    parser = argparse.ArgumentParser(description="PyPI server stress testing")
    parser.add_argument(
        "--profile", default="production_incident", choices=TEST_PROFILES.keys()
    )
    parser.add_argument("--pypi-url", default=os.getenv("PYPI_URL"))
    parser.add_argument("--username", default=os.getenv("PYPI_USERNAME"))
    parser.add_argument("--password", default=os.getenv("PYPI_PASSWORD"))
    parser.add_argument("--output-dir", type=Path, default=Path("tests/results"))

    args = parser.parse_args()

    if not all([args.pypi_url, args.username, args.password]):
        parser.error(
            "Must provide --pypi-url, --username, --password or set PYPI_URL, PYPI_USERNAME, PYPI_PASSWORD env vars"
        )

    profile_config = TEST_PROFILES[args.profile]

    results = run_stress_test(
        pypi_url=args.pypi_url,
        username=args.username,
        password=args.password,
        profile=args.profile,
        **profile_config,
    )

    save_results(results, args.output_dir)

    # Print summary
    print("\n" + "=" * 60)
    print(f"Stress Test Complete: {args.profile}")
    print("=" * 60)
    print(f"Total Requests: {results.total_requests}")
    print(f"Error Rate: {100 * results.error_rate:.2f}%")
    print(f"P95 Latency: {results.latency_p95:.2f} ms")
    print(f"5xx Errors: {results.error_5xx_count}")
    print("=" * 60)

    # Exit with error code if test failed criteria
    if results.error_rate > 0.01 or results.error_5xx_count > 0:
        print("\n❌ Test FAILED: Error rate or 5xx errors exceed threshold")
        exit(1)
    elif results.latency_p95 > 2000:  # 2 seconds
        print("\n⚠️  Test WARNING: P95 latency exceeds 2s")
        exit(0)
    else:
        print("\n✅ Test PASSED")
        exit(0)
