"""
Test for package generator fixtures.

This is a simple test to verify the test_packages fixture works correctly.
To run: pytest tests/test_package_generator.py -v
"""

from pathlib import Path


def test_package_generation(test_packages):
    """Test that packages are generated correctly."""
    # Should generate 100 packages × 3 versions = 300 wheels
    assert len(test_packages) == 300, f"Expected 300 packages, got {len(test_packages)}"

    # All should be Path objects
    assert all(isinstance(pkg, Path) for pkg in test_packages)

    # All should exist
    assert all(pkg.exists() for pkg in test_packages)

    # All should be .whl files
    assert all(pkg.suffix == ".whl" for pkg in test_packages)

    # Check naming pattern (should be test_package_XXX-VERSION-py3-none-any.whl)
    sample = test_packages[0]
    assert sample.name.startswith("test_package_")
    assert "py3-none-any.whl" in sample.name

    # Calculate sizes
    wheels_size_mb = sum(pkg.stat().st_size for pkg in test_packages) / 1024 / 1024

    print(f"\n✓ Successfully generated {len(test_packages)} test packages")
    print(f"  Sample: {test_packages[0].name}")
    print(f"  Wheel files total: {wheels_size_mb:.2f} MB")
    print(f"  Note: Minimal packages (only __init__.py), suitable for stress testing")


def test_upload_fixture_returns_callable(upload_packages_to_pypi):
    """Test that upload fixture returns a callable function."""
    assert callable(upload_packages_to_pypi)
    print("\n✓ upload_packages_to_pypi fixture is callable")
