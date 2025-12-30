# Architecture Notes

## Why `--backend simple-dir`?

### Problem: Cache Synchronization Bug

When running PyPI server with the default caching backend in a distributed environment, users experienced a cache synchronization issue where different containers would serve different package lists.

**Symptoms:**
- Package `xyz` version `1.2.3` uploaded by user
- Some requests return the new version `1.2.3` in the index
- Other requests return only older versions (up to `1.2.2`)
- Behavior is non-deterministic depending on which container handles the request

### Root Cause

The module architecture involves:
- Multiple ECS containers sharing a single EFS volume at `/data/packages`
- Gunicorn as the WSGI server (with multi-worker configuration)
- PyPI server's watchdog library for monitoring file system changes

**Two-level caching problem:**

1. **Intra-container:** Multiple gunicorn workers within one container maintain separate in-memory caches. When a package is uploaded, inotify events don't reliably reach all workers.

2. **Inter-container:** Even with `--workers 1`, EFS uses NFS v4.1, where inotify events don't work reliably across network filesystems. Different containers may not receive file change notifications.

This is documented in pypiserver GitHub issues (#449 and others).

### Solution: `--backend simple-dir`

The module uses `--backend simple-dir` to disable caching entirely. This forces PyPI server to scan the directory on every request.

**Trade-offs:**
- ✅ **Consistency:** All containers and workers always see the current state of EFS
- ✅ **Simplicity:** No complex cache invalidation logic needed
- ⚠️ **Performance:** Slightly higher I/O due to directory scans per request
- ✅ **Scalability:** Auto-scaling handles any performance impact by adding more tasks

### Alternative Solutions Considered

**Option 2: `--workers 1`**
- Only solves intra-container issue
- Does NOT solve inter-container issue (NFS inotify unreliability)
- Not sufficient for our distributed architecture

**Option 3: `--server wsgiref`**
- Uses built-in server instead of gunicorn
- Avoids multi-worker issues
- Less production-ready than gunicorn

**Chosen:** Option 1 (`--backend simple-dir`) provides the best correctness guarantees for our distributed, EFS-backed architecture.

### Implementation

See `main.tf` line 32:
```hcl
container_command = [
  "run", "-p", local.container_port, "--server", "gunicorn", "--backend", "simple-dir", ...
]
```

The `--backend simple-dir` flag ensures all requests across all containers return consistent, up-to-date package listings.

---

## Performance Considerations

### Memory Requirements

The module's architecture (EFS + `--backend simple-dir`) creates specific memory requirements:

#### Why Memory Matters

1. **No Application Cache**: `--backend simple-dir` disables pypiserver's in-memory cache
2. **Metadata-Heavy**: Every request scans EFS directory structure
3. **Page Cache Critical**: Kernel caches EFS metadata in RAM
4. **Memory Pressure → Swap → Latency**: If RAM is exhausted, kernel swaps → iowait spikes

#### Memory Breakdown

On a typical deployment:

**Container** (per task):
- Pypiserver process: 40-60 MB baseline
- Gunicorn workers: 30-50 MB each
- Request buffers: 20-40 MB
- **Total per container**: ~128 MB minimum, 512 MB recommended

**Host** (EC2 instance):
- System overhead: ~200 MB
- ECS agent: ~20 MB
- CloudWatch agent: ~5 MB
- **Page cache** (the critical part): 500+ MB needed for good performance
- **Total**: Container memory × tasks + 700 MB minimum

#### Real-World Example

From production incident (2025-12-27):

**Configuration**:
- Instance: t3.micro (916 MB RAM)
- Containers: 2 × 128 MB = 256 MB
- System overhead: ~200 MB
- Page cache available: ~460 MB

**Under Load**:
- CI burst: 10 concurrent pip installs
- Directory scans: 100+ packages × 10 clients = 1000s of metadata ops
- Page cache misses: kernel evicts cache to free RAM
- Swap activated: 750 MB swapped out
- iowait: 84% (waiting on swap + EFS)
- Latency: requests timing out

**Resolution**:
- Increased to t3.small (2 GB RAM)
- Containers: 2 × 512 MB = 1024 MB
- Page cache: ~800 MB
- Result: No swap, iowait < 5%, latency normal

### EFS Burst Credits

EFS operates in bursting mode by default:

- **Baseline throughput**: 50 KiB/s per GB stored
- **Burst throughput**: 100 MiB/s
- **Burst credits**: Accumulated when below baseline, consumed when bursting

For a 10 GB PyPI repository:
- Baseline: 500 KiB/s (very low)
- Typical CI burst: 20 MiB/s
- Credit consumption: 40× baseline
- Credits last: ~6 hours of continuous burst

**Implications**:
- Burst model works well for bursty CI workload
- Credits recharge during off-hours
- Long sustained bursts (e.g., migration) may deplete credits
- Monitor `BurstCreditBalance` via CloudWatch

### Alternative Approaches Considered

This section documents alternatives and why they weren't chosen:

#### Option 1: Re-enable Caching

**Approach**: Use `--backend auto` (default caching)

**Pros**:
- Much better performance (no directory scans)
- Lower EFS load
- Lower memory requirements

**Cons**:
- Cache synchronization bugs across distributed containers
- Non-deterministic stale reads (serious correctness issue)
- inotify doesn't work reliably on EFS/NFS

**Decision**: Rejected. Consistency is more important than performance.

#### Option 2: Redis-Backed Cache

**Approach**: External Redis for shared cache, invalidate on uploads

**Pros**:
- Consistent cache across containers
- Better performance than no cache

**Cons**:
- Adds complexity (Redis cluster management)
- Invalidation timing issues (eventual consistency)
- Additional cost
- Pypiserver doesn't support Redis backend natively

**Decision**: Rejected for now. May revisit if performance becomes critical.

#### Option 3: S3 Backend

**Approach**: Store packages in S3, use pypiserver S3 backend

**Pros**:
- Unlimited scalability
- Lower latency than EFS
- No burst credits to manage

**Cons**:
- Different module architecture (breaking change)
- S3 costs may be higher for high request volume
- Backend support varies by pypiserver version

**Decision**: Future consideration. Not suitable for quick fix.

#### Option 4: CloudFront + EFS

**Approach**: CloudFront in front of ALB for caching

**Pros**:
- HTTP-level caching
- Transparent to pypiserver
- Reduces backend load

**Cons**:
- Cache invalidation complexity on uploads
- Additional AWS component
- Cost

**Decision**: Recommended as optional enhancement for heavy workloads. Not in base module.

### Chosen Solution

**Increase memory allocation** to make `--backend simple-dir` performant:

1. Instance memory: page cache absorbs EFS metadata
2. Container memory: application has headroom
3. Monitoring: alerts on memory/EFS issues
4. Documentation: sizing guidance for users

This maintains correctness while achieving acceptable performance for typical workloads.