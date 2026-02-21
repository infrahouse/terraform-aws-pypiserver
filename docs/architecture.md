# Architecture

## Component Overview

![PyPI Server Architecture](assets/architecture.png)

## Request Flow

1. `pip install` or `twine upload` connects to the ALB over HTTPS
2. ALB terminates TLS using an ACM certificate (auto-provisioned and validated via DNS)
3. ALB forwards the request to a healthy ECS task (round-robin)
4. The pypiserver container authenticates the request using HTTP Basic Auth
5. For downloads: pypiserver scans the EFS-mounted packages directory and serves the file
6. For uploads: pypiserver writes the package to EFS; all containers see it immediately

## Why `--backend simple-dir`

Pypiserver supports two backends:

- **`cached-dir`** (default): Builds an in-memory index at startup, watches for changes
- **`simple-dir`**: Scans the directory on every request

This module uses `simple-dir` because `cached-dir` has a fundamental problem in a
distributed setup: each gunicorn worker in each container maintains its own cache.
When a package is uploaded, the receiving worker updates its cache, but workers in
other containers don't know about the new file until they happen to detect it through
filesystem events -- which is unreliable over NFS/EFS.

The trade-off: every request does a directory scan on EFS. This makes EFS metadata
performance the bottleneck, but guarantees consistency. The CloudWatch dashboard
tracks EFS I/O so you can monitor this directly.

## Auto-Calculation Logic

The module automatically calculates task counts and resource allocation from the
instance type. The goal is to fully utilize each instance without overcommitting.

### Tasks per Instance

```
available_ram = instance_memory - 300 MB (system) - 512 MB (page cache)
available_cpu = instance_cpu - 128 units (ECS agent, CloudWatch)

tasks_per_instance = min(
  floor(available_ram / container_memory_reservation),
  floor(available_cpu / container_cpu)
)
```

### Gunicorn Workers

```
workers = max(2, min(8, floor(container_memory / 128)))
```

### Container CPU

```
cpu_units = (gunicorn_workers × 150) + 40
```

### Example: t3.small (2 vCPU, 2 GB)

With default settings (512 MB container memory, auto-calculated CPU):

| Parameter | Value |
|-----------|-------|
| Gunicorn workers | 4 |
| Container CPU | 640 units |
| Container memory reservation | 384 MB (75% of 512) |
| Available RAM | 1248 MB |
| Available CPU | 1920 units |
| Tasks per instance (RAM) | 3 |
| Tasks per instance (CPU) | 3 |
| **Tasks per instance** | **3** |
| **Total tasks (2 instances)** | **6** |

## Security Model

- **Network isolation**: ECS tasks run in private subnets; only the ALB is public
- **Encryption at rest**: EFS encrypted with the `aws/elasticfilesystem` KMS key
- **Encryption in transit**: HTTPS enforced via ACM certificate on ALB
- **Authentication**: HTTP Basic Auth for all operations (download, list, upload)
- **Credentials**: Auto-generated, stored in Secrets Manager, accessible via IAM
- **IAM**: Least-privilege roles for ECS tasks, backup operations, and instance profiles
- **Security groups**: EFS SG allows NFS (port 2049) from VPC CIDR only
