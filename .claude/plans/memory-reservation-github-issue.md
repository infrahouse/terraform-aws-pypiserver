# GitHub Issue: Add support for `container_memory_reservation`

**Title**: Add support for container memory reservation (soft limit)

---

## Summary

Add support for the ECS `memoryReservation` parameter to allow containers to burst above their reserved memory while maintaining efficient bin packing on EC2 instances.

## Problem Statement

Currently, the module only supports `container_memory` (hard limit), which forces users to choose between:

1. **Sizing for worst-case**: Set `container_memory` high to handle bursts → wastes memory during normal operation → poor instance utilization
2. **Sizing for average**: Set `container_memory` low → containers get OOM killed during bursts → service disruptions

This is particularly problematic for bursty workloads (CI/CD, batch processing, request spikes) where memory usage fluctuates significantly.

## Proposed Solution

Add `container_memory_reservation` variable to support ECS's soft memory limit feature.

### How Memory Reservation Works

AWS ECS supports two memory parameters that work together:

- **`memoryReservation` (soft limit)**: Minimum memory ECS reserves for bin packing. Container is guaranteed this amount.
- **`memory` (hard limit)**: Maximum memory the container can use. Container is OOM killed if exceeded.

**Behavior**:
```
0 MB ----[memoryReservation]----[actual usage]----[memory]---- ∞
         ^                       ^                 ^
         Reserved for            Can grow          Hard ceiling
         scheduling              dynamically       (OOM kill)
```

**Key points**:
- ECS uses `memoryReservation` for task placement decisions (bin packing)
- Containers can use more than reserved if available on the instance
- Containers cannot exceed `memory` hard limit
- If only `memory` is set, ECS uses it for both reservation and limit

### Benefits

#### 1. Better Instance Utilization

**Current behavior** (memory only):
```hcl
container_memory = 512  # Must size for worst case

Instance (2 GB RAM):
  Task 1: 512 MB reserved
  Task 2: 512 MB reserved
  Task 3: 512 MB reserved
  Task 4: 512 MB reserved
  Total: 2048 MB → Full (4 tasks)
```

**With memory reservation**:
```hcl
container_memory = 512              # Burst ceiling
container_memory_reservation = 256  # Normal operation

Instance (2 GB RAM):
  Task 1-8: 256 MB × 8 = 2048 MB reserved
  Total: 2048 MB → Full (8 tasks)

Each task can still burst to 512 MB if needed
```

**Result**: 2× task density on same hardware

#### 2. Cost Optimization

**Example**: Service needs to handle 10 tasks during peak load

| Configuration | Reserved per task | Instance requirement | Cost/month |
|--------------|-------------------|---------------------|------------|
| Memory only | 512 MB | 2× t3.medium (8 GB) | ~$60 |
| With reservation | 256 MB (burst 512) | 1× t3.medium (4 GB) | ~$30 |

**Savings**: 50% infrastructure cost

#### 3. Better Handling of Bursty Workloads

Common pattern: Low baseline memory, occasional spikes

**Examples**:
- Web servers: 200 MB baseline, 500 MB during traffic spikes
- Batch processors: 150 MB idle, 400 MB during job execution
- API services with CI/CD: 128 MB normal, 300+ MB during dependency resolution (pip/npm)

**Without reservation**: Must set `memory = 500 MB` → wastes 300 MB most of the time

**With reservation**: Set `reservation = 200 MB, memory = 500 MB` → reserves only 200 MB, allows bursts

## Use Cases

### Real-World Example: PyPI Server

From production incident analysis:

**Workload characteristics**:
- Normal operation: ~128 MB per container
- CI/CD burst: ~300-400 MB (pip install, dependency resolution)
- Peak spikes: Can reach 500 MB

**Current approach** (no reservation):
```hcl
container_memory = 512  # Must handle worst case
```
- Instance fits 4 tasks on t3.small (2 GB)
- Wastes ~384 MB per task during normal operation (75% waste)

**With reservation**:
```hcl
container_memory = 512
container_memory_reservation = 256
```
- Instance fits 8 tasks on t3.small
- Each can burst to 512 MB when needed
- 2× better utilization

### Other Applicable Scenarios

1. **Development/staging environments**: Lower reservation, same burst capacity as prod
2. **Microservices**: Different services have different burst patterns
3. **Background workers**: Low idle memory, high during job processing
4. **Scheduled tasks**: Minimal reservation most of the time, burst during execution windows

## Proposed Implementation

### 1. Add Variable

**File**: `variables.tf`

```hcl
variable "container_memory_reservation" {
  description = <<-EOT
    Soft memory limit in MB. The amount of memory reserved for the container.
    ECS uses this value for task placement (bin packing).
    Container can use more than this if available on the instance, up to container_memory.
    If null, defaults to container_memory (no bursting).
    Must be less than or equal to container_memory if both are set.
    See: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#container_definition_memory
  EOT
  type        = number
  default     = null

  validation {
    condition = var.container_memory_reservation == null || (
      var.container_memory_reservation > 0 &&
      var.container_memory_reservation <= var.container_memory
    )
    error_message = "container_memory_reservation must be greater than 0 and less than or equal to container_memory"
  }
}
```

### 2. Update Task Definition

**File**: `main.tf` (or wherever task definition is created)

```hcl
resource "aws_ecs_task_definition" "service" {
  # ... existing configuration ...

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.docker_image
      cpu       = var.container_cpu
      memory    = var.container_memory

      # Add memory reservation if specified
      memoryReservation = var.container_memory_reservation

      # ... rest of container definition ...
    }
  ])
}
```

**Note**: Only include `memoryReservation` in JSON if not null, or ECS will accept null values.

### 3. Update README

**File**: `README.md`

Add to variables documentation:

```markdown
### Memory Configuration

The module supports both hard and soft memory limits:

- `container_memory` (required): Hard limit in MB. Container is killed if exceeded.
- `container_memory_reservation` (optional): Soft limit in MB for bin packing.

**Recommended pattern for bursty workloads**:
```hcl
module "ecs_service" {
  source = "infrahouse/ecs/aws"

  container_memory              = 512   # Maximum burst
  container_memory_reservation  = 256   # Normal operation

  # ... other configuration ...
}
```

This reserves 256 MB for scheduling but allows bursts up to 512 MB.

### 4. Add Example

**File**: `examples/with-memory-reservation/main.tf` (new example)

```hcl
module "bursty_service" {
  source = "../.."

  service_name     = "api-service"
  docker_image     = "myapp:latest"
  container_cpu    = 256

  # Size for bursts, reserve for baseline
  container_memory             = 512
  container_memory_reservation = 256

  # ... other required variables ...
}
```

## Testing Considerations

1. **Backwards compatibility**:
   - Default `container_memory_reservation = null` maintains current behavior
   - Existing users unaffected

2. **Test cases**:
   - ✅ With `memory` only (current behavior, no reservation)
   - ✅ With both `memory` and `memoryReservation`
   - ✅ Validation: `memoryReservation > memory` should fail
   - ✅ Validation: `memoryReservation = 0` should fail
   - ✅ Task placement respects reservation (verify via ECS console)

3. **Integration test**:
   - Deploy service with reservation < memory
   - Verify tasks are scheduled based on reservation
   - Verify tasks can burst above reservation (memory stress test)

## AWS Documentation References

- [Task Definition Parameters - Memory](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#container_definition_memory)
- [Task Definition Template - Container Definitions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#container_definitions)
- [AWS ECS Best Practices - Right-sizing](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/capacity-tasksize.html)

## Related Issues/PRs

This feature is commonly requested in other ECS modules:
- terraform-aws-modules/ecs#XXX
- AWS Provider supports it natively in `aws_ecs_task_definition`

## Checklist

Implementation checklist:

- [ ] Add `container_memory_reservation` variable with validation
- [ ] Update task definition to include `memoryReservation` when specified
- [ ] Update README with memory configuration guidance
- [ ] Add example demonstrating memory reservation usage
- [ ] Add validation tests
- [ ] Update CHANGELOG
- [ ] Bump minor version (non-breaking change)

---

## Additional Context

This feature request comes from production experience with a PyPI server deployment where:
- Memory usage during normal operation: ~128-256 MB
- Memory usage during CI bursts (pip install): ~300-500 MB
- Current solution wastes significant instance capacity by sizing for worst case
- Memory reservation would enable 2× task density on same hardware

The implementation is straightforward and follows AWS ECS best practices for right-sizing containers with variable workloads.
