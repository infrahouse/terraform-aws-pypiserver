# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]
## [2.0.0] - 2025-11-28

## [1.11.0] - 2025-11-28

### Added
- AWS provider v6 support (>= 5.11, < 7.0.0)
- Pytest parametrization to test both AWS provider v5 and v6
- Auto-generation of terraform.tf in tests for provider version control
- Architecture notes documentation explaining cache synchronization fix
- Comprehensive end-to-end validation testing (upload/download/install packages)
- Smart server readiness polling with timeout
- Auto-discovery of Internet Gateway from VPC subnets

### Changed
- Updated AWS provider constraint from ~> 5.11 to >= 5.11, < 7.0.0
- Default TEST_SELECTOR now uses aws-6 for testing
- Updated infrahouse/ecs/aws module version from 5.11.0 to 6.1.0
- Updated infrahouse/secret/aws module version from 1.1.0 to 1.1.1
- Enhanced variables with HEREDOC descriptions and comprehensive validations
- Refactored healthcheck from one-liner to proper Python script (files/healthcheck.py)
- Simplified requirements.txt to pytest-infrahouse + infrahouse-core
- Updated Makefile with separate targets for CI/CD vs local development

### Fixed
- Cache synchronization bug by adding --backend simple-dir flag
  - Prevents stale package listings across different gunicorn workers
  - Addresses unreliable inotify events on NFS/EFS (pypiserver issue #449)
- Hardcoded service_name in main.tf now uses var.service_name for reusability
- Conditional assume_role in test providers for local development
- Package installation now uses current pytest environment instead of nested venv

### Removed
- Obsolete test infrastructure (service-network, jumphost)
- internet_gateway_id variable (now auto-discovered)
- ssh_key_name variable (not needed with current setup)

## [1.10.0] - Previous Release

_Earlier release notes to be added from git history_

---

[Unreleased]: https://github.com/infrahouse/terraform-aws-pypiserver/compare/1.11.0...HEAD
[1.11.0]: https://github.com/infrahouse/terraform-aws-pypiserver/compare/1.10.0...1.11.0
[1.10.0]: https://github.com/infrahouse/terraform-aws-pypiserver/releases/tag/1.10.0