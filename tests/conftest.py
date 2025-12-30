import logging
import subprocess
from pathlib import Path

import pytest
from infrahouse_core.logging import setup_logging
from pytest_infrahouse import LOG as LOG_PT_IH

LOG = logging.getLogger(__name__)

setup_logging(LOG, debug=True, debug_botocore=False)
setup_logging(LOG_PT_IH, debug=True, debug_botocore=False)


@pytest.fixture(scope="session")
def test_packages():
    """
    Generate test packages as wheels.

    Packages are cached in tests/.cache/packages/ and reused across test runs.
    Only regenerates if cache doesn't exist.

    Returns:
        List[Path]: Paths to built wheel files
    """
    # Use persistent cache directory instead of pytest's tmp
    cache_dir = Path(__file__).parent / ".cache" / "packages"
    cache_dir.mkdir(parents=True, exist_ok=True)

    # Check if packages already exist
    expected_packages = []
    for i in range(100):
        pkg_name = f"test-package-{i:03d}"
        for version in ["1.0.0", "1.1.0", "2.0.0"]:
            wheel_name = f"{pkg_name.replace('-', '_')}-{version}-py3-none-any.whl"
            expected_packages.append(cache_dir / wheel_name)

    # If all packages exist, return them (skip generation)
    if all(pkg.exists() for pkg in expected_packages):
        LOG.info(f"Using cached test packages from {cache_dir}")
        return expected_packages

    # Otherwise, generate packages
    LOG.info(f"Generating 300 test packages (this will take ~7 minutes)...")
    packages = []

    for i in range(100):
        pkg_name = f"test-package-{i:03d}"
        for version in ["1.0.0", "1.1.0", "2.0.0"]:
            wheel_path = _build_package(
                name=pkg_name, version=version, output_dir=cache_dir
            )
            packages.append(wheel_path)

    LOG.info(f"✓ Generated {len(packages)} packages in {cache_dir}")
    return packages


def _build_package(name: str, version: str, output_dir: Path) -> Path:
    """Build a minimal wheel package."""
    pkg_dir = output_dir / name / version
    pkg_dir.mkdir(parents=True, exist_ok=True)

    # Create pyproject.toml
    (pkg_dir / "pyproject.toml").write_text(
        f"""
[build-system]
requires = ["setuptools>=45", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "{name}"
version = "{version}"
description = "Test package for stress testing"
"""
    )

    # Create minimal package source
    src_dir = pkg_dir / "src" / name.replace("-", "_")
    src_dir.mkdir(parents=True, exist_ok=True)

    (src_dir / "__init__.py").write_text(f'__version__ = "{version}"')

    # Build wheel
    subprocess.run(
        ["python", "-m", "build", "--wheel", "--outdir", str(output_dir)],
        cwd=pkg_dir,
        check=True,
        capture_output=True,
    )

    return output_dir / f"{name.replace('-', '_')}-{version}-py3-none-any.whl"


@pytest.fixture(scope="session")
def upload_packages_to_pypi(test_packages):
    """
    Upload test packages to PyPI server after terraform_apply().

    Idempotent - safe to run multiple times (skips existing packages).

    Usage in tests:
        def test_stress(terraform_outputs, upload_packages_to_pypi):
            # terraform_outputs provides pypi_url, username, password
            # upload_packages_to_pypi uploads packages
            # now run stress test
    """

    def _upload(pypi_url: str, username: str, password: str):
        uploaded_count = 0
        skipped_count = 0
        failed_count = 0

        for wheel in test_packages:
            result = subprocess.run(
                [
                    "twine",
                    "upload",
                    "--repository-url",
                    pypi_url,
                    "--username",
                    username,
                    "--password",
                    password,
                    str(wheel),
                ],
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                # Successfully uploaded
                uploaded_count += 1
                LOG.debug(f"✓ Uploaded {wheel.name}")
            else:
                # Check if failure is due to package already existing
                error_output = result.stdout + result.stderr
                if (
                    "already exists" in error_output.lower()
                    or "file already exists" in error_output.lower()
                    or "409 conflict" in error_output.lower()
                    or ("conflict" in error_output.lower() and "409" in error_output)
                ):
                    # Package already exists - this is fine
                    skipped_count += 1
                    LOG.debug(f"⊘ Skipped {wheel.name} (already exists)")
                else:
                    # Real upload failure
                    failed_count += 1
                    LOG.error(f"✗ Failed to upload {wheel.name}")
                    LOG.error(f"  stdout: {result.stdout}")
                    LOG.error(f"  stderr: {result.stderr}")

        LOG.info(
            f"Upload summary: {uploaded_count} uploaded, {skipped_count} skipped, {failed_count} failed"
        )

        if failed_count > 0:
            raise RuntimeError(
                f"Failed to upload {failed_count} packages - see logs above for details"
            )

        return len(test_packages)

    return _upload
