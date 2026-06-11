# Plan: Enable cross-region replication on the pypiserver ALB access-log bucket

## Context

`terraform-aws-pypiserver` deploys the pypiserver service through `infrahouse/ecs/aws`, which
creates the ALB access-log S3 bucket (`pypise-access-log-*` in our deployment). That bucket
has no cross-region replication, so it fails the Vanta test
`aws-s3-cross-region-replication-enabled`. ALB access logs are an audit record under the
InfraHouse compliance policy (§6/§7.1) and must get CRR, not a Vanta exemption.

The ECS module already supports CRR via a `replication_region` input (wired to the access-log
bucket through its website-pod submodule), but **only from v8.1.0+**. This module currently
pins `infrahouse/ecs/aws` at `7.12.0`, which predates the input, and never passes it.

## Changes (this repo)

1. In `main.tf`, bump the `infrahouse/ecs/aws` module pin from `7.12.0` to the latest release
   (`>= 8.1.0`). Confirm that version exposes `replication_region`.
2. Add a `replication_region` variable (`variables.tf`):
   ```hcl
   variable "replication_region" {
     description = <<-EOT
       AWS region for cross-region replication of the ALB access-log bucket.
       Must differ from the region this module is deployed in (a same-region replica still
       fails the Vanta CRR test).
     EOT
     type = string
   }
   ```
3. Pass it into the ECS module call: `replication_region = var.replication_region`.
4. Reconcile the ECS **7.x -> 8.x major bump** (read the ECS CHANGELOG; fix renamed/required
   inputs) so `terraform validate` and the module tests pass. Do not silence failures.
5. Regenerate `README.md` docs (terraform-docs). Open a PR; do not merge.
   Do not bump the module version or update `CHANGELOG.md`.

## Acceptance criteria

- [ ] `replication_region` exposed (required, no default), passed to `infrahouse/ecs/aws`.
- [ ] ECS pin `>= 8.1.0`; `terraform validate` + tests pass.
- [ ] README updated (no version bump, no CHANGELOG change).

## Constraints

- Public module `infrahouse/terraform-aws-pypiserver` — keep generic, no consumer-specific
  account IDs or regions baked in (`replication_region` is required, caller supplies it).
- Same-region guard: replica region must differ from the deployment region.
- Scope = the access-log bucket only; do not touch the pypiserver app/data path.

## Follow-up (separate repo)

After release, bump `infrahouse/pypiserver/aws` in `aws-control-prod` (currently `2.3.0`), set
`replication_region = "us-east-1"`, `apply`, then run S3 batch replication to backfill so
`pypise-access-log-*` goes green in Vanta.

## Module chain

terraform-aws-pypiserver -> infrahouse/ecs/aws (>= 8.1.0, replication_region) -> website-pod
-> infrahouse/s3-bucket/aws (replication resources).
