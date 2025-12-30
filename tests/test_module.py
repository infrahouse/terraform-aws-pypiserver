import io
import json
import os
import shutil
import subprocess
import tarfile
import time
from os import path as osp
from textwrap import dedent

import pytest
import requests
from infrahouse_core.timeout import timeout
from pytest_infrahouse import terraform_apply
from pytest_infrahouse.utils import wait_for_instance_refresh

from tests.conftest import LOG


def _create_test_package(package_name: str, version: str) -> bytes:
    """Create a minimal test Python package as a tar.gz."""
    setup_py = dedent(
        f"""
        from setuptools import setup
        setup(
            name="{package_name}",
            version="{version}",
            py_modules=["{package_name}"],
            description="Test package for PyPI server validation",
        )
        """
    )

    module_py = dedent(
        f'''
        """Test package {package_name} version {version}"""

        def get_version():
            return "{version}"

        def hello():
            return "Hello from {package_name}!"
        '''
    )

    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w:gz") as tar:
        # Add setup.py
        setup_info = tarfile.TarInfo(name=f"{package_name}-{version}/setup.py")
        setup_bytes = setup_py.encode("utf-8")
        setup_info.size = len(setup_bytes)
        tar.addfile(setup_info, io.BytesIO(setup_bytes))

        # Add module file
        module_info = tarfile.TarInfo(
            name=f"{package_name}-{version}/{package_name}.py"
        )
        module_bytes = module_py.encode("utf-8")
        module_info.size = len(module_bytes)
        tar.addfile(module_info, io.BytesIO(module_bytes))

    return tar_buffer.getvalue()


def _upload_package(
    pypi_url: str, username: str, password: str, package_name: str, version: str
) -> bool:
    """Upload a package to the PyPI server."""
    package_data = _create_test_package(package_name, version)
    filename = f"{package_name}-{version}.tar.gz"

    LOG.info(f"Uploading {filename} to {pypi_url}")
    response = requests.post(
        f"{pypi_url}/",
        auth=(username, password),
        files={"content": (filename, package_data, "application/gzip")},
        data={
            ":action": "file_upload",
            "name": package_name,
            "version": version,
        },
        timeout=30,
    )
    response.raise_for_status()
    LOG.info(f"Successfully uploaded {package_name} version {version}")
    return True


def _verify_package_exists(
    pypi_url: str, username: str, password: str, package_name: str, version: str
) -> bool:
    """Verify package exists in the simple index."""
    LOG.info(f"Verifying {package_name} {version} exists in index")
    response = requests.get(
        f"{pypi_url}/simple/{package_name}/",
        auth=(username, password),
        timeout=30,
    )
    response.raise_for_status()

    expected_filename = f"{package_name}-{version}.tar.gz"
    if expected_filename in response.text:
        LOG.info(f"✓ Package {package_name} {version} found in index")
        return True
    else:
        LOG.error(f"✗ Package {package_name} {version} NOT found in index")
        LOG.error(f"Index content: {response.text}")
        return False


def _install_and_test_package(
    pypi_url: str, username: str, password: str, package_name: str, version: str
) -> bool:
    """Install package using pip in current environment and verify it works."""
    LOG.info(f"Installing {package_name} {version} using pip in current environment")

    # Install from the PyPI server in the current environment
    index_url = f"https://{username}:{password}@{pypi_url.replace('https://', '')}"
    hostname = pypi_url.replace("https://", "").replace("http://", "").split("/")[0]

    install_result = subprocess.run(
        [
            "pip",
            "install",
            f"{package_name}=={version}",
            "--index-url",
            index_url,
            "--trusted-host",
            hostname,
        ],
        capture_output=True,
        text=True,
    )

    if install_result.returncode != 0:
        LOG.error(f"Failed to install package: {install_result.stderr}")
        return False

    LOG.info(f"✓ Package {package_name} installed successfully")

    try:
        # Test the installed package by importing it
        test_result = subprocess.run(
            [
                "python",
                "-c",
                f"import {package_name}; assert {package_name}.get_version() == '{version}'; print({package_name}.hello())",
            ],
            capture_output=True,
            text=True,
        )

        if test_result.returncode != 0:
            LOG.error(f"Package test failed: {test_result.stderr}")
            return False

        LOG.info(
            f"✓ Package {package_name} works correctly: {test_result.stdout.strip()}"
        )
        return True

    finally:
        # Clean up - uninstall the test package
        LOG.info(f"Cleaning up: uninstalling {package_name}")
        subprocess.run(
            ["pip", "uninstall", "-y", package_name],
            capture_output=True,
        )


def _wait_for_server_ready(
    pypi_url: str, username: str, password: str, timeout_seconds: int = 120
):
    """Wait for PyPI server to be ready by polling health endpoint."""
    LOG.info(f"Waiting for PyPI server to be ready (max {timeout_seconds}s)...")
    start_time = time.time()

    with timeout(seconds=timeout_seconds):
        while True:
            try:
                response = requests.get(
                    f"{pypi_url}/",
                    auth=(username, password),
                    timeout=5,
                )
                if response.status_code in (
                    200,
                    401,
                ):  # 200 OK or 401 means server is up
                    elapsed = time.time() - start_time
                    LOG.info(f"✓ Server ready after {elapsed:.1f}s")
                    return
            except requests.RequestException as e:
                LOG.debug(f"Server not ready yet: {e}")

            time.sleep(1)  # Poll every second


def _validate_pypi_functionality(tf_output: dict):
    """Validate PyPI server by uploading, downloading, and installing a test package."""
    LOG.info("=" * 70)
    LOG.info("VALIDATING PYPI SERVER FUNCTIONALITY")
    LOG.info("=" * 70)

    # Get PyPI server URL - will raise KeyError if missing
    pypi_url = tf_output["pypi_server_urls"]["value"][0]
    LOG.info(f"PyPI server URL: {pypi_url}")

    # Get credentials from outputs - will raise KeyError if missing
    username = tf_output["pypi_username"]["value"]
    password = tf_output["pypi_password"]["value"]
    LOG.info(f"Username: {username}")

    # Wait for service to be ready with smart polling
    _wait_for_server_ready(pypi_url, username, password)

    # Test package details - use timestamp to ensure uniqueness across test runs
    timestamp = int(time.time())
    test_package = "pypitestinfrahouse"  # No hyphens - must be valid Python identifier
    test_version = f"1.0.{timestamp}"
    LOG.info(f"Test package: {test_package} version {test_version}")

    try:
        # Step 1: Upload package
        LOG.info(f"\n[1/3] Uploading test package {test_package} {test_version}")
        assert _upload_package(pypi_url, username, password, test_package, test_version)

        # Wait a bit for indexing
        time.sleep(5)

        # Step 2: Verify package is downloadable
        LOG.info(f"\n[2/3] Verifying package appears in index")
        assert _verify_package_exists(
            pypi_url, username, password, test_package, test_version
        )

        # Step 3: Install and test the package
        LOG.info(f"\n[3/3] Installing and testing package with pip")
        assert _install_and_test_package(
            pypi_url, username, password, test_package, test_version
        )

        LOG.info("\n" + "=" * 70)
        LOG.info("✓ ALL VALIDATION TESTS PASSED")
        LOG.info("=" * 70 + "\n")

    except Exception as e:
        LOG.error("\n" + "=" * 70)
        LOG.error(f"✗ VALIDATION FAILED: {e}")
        LOG.error("=" * 70 + "\n")
        raise


@pytest.mark.parametrize(
    "aws_provider_version", ["~> 5.11", "~> 6.0"], ids=["aws-5", "aws-6"]
)
def test_module(
    service_network,
    test_role_arn,
    aws_region,
    subzone,
    keep_after,
    aws_provider_version,
    boto3_session,
):
    terraform_root_dir = "test_data"

    subnet_public_ids = service_network["subnet_public_ids"]["value"]
    subnet_private_ids = service_network["subnet_private_ids"]["value"]
    zone_id = subzone["subzone_id"]["value"]

    terraform_module_dir = osp.join(terraform_root_dir, "pypiserver")

    # Clean up Terraform cache files
    try:
        shutil.rmtree(osp.join(terraform_module_dir, ".terraform"))
    except FileNotFoundError:
        pass

    try:
        os.remove(osp.join(terraform_module_dir, ".terraform.lock.hcl"))
    except FileNotFoundError:
        pass

    # Generate terraform.tf with specified AWS provider version
    with open(osp.join(terraform_module_dir, "terraform.tf"), "w") as fp:
        fp.write(
            dedent(
                f"""
                terraform {{
                  //noinspection HILUnresolvedReference
                  required_providers {{
                    aws = {{
                      source  = "hashicorp/aws"
                      version = "{aws_provider_version}"
                    }}
                  }}
                }}
                """
            )
        )

    LOG.info(
        f"Generated terraform.tf with AWS provider version: {aws_provider_version}"
    )

    # Create pypi server
    with open(osp.join(terraform_module_dir, "terraform.tfvars"), "w") as fp:
        fp.write(
            dedent(
                f"""
                region = "{aws_region}"
                zone_id = "{zone_id}"

                subnet_public_ids = {json.dumps(subnet_public_ids)}
                subnet_private_ids = {json.dumps(subnet_private_ids)}
                """
            )
        )
        if test_role_arn:
            fp.write(
                dedent(
                    f"""
                    role_arn = "{test_role_arn}"
                    """
                )
            )
    with terraform_apply(
        terraform_module_dir,
        destroy_after=not keep_after,
        json_output=True,
        enable_trace=False,
    ) as tf_pypiserver_output:
        LOG.info(json.dumps(tf_pypiserver_output, indent=4))

        # Wait for any in-progress ASG instance refreshes to complete
        # This ensures instances have the latest configuration from cloud-init
        asg_name = tf_pypiserver_output["asg_name"]["value"]
        autoscaling_client = boto3_session.client("autoscaling", region_name=aws_region)
        wait_for_instance_refresh(
            asg_name=asg_name,
            autoscaling_client=autoscaling_client,
            timeout=1200,  # 20 minutes max
            poll_interval=10,
        )

        # Validation: Test package upload/download/install
        _validate_pypi_functionality(tf_pypiserver_output)

        # Log capacity calculation info
        capacity_info = tf_pypiserver_output["capacity_info"]["value"]
        LOG.info("=" * 70)
        LOG.info("CAPACITY CALCULATION")
        LOG.info("=" * 70)
        LOG.info(f"Instance type:              {capacity_info['instance_type']}")
        LOG.info(f"Instance RAM:               {capacity_info['instance_ram_mb']} MB")
        LOG.info(
            f"System overhead:            {capacity_info['system_overhead_mb']} MB"
        )
        LOG.info(
            f"Available RAM per instance: {capacity_info['available_ram_mb_per_instance']} MB"
        )
        LOG.info(
            f"Container memory limit:     {capacity_info['container_memory_mb']} MB"
        )
        LOG.info(
            f"Container memory reserved:  {capacity_info['container_memory_reservation_mb']} MB"
        )
        LOG.info(
            f"Container CPU reserved:     {capacity_info['container_cpu_units']} units ({capacity_info['container_cpu_units']/1024:.2f} vCPU)"
        )
        LOG.info(
            f"Gunicorn workers/container: {capacity_info['gunicorn_workers_per_container']}"
        )
        LOG.info(f"Tasks per instance:         {capacity_info['tasks_per_instance']}")
        LOG.info(f"ASG instance count:         {capacity_info['asg_instance_count']}")
        LOG.info(
            f"Auto-calculated task_min:   {capacity_info['auto_calculated_task_min_count']}"
        )
        LOG.info(
            f"Actual task_min_count:      {capacity_info['actual_task_min_count']}"
        )
        LOG.info("=" * 70 + "\n")

        # Output PyPI credentials for manual testing
        pypi_url = tf_pypiserver_output["pypi_server_urls"]["value"][0]
        username = tf_pypiserver_output["pypi_username"]["value"]
        password = tf_pypiserver_output["pypi_password"]["value"]

        LOG.info("\n" + "=" * 70)
        LOG.info("PYPI SERVER CREDENTIALS")
        LOG.info("=" * 70)
        LOG.info(f"URL:      {pypi_url}")
        LOG.info(f"Username: {username}")
        LOG.info(f"Password: {password}")
        LOG.info("=" * 70 + "\n")
