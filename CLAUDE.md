# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## First Steps

**Your first tool call in this repository MUST be reading .claude/CODING_STANDARD.md.
Do not read any other files, search, or take any actions until you have read it.**
This contains InfraHouse's comprehensive coding standards for Terraform, Python, and general formatting rules.

## What This Module Does

Terraform module that deploys a private PyPI server on AWS using ECS, EFS, and ALB. The module auto-calculates task counts and resource allocation from instance type selection, manages credentials via AWS Secrets Manager, and includes EFS backup, CloudWatch alarms, and dashboards.

Key architectural decision: uses `--backend simple-dir` (no caching) to avoid cache synchronization bugs across distributed gunicorn workers on EFS. See `.claude/architecture-notes.md` for rationale.

## Common Commands

```bash
make bootstrap          # Install dependencies and git hooks
make lint               # Check formatting (terraform fmt, black)
make format             # Auto-format all code (or: make fmt)
make docs               # Regenerate terraform-docs
make test-clean         # Run tests with cleanup (local dev, assumes IAM role)
make test-keep          # Run tests, keep infrastructure for debugging
make stress             # Run stress tests (run test-keep first)
make release-patch      # Bump patch version (must be on main)
```

Run a single test locally:
```bash
pytest -xvvs --aws-region us-west-2 --test-role-arn "arn:aws:iam::303467602807:role/pypiserver-tester" --keep-after -k "test_name and aws-6" tests/test_module.py
```

## Architecture

- **main.tf** — ECS service via `registry.infrahouse.com/infrahouse/ecs/aws` module, container configuration, capacity auto-calculation logic (locals at top)
- **variables.tf** — 24+ inputs with validation; many have auto-calculating defaults
- **outputs.tf** — URLs, credentials, ECS/ASG identifiers, monitoring links
- **efs-common.tf / efs-enc.tf** — Encrypted EFS for shared package storage
- **backup.tf** — AWS Backup vault and plan for EFS
- **cloudwatch-alarms.tf / cloudwatch-dashboard.tf** — Monitoring infrastructure
- **htpasswd.tf** — Auto-generated credentials stored in Secrets Manager
- **test_data/pypiserver/** — Test harness that instantiates this module

Tests in `tests/` use `pytest-infrahouse` fixtures and deploy real AWS infrastructure. Tests create actual ECS clusters, so they take significant time and require AWS credentials.

## Conventions

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`
- Module dependencies use exact version pins (no ranges)
- Pre-commit hooks enforce `terraform fmt` and `black` formatting
- The module uses a private Terraform registry at `registry.infrahouse.com`
- Provider configuration requires an aliased `aws.dns` provider for Route53
