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