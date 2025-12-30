# Stress Testing Guide

This directory contains stress testing tools for the PyPI server module.

## Overview

The stress tests simulate concurrent pip/poetry operations to validate performance under load. They help ensure the PyPI server can handle CI/CD bursts without degradation.

## Components

### 1. Test Package Generator (`conftest.py`)
- Pytest fixture that generates 300 minimal test packages (100 packages × 3 versions)
- Session-scoped and cached (builds once, reuses across tests)
- Generates ~0.36 MB of wheels

### 2. Stress Test Module (`stress_test.py`)
- Simulates concurrent PyPI operations (package listing, downloads)
- Measures latency, error rates, throughput
- Collects metrics and generates reports
- Can run standalone or via pytest

### 3. Pytest Integration (`test_stress.py`)
- Pytest tests that use the stress test module
- Three test profiles: light, production_incident, heavy
- Validates against performance criteria

## Quick Start

### Prerequisites

1. **Deploy PyPI server** (via Terraform):
   ```bash
   cd test_data/pypiserver
   terraform init
   terraform apply
   ```

2. **Install Python dependencies**:
   ```bash
   pip install pytest requests
   ```

### Running Stress Tests

#### Recommended Workflow (via Make)

```bash
# Step 1: Deploy PyPI server and keep it running
make test-keep

# Step 2: Run stress tests against the deployed server
make stress
```

The `make stress` command runs all stress tests. To run a specific test:

```bash
# Set up AWS credentials first
export AWS_REGION="us-west-2"
export AWS_ROLE_ARN="arn:aws:iam::303467602807:role/pypiserver-tester"

# Run specific stress test
pytest -xvvs --keep-after -k "test_stress_production_incident" tests/test_stress.py
pytest -xvvs --keep-after -k "test_stress_light_load" tests/test_stress.py
pytest -xvvs --keep-after -k "test_stress_heavy_load" tests/test_stress.py
```

#### Alternative: Standalone Script

```bash
# Set credentials from existing deployment
export PYPI_URL=$(terraform -chdir=test_data/pypiserver output -raw pypi_url)
export PYPI_USERNAME=$(terraform -chdir=test_data/pypiserver output -raw pypi_username)
export PYPI_PASSWORD=$(terraform -chdir=test_data/pypiserver output -raw pypi_password)

# Run with profile
python tests/stress_test.py --profile production_incident

# Other profiles
python tests/stress_test.py --profile light_load
python tests/stress_test.py --profile heavy_load
```

## Test Profiles

### `production_incident`
Reproduces the actual production incident from 2025-12-27:
- **Duration**: 24 minutes (1440 seconds)
- **Concurrent clients**: 3 (baseline - low continuous load)
- **Pattern**: ~54 req/min baseline with sharp bursts to ~1,350 req/min every 60 seconds
- **Peak load**: 75 concurrent clients (25× baseline)
- **Total requests**: ~4,500+
- **Purpose**: Validate fixes prevent the original issue
- **Note**: Each pip install makes 3 requests (redirect + get + download) matching real pip behavior

**Expected Results**:
- ❌ FAIL on baseline (t3.micro + 128 MB)
- ✅ PASS on optimized (t3.small + 512 MB)

### `light_load`
Quick smoke test for basic validation:
- **Duration**: 5 minutes (300 seconds)
- **Concurrent clients**: 3
- **Pattern**: Steady low load, no bursts
- **Purpose**: Fast validation that server is working

**Expected Results**:
- ✅ PASS on all configurations

### `heavy_load`
Extreme load test for stress testing:
- **Duration**: 10 minutes (600 seconds)
- **Concurrent clients**: 20
- **Pattern**: High sustained load with 5× bursts every 30s
- **Purpose**: Validate performance under extreme conditions

**Expected Results**:
- ❌ FAIL on baseline and medium configurations
- ✅ PASS on optimized (t3.medium + 1024 MB)

## Success Criteria

Tests validate against these thresholds:

| Metric | Threshold | Notes |
|--------|-----------|-------|
| Error rate | < 1% | Percentage of failed requests |
| P95 latency | < 2000 ms | Package listing operations |
| P99 latency | < 5000 ms | Package download operations |
| 5xx errors | 0 | No server errors allowed |

## Output

Stress tests generate two output files in `tests/results/`:

### 1. JSON Report
Detailed metrics in machine-readable format:
```
tests/results/stress_test_20251227_153045.json
```

Contains:
- All latency percentiles
- Per-operation metrics
- Error breakdown by status code
- Timestamps and duration

### 2. Markdown Summary
Human-readable summary:
```
tests/results/stress_test_20251227_153045.md
```

Contains:
- Test summary
- Latency statistics
- Error counts
- Per-operation breakdown

## Example Workflow

### Testing Performance Improvements

1. **Establish baseline** (current configuration):
   ```bash
   # Deploy PyPI server with default configuration (t3.micro + 128 MB)
   make test-keep

   # Run stress tests
   make stress

   # Save results
   cp tests/results/stress_test_*.json tests/results/baseline.json
   ```

2. **Test with improvements**:
   ```bash
   # Update test_data/pypiserver/main.tf with optimized configuration
   # Set asg_instance_type = "t3.small", container_memory = 512, etc.

   # Clean up old deployment
   cd test_data/pypiserver
   terraform destroy
   cd ../..

   # Deploy with new configuration
   make test-keep

   # Run same stress tests
   make stress

   # Save results
   cp tests/results/stress_test_*.json tests/results/optimized.json
   ```

3. **Compare results**:
   ```bash
   # Compare latencies
   jq '.latency_p95' tests/results/baseline.json
   jq '.latency_p95' tests/results/optimized.json

   # Compare error rates
   jq '.error_rate' tests/results/baseline.json
   jq '.error_rate' tests/results/optimized.json
   ```

## Integration with Test Package Fixture

The stress tests automatically use the `test_packages` fixture from `conftest.py`:

```python
def test_stress_production_incident(keep_after, results_dir, test_packages, upload_packages_to_pypi):
    # test_packages fixture generates 300 wheels (one-time, cached)
    # upload_packages_to_pypi uploads them to the server
    # terraform_apply() gets credentials from deployed infrastructure
    # Then stress test runs against the populated server
```

**First run**: Takes ~7 minutes (package generation)
**Subsequent runs**: Instant (uses cached packages)

## Monitoring During Tests

### ECS Metrics
```bash
# Watch container memory
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ServiceName,Value=pypiserver \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average
```

### EFS Metrics
```bash
# Check burst credits
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name BurstCreditBalance \
  --dimensions Name=FileSystemId,Value=fs-xxxxx \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average
```

### Host Metrics (SSH to EC2 instance)
```bash
# Monitor memory/swap in real-time
watch -n 5 'free -m'

# Monitor IO wait
vmstat 5

# Check EFS mount stats
cat /proc/self/mountstats | grep -A50 "mounted on /data/packages"
```

## Cost Considerations

Stress tests are **manual/ad-hoc only** (not run in CI) due to cost:

- **Single test run** (~24 min): ~$0.02
  - t3.micro: $0.007
  - EFS: $0.00 (burst credits)
  - ALB: $0.01

- **Continuous testing** (hourly): ~$1,200/month ❌

**Recommendation**: Run manually when:
- Implementing performance changes
- Investigating production incidents
- Validating sizing recommendations
- Before major releases

## Troubleshooting

### "PYPI_URL not set"
```bash
# Make sure to export credentials
export PYPI_URL=$(terraform -chdir=test_data/pypiserver output -raw pypi_url)
export PYPI_USERNAME=$(terraform -chdir=test_data/pypiserver output -raw pypi_username)
export PYPI_PASSWORD=$(terraform -chdir=test_data/pypiserver output -raw pypi_password)
```

### "Connection refused"
- Verify PyPI server is deployed and healthy
- Check security groups allow inbound HTTPS traffic
- Verify ALB target groups show healthy targets

### Test times out
- Increase `timeout` parameter in stress_test.py
- Check if server is actually responding (curl test)
- Monitor CloudWatch for container/instance issues

### High error rates during baseline
- This is expected! Baseline (t3.micro + 128 MB) should fail
- The whole point is to demonstrate the problem exists
- Only optimized configuration should pass all tests

## Next Steps

After running stress tests:

1. **Review results** in `tests/results/`
2. **Compare metrics** between baseline and optimized
3. **Document findings** in performance plan
4. **Update sizing guide** with empirical data
5. **Create PR** with improvements and test results