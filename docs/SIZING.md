# PyPI Server Sizing Guide

This guide helps you choose the right infrastructure configuration for your PyPI server workload based on real-world stress testing.

## Table of Contents

- [Quick Recommendations](#quick-recommendations)
- [Workload Profiles](#workload-profiles)
- [Sizing Strategy](#sizing-strategy)
- [Performance Characteristics](#performance-characteristics)
- [Cost Analysis](#cost-analysis)
- [Capacity Planning](#capacity-planning)
- [When to Scale Up](#when-to-scale-up)

---

## Quick Recommendations

**Choose your workload profile:**

| Profile | Packages | Users | CI Jobs | Burst Requests | Recommended Configuration |
|---------|----------|-------|---------|----------------|---------------------------|
| **Light** | < 50 | < 5 | Few | < 50/min | 2 × t3.small (~$30/mo) |
| **Medium** | 50-200 | 5-20 | Moderate | 50-200/min | 2 × c6a.large (~$110/mo) |
| **Heavy** | 200-500 | 20-50 | Many | 200-500/min | 2 × c6a.xlarge (~$220/mo) |
| **Very Heavy** | 500+ | 50+ | Continuous | 500+/min | 2 × c6a.2xlarge (~$440/mo) |

**Key Principle:** Use **fewer, beefier instances** rather than many small instances.

---

## Workload Profiles

### Light Workload

**Characteristics:**
- Packages: < 50
- Team size: < 5 developers
- CI/CD: Infrequent builds (< 10/day)
- Request pattern: Sporadic, low volume
- Peak burst: < 50 simultaneous requests

**Recommended Configuration:**
```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  asg_instance_type = "t3.small"
  asg_min_size      = 2
  asg_max_size      = 2

  container_memory = 512
  task_min_count   = null  # Auto = 6 (3 per instance)
  task_max_count   = null  # Auto = 12 (2× min)
}
```

**Expected Performance:**
- P95 latency: < 2 seconds (normal load)
- Error rate: < 0.1%
- Handles bursts up to 50 requests gracefully

**Cost:** ~$30/month (2 × t3.small)

---

### Medium Workload

**Characteristics:**
- Packages: 50-200
- Team size: 5-20 developers
- CI/CD: Regular builds (10-50/day)
- Request pattern: Daily peaks, moderate bursts
- Peak burst: 50-200 simultaneous requests

**Recommended Configuration:**
```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  asg_instance_type = "c6a.large"
  asg_min_size      = 2
  asg_max_size      = 4

  container_memory = 512
  task_min_count   = null  # Auto = 6 (3 per instance)
  task_max_count   = null  # Auto = 24 (2× min, allows scaling)
}
```

**Expected Performance:**
- P95 latency: < 5 seconds (normal load), < 10 seconds (burst)
- Error rate: < 0.5%
- Handles bursts up to 200 requests

**Cost:** ~$110/month (2 × c6a.large)

---

### Heavy Workload (Production-Validated)

**Characteristics:**
- Packages: 200-500
- Team size: 20-50 developers
- CI/CD: Continuous builds (50-200/day)
- Request pattern: Sustained traffic with significant bursts
- Peak burst: 200-500 simultaneous requests

**Recommended Configuration:**
```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  asg_instance_type = "c6a.xlarge"
  asg_min_size      = 2
  asg_max_size      = 4

  container_memory = 512
  task_min_count   = null  # Auto = 12 (6 per instance)
  task_max_count   = null  # Auto = 24 (2× min)
}
```

**Validated Performance** (Stress tested with 510 concurrent requests):
- Error rate: **0.05%** (3 failures / 6,273 requests)
- P95 latency: 14 seconds (extreme burst)
- P99 latency: 20 seconds
- Throughput: 20 req/s sustained
- 5xx errors: < 10 per test

**Cost:** ~$220/month (2 × c6a.xlarge)

**Why This Works:**
- 4 vCPU per instance provides headroom to absorb burst traffic
- Compute-optimized instances (100% sustained CPU, no burst credits)
- Only 6 ALB targets (vs 12+ with smaller instances) = less load distribution variance
- Can handle all 510 requests on a single instance if needed (due to HTTP keep-alive stickiness)

---

### Very Heavy Workload

**Characteristics:**
- Packages: 500+
- Team size: 50+ developers
- CI/CD: Continuous parallel builds (200+/day)
- Request pattern: High sustained traffic, large bursts
- Peak burst: 500-1000 simultaneous requests

**Recommended Configuration:**
```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  asg_instance_type = "c6a.2xlarge"
  asg_min_size      = 2
  asg_max_size      = 4

  container_memory = 1024
  task_min_count   = null  # Auto = 12 (6 per instance)
  task_max_count   = null  # Auto = 24
}
```

**Expected Performance:**
- P95 latency: < 15 seconds (burst), < 3 seconds (normal)
- Error rate: < 0.05%
- Handles bursts up to 1000 requests

**Cost:** ~$440/month (2 × c6a.2xlarge)

---

## Sizing Strategy

### "Fewer, Beefier Instances" Principle

Based on extensive stress testing, we recommend **2-4 compute-optimized instances** rather than many small instances.

**Why This Works:**

1. **Reduced ALB Target Variance**
   - 6 ALB targets (2 instances × 3 tasks) vs 12+ with smaller instances
   - Lower variance in load distribution during bursts
   - Mathematical: Distributing 500 requests across 6 targets has ±14% variance vs ±20% across 12 targets

2. **Better Burst Absorption**
   - More CPU per instance handles uneven load distribution
   - HTTP keep-alive creates sticky connections (fundamental ALB behavior)
   - One instance may receive 80% of traffic during bursts
   - Beefier instances can handle this without failing

3. **Sustained Performance**
   - Compute-optimized instances (c6a, c7a) provide 100% CPU baseline
   - No burst credit management needed
   - Better price/performance for CPU-intensive workloads

**Instance Family Comparison:**

| Family | Use Case | CPU Baseline | Cost Efficiency |
|--------|----------|--------------|-----------------|
| t3 | Light, variable workloads | 20-40% (burst credits) | Good for small teams |
| c6a | CPU-intensive (recommended) | 100% | Best for PyPI |
| c7a | Latest gen (optional) | 100% | 15% better than c6a |
| m6i | Memory-intensive | 100% | Overkill for PyPI |

---

## Performance Characteristics

### Latency Expectations

**Normal Load (< 50 concurrent requests):**
- Package listing: < 1 second
- Package download: < 2 seconds
- P95 latency: < 2 seconds

**Moderate Burst (50-200 concurrent requests):**
- Package listing: 2-5 seconds
- Package download: 3-8 seconds
- P95 latency: 5-10 seconds

**Extreme Burst (500+ concurrent requests):**
- Package listing: 5-15 seconds
- Package download: 10-20 seconds
- P95 latency: 10-20 seconds

**Why High Latency During Bursts:**
1. HTTP keep-alive creates sticky connections to one instance
2. All 500 requests queue on same backend
3. Python GIL limits parallelism within workers
4. EFS metadata scans (no caching with `--backend simple-dir`)

**This is expected behavior and acceptable for internal PyPI servers.**

### Error Rate Expectations

| Configuration | Normal Load | Burst Load (500 req) |
|---------------|-------------|----------------------|
| 2 × t3.small | < 0.1% | 2-5% |
| 2 × c6a.large | < 0.05% | 0.5-1% |
| 2 × c6a.xlarge | < 0.01% | **0.05%** (validated) |
| 2 × c6a.2xlarge | < 0.01% | < 0.05% |

**Target: < 1% error rate under burst load**

---

## Cost Analysis

### Monthly Cost Breakdown

**Light Configuration (2 × t3.small):**
- EC2: 2 × $0.0208/hour × 730 hours = $30.37
- EFS: ~$0.30 (1 GB storage, elastic throughput)
- ALB: ~$16.20 (base) + ~$1/month (LCU)
- **Total: ~$48/month**

**Heavy Configuration (2 × c6a.xlarge - Recommended):**
- EC2: 2 × $0.153/hour × 730 hours = $223.38
- EFS: ~$3.00 (10 GB storage, elastic throughput)
- ALB: ~$16.20 (base) + ~$3/month (LCU)
- **Total: ~$245/month**

**Very Heavy Configuration (2 × c6a.2xlarge):**
- EC2: 2 × $0.306/hour × 730 hours = $446.76
- EFS: ~$10.00 (50 GB storage, elastic throughput)
- ALB: ~$16.20 (base) + ~$5/month (LCU)
- **Total: ~$478/month**

**Cost Optimization Tips:**
1. Use Savings Plans or Reserved Instances (save 30-50%)
2. Enable EFS lifecycle policies to move old packages to IA storage
3. Set reasonable `task_max_count` to limit auto-scaling costs
4. Use `asg_max_size` to cap instance count

---

## Capacity Planning

### Auto-Scaling Calculation

The module auto-calculates task capacity based on **both CPU and RAM** constraints:

```
tasks_per_instance_ram = floor(available_ram / container_memory_reservation)
tasks_per_instance_cpu = floor(available_cpu / container_cpu)
tasks_per_instance = min(tasks_per_instance_ram, tasks_per_instance_cpu)
```

**Example: c6a.xlarge**
- RAM: 8 GB = 8192 MB
- Available RAM: 8192 - 800 (system) = 7392 MB
- Container reservation: 384 MB (75% of 512 MB limit)
- **RAM-based capacity**: floor(7392 / 384) = **19 tasks**

- CPU: 4 vCPU = 4096 CPU units
- Available CPU: 4096 - 128 (system) = 3968 units
- Container CPU: 640 units (4 workers × 150 + 40)
- **CPU-based capacity**: floor(3968 / 640) = **6 tasks**

- **Actual capacity**: min(19, 6) = **6 tasks per instance** (CPU constrained)

**For 2 × c6a.xlarge:**
- `task_min_count` = 6 × 2 = **12 tasks**
- `task_max_count` = 12 × 2 = **24 tasks** (auto-scaling headroom)

### Worker Count Calculation

Each task runs **4 gunicorn workers** (auto-calculated):
- Formula: `(2 × vCPU_per_task) = (2 × 0.625) ≈ 1.25, rounded to 4 (minimum)`
- For CPU-constrained workloads, 4 workers provides good parallelism
- For I/O-bound operations (EFS), workers wait on I/O (Python GIL is not limiting factor)

**Total worker capacity:**
- 2 instances × 6 tasks × 4 workers = **48 concurrent workers**
- Can handle 48 simultaneous pip install operations without queuing

---

## When to Scale Up

### Signs You Need More Resources

**Scale Up Instance Type** if:
- ✅ CPU utilization > 80% sustained (not just during bursts)
- ✅ Error rate > 1% during normal traffic
- ✅ P95 latency > 5 seconds during normal traffic
- ✅ CloudWatch shows consistent memory pressure

**Scale Out Instance Count** if:
- ✅ Task count consistently at `task_max_count`
- ✅ ECS service auto-scaling is frequently triggered
- ✅ Need high availability (already at 2 instances minimum)

**Upgrade EFS Throughput** if:
- ✅ `PercentIOLimit` > 80% sustained
- ✅ Many packages (> 1000) causing metadata bottleneck
- ✅ EFS burst credits depleting (only applies if `efs_throughput_mode = "bursting"`)

### Monitoring Metrics

**Key CloudWatch Metrics:**

1. **EFS PercentIOLimit**
   - Alert: > 80% sustained
   - Action: Verify `efs_throughput_mode = "elastic"` (default) or switch to provisioned

2. **ECS CPU Utilization**
   - Alert: > 80% for 10+ minutes
   - Action: Increase instance type

3. **ECS Memory Utilization**
   - Alert: > 90%
   - Action: Increase `container_memory` or instance type

4. **ALB TargetResponseTime (P95)**
   - Alert: > 5 seconds during normal traffic
   - Action: Check instance CPU/memory, consider scaling

5. **ALB 5xx Error Count**
   - Alert: > 10 errors per hour
   - Action: Review diagnostics, check backend health

---

## Migration Guide

### Upgrading from Smaller to Larger Instances

**Example: t3.small → c6a.xlarge**

1. **Update Terraform Configuration:**
```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  # Before
  # asg_instance_type = "t3.small"

  # After
  asg_instance_type = "c6a.xlarge"
  asg_min_size      = 2
  asg_max_size      = 4
}
```

2. **Plan the Change:**
```bash
terraform plan
# Review changes: instance type, task count adjustments
```

3. **Apply During Low-Traffic Window:**
```bash
terraform apply
# ECS will perform rolling update
# ~5-10 minutes of partial capacity
```

4. **Monitor Post-Upgrade:**
- Check CloudWatch for CPU/memory utilization
- Verify error rates are acceptable
- Monitor EFS metrics

### Downgrading (Cost Optimization)

If your workload is lighter than expected:

1. **Validate Current Usage:**
   - Check CloudWatch metrics for actual utilization
   - Ensure CPU < 50% sustained, memory < 60%
   - Verify error rates remain low

2. **Test with Smaller Instance:**
   - Use test environment to validate
   - Run stress tests if available

3. **Gradual Rollback:**
   - Change instance type in stages (e.g., c6a.xlarge → c6a.large → t3.medium)
   - Monitor each stage for 24-48 hours

---

## Advanced Tuning

### Custom Task Count

Override auto-calculation for specific requirements:

```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  asg_instance_type = "c6a.xlarge"
  asg_min_size      = 2

  # Explicit task count (instead of auto-calculated)
  task_min_count = 8   # Fewer tasks for higher memory per task
  task_max_count = 16
}
```

**Use Cases:**
- Need more memory per container (fewer tasks = more RAM per task)
- Want to reserve capacity for future growth
- Optimizing for specific workload patterns

### EFS Throughput Mode

The module defaults to **elastic** throughput mode, which eliminates burst credit management
and uses pay-per-use pricing. This is recommended for pypiserver because small filesystems
get minimal burst baseline (~50 KiB/s per GiB) and continuous metadata I/O inevitably
depletes burst credits.

**Available modes:**

```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  # Default: elastic (recommended)
  efs_throughput_mode = "elastic"

  # Alternative: provisioned (for very heavy, predictable workloads)
  # efs_throughput_mode                 = "provisioned"
  # efs_provisioned_throughput_in_mibps = 100

  # Alternative: bursting (not recommended for pypiserver)
  # efs_throughput_mode = "bursting"
}
```

**Cost comparison:**
- **Elastic**: ~$0.04/GB transferred (economical for modest throughput)
- **Provisioned**: ~$6/MiB/s/month (e.g. ~$600/month for 100 MiB/s)
- **Bursting**: Free with storage, but credits deplete on small filesystems

---

## Troubleshooting Performance Issues

### High Latency Checklist

1. **Check EFS Throughput Utilization:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EFS \
     --metric-name PercentIOLimit \
     --dimensions Name=FileSystemId,Value=fs-xxxxx \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Maximum
   ```

2. **Check Instance CPU/Memory:**
   - Navigate to ECS Console → Cluster → Service → Metrics
   - Look for CPU/memory spikes correlating with latency

3. **Check ALB Target Health:**
   ```bash
   aws elbv2 describe-target-health \
     --target-group-arn <your-target-group-arn>
   ```

4. **Review Application Logs:**
   - Check CloudWatch Logs for errors
   - Look for OOM kills or container restarts

### High Error Rate Checklist

1. **Identify Error Type:**
   - 502 Bad Gateway = Backend overloaded or unhealthy
   - 503 Service Unavailable = No healthy targets
   - 504 Gateway Timeout = Request processing too slow

2. **Check Backend Health:**
   - ECS task count vs desired count
   - Container crash loops
   - Health check failures

3. **Increase Capacity:**
   - Scale up instance type (more CPU/RAM)
   - Increase task count
   - Add more instances

---

## FAQ

**Q: Why 2 instances minimum instead of 1?**
A: High availability. If one instance fails, the other handles traffic. Also provides some load distribution.

**Q: Why compute-optimized (c6a) instead of general-purpose (t3)?**
A: PyPI serving is CPU-intensive (file serving, compression). Compute-optimized provides better price/performance and 100% sustained CPU (no burst credits).

**Q: Can I use ARM-based instances (Graviton)?**
A: Yes! c6g/c7g instances work well and cost ~20% less. Ensure your container images support ARM64.

**Q: Why does load concentrate on one instance during bursts?**
A: HTTP keep-alive creates sticky connections. ALB distributes new connections but can't rebalance existing ones. This is expected behavior.

**Q: Can I improve latency beyond 14 seconds P95?**
A: For extreme bursts (500+ simultaneous), 10-20 seconds is expected with current architecture. To improve:
- Add CloudFront CDN for static file caching
- Switch to cached backend (requires cache invalidation strategy)
- Stagger CI/CD job starts to reduce burst impact

**Q: How many packages can one server handle?**
A: Tested up to 500 packages. For 1000+, consider CloudFront or dedicated caching layer.

---

## Summary

**Quick Sizing Decision Tree:**

1. **Team < 10 developers, < 50 packages:**
   → 2 × t3.small (~$48/month)

2. **Team 10-30 developers, 50-200 packages:**
   → 2 × c6a.large (~$110/month)

3. **Team 30-60 developers, 200-500 packages:**
   → 2 × c6a.xlarge (~$245/month) ✅ **Recommended, stress-tested**

4. **Team 60+ developers, 500+ packages:**
   → 2 × c6a.2xlarge (~$478/month)

**Key Takeaways:**
- ✅ Use fewer, beefier instances (not many small ones)
- ✅ Compute-optimized instances provide best price/performance
- ✅ 2 instances minimum for HA
- ✅ Auto-calculated task counts work well (don't override unless needed)
- ✅ Expect 10-20 second P95 latency during extreme bursts (500+ concurrent)
- ✅ Target < 1% error rate (0.05% achievable with proper sizing)