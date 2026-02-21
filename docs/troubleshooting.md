# Troubleshooting

## Slow Package Listing

**Symptoms**: `pip install` or `poetry install` takes > 5 seconds to resolve the
package index.

**Possible causes**:

1. EFS throughput throttled (check `PercentIOLimit` metric)
2. Instance swapping due to low memory
3. Too many packages (> 1000) causing metadata bottleneck

**Diagnosis**:

```bash
# 1. Check EFS throughput utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name PercentIOLimit \
  --dimensions Name=FileSystemId,Value=$(terraform output -raw efs_file_system_id) \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Maximum

# 2. SSH to instance and check swap activity
aws ssm start-session --target <instance-id>
vmstat 1 5  # Watch si/so columns - should be 0
free -m     # Check available memory

# 3. Check package count
ls /mnt/packages | wc -l
```

**Solutions**:

1. If `PercentIOLimit` > 80%: Verify `efs_throughput_mode = "elastic"` (default) or
   switch to provisioned
2. If swap columns (si/so) are non-zero: Increase `asg_instance_type`
3. If available memory < 500 MB: Increase `container_memory` or instance size
4. For 1000+ packages: Consider a CloudFront caching layer

---

## Container OOM Kills

**Symptoms**: Tasks restarting frequently; ECS events show "OutOfMemory" or
"Essential container in task exited".

**Cause**: Container memory limit (`container_memory`) is too low.

**Diagnosis**:

```bash
# Check ECS service events
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  | jq '.services[0].events[] | select(.message | contains("OutOfMemory"))'

# Check container memory metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ServiceName,Value=pypiserver \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Maximum
```

**Solutions**:

1. Increase `container_memory` to 512 MB or 1024 MB
2. Reduce `task_min_count` to allocate more memory per task
3. Increase instance type if tasks won't fit

---

## High iowait on Hosts

**Symptoms**: Slow responses; CloudWatch shows high CPU wait time.

**Causes**:

1. Insufficient page cache (instance memory too small)
2. EFS throttling
3. Swap activity

**Diagnosis**:

```bash
aws ssm start-session --target <instance-id>

# Check iowait % (wa column should be < 10%)
vmstat 1 5

# Check if swapping
cat /proc/meminfo | grep -E 'MemAvailable|SwapTotal|SwapFree'

# Check EFS mount stats
cat /proc/self/mountstats | grep -A20 "mounted on /data/packages"
```

**Solutions**:

1. If `SwapFree` < `SwapTotal`: Increase instance size immediately
2. If `MemAvailable` < 500 MB: Increase instance size or reduce container memory
3. Check CloudWatch `PercentIOLimit` for EFS throttling

---

## Authentication Failures

**Symptoms**: `pip install` or `twine upload` returns 401 Unauthorized.

**Causes**:

1. Incorrect credentials
2. Special characters in password not URL-encoded
3. Credentials not yet propagated from Secrets Manager

**Diagnosis**:

```bash
# Retrieve current credentials
terraform output -raw pypi_username
terraform output -raw pypi_password

# Test with curl
curl -u "$(terraform output -raw pypi_username):$(terraform output -raw pypi_password)" \
  https://$(terraform output -raw pypi_server_urls | jq -r '.[0]')/simple/
```

**Solutions**:

1. Verify credentials match Terraform outputs
2. URL-encode password if it contains special characters:
   ```bash
   python3 -c "import urllib.parse; print(urllib.parse.quote(input('Password: ')))"
   ```
3. Configure pip with credentials:
   ```bash
   export PIP_INDEX_URL=https://username:password@pypi.example.com/simple/
   ```

---

## Package Upload Fails

**Symptoms**: `twine upload` returns 5xx error or times out.

**Possible causes**:

1. Container out of memory during upload
2. Package too large (> 100 MB)
3. Network timeout

**Diagnosis**:

```bash
# Check recent container events
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  | jq '.services[0].events[0:5]'

# Try uploading with verbose output
twine upload --verbose --repository-url https://pypi.example.com dist/*.whl
```

**Solutions**:

1. If container OOM killed during upload: Increase `container_memory`
2. For large packages: Split into smaller packages or increase twine timeout:
   `twine upload --timeout 300`
3. Check EFS for throttling via `PercentIOLimit` metric

---

## High Error Rate During Bursts

**Symptoms**: Many 502 Bad Gateway or connection timeout errors when many CI jobs
run simultaneously.

**Expected behavior**: < 1% error rate is normal for extreme bursts (500+ simultaneous
requests). 10-20 second P95 latency during bursts is expected.

**Diagnosis**:

```bash
# Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  | jq '.TargetHealthDescriptions[] | {Target: .Target.Id, State: .TargetHealth.State}'

# Check ECS task count
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  | jq '.services[0] | {desired: .desiredCount, running: .runningCount}'
```

**Solutions (if error rate > 1%)**:

1. Increase instance type: `c6a.xlarge` or `c6a.2xlarge`
2. Use the "fewer, beefier instances" strategy
3. Stagger CI job starts with random jitter (0-60s)
4. See [Sizing](SIZING.md) for capacity planning

!!! note
    Due to HTTP keep-alive connection stickiness, burst traffic often concentrates
    on one instance. This is fundamental ALB behavior. The solution is provisioning
    enough CPU per instance to handle it.
