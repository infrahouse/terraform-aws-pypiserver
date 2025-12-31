.DEFAULT_GOAL := help

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
	match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
	if match:
		target, help = match.groups()
		print("%-40s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

TEST_REGION ?= "us-west-2"
TEST_ROLE ?= "arn:aws:iam::303467602807:role/pypiserver-tester"
TEST_SELECTOR ?= aws-6
KEEP_AFTER ?=
STRESS_TEST ?= test_stress_production_incident

# Function to run pytest without role (for CI/CD environment)
# Args: $(1) = test filter pattern, $(2) = test path, $(3) = force keep-after flag
define run_pytest
	pytest -xvvs \
		$(if $(or $(KEEP_AFTER),$(3)),--keep-after,) \
		-k "$(1)" \
		$(2) 2>&1 | tee pytest-`date +%Y%m%d-%H%M%S`-output.log
endef

# Function to run pytest with role (for local development)
# Args: $(1) = test filter pattern, $(2) = test path, $(3) = force keep-after flag
define run_pytest_with_role
	pytest -xvvs \
		--aws-region $(TEST_REGION) \
		--test-role-arn $(TEST_ROLE) \
		$(if $(or $(KEEP_AFTER),$(3)),--keep-after,) \
		-k "$(1) and $(TEST_SELECTOR)" \
		$(2) 2>&1 | tee pytest-`date +%Y%m%d-%H%M%S`-output.log
endef

help: install-hooks
	@python -c "$$PRINT_HELP_PYSCRIPT" < Makefile

.PHONY: install-hooks
install-hooks:  ## Install repo hooks
	@echo "Checking and installing hooks"
	@test -d .git/hooks || (echo "Looks like you are not in a Git repo" ; exit 1)
	@test -L .git/hooks/pre-commit || ln -fs ../../hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@test -L .git/hooks/commit-msg || ln -fs ../../hooks/commit-msg .git/hooks/commit-msg
	@chmod +x .git/hooks/commit-msg


.PHONY: test
test:  ## Run tests and clean up resources after (for CI/CD, no role assumption)
	@echo "Running tests with cleanup (no role)..."
	$(call run_pytest,test_,tests/test_module.py)

.PHONY: test-clean
test-clean:  ## Run tests and clean up resources after (for local, with role assumption)
	@echo "Running tests with cleanup (with role)..."
	$(call run_pytest_with_role,test_,tests/test_module.py)

.PHONY: test-keep
test-keep:  ## Run tests and keep resources for debugging (for local, with role assumption)
	@echo "Running tests with KEEP_AFTER=1 (with role)..."
	$(call run_pytest_with_role,test_,tests/test_module.py,1)

.PHONY: stress
stress:  ## Run stress test against existing PyPI server (run test-keep first). Override test with STRESS_TEST=test_name
	@echo "Running stress test: $(STRESS_TEST) with KEEP_AFTER=1 (with role)..."
	@echo "Region: $(TEST_REGION), Role: $(TEST_ROLE)"
	$(call run_pytest_with_role,$(STRESS_TEST),tests/test_stress.py,1)


.PHONY: lint
lint:  ## Check code style
	terraform fmt -check -recursive
	black --check tests/

.PHONY: bootstrap
bootstrap: install-hooks  ## Bootstrap the development environment
	pip install -U "pip ~= 25.2"
	pip install -U "setuptools ~= 80.9"
	pip install -r requirements.txt

.PHONY: clean
clean:  ## Clean the repo from cruft
	rm -rf .pytest_cache
	rm -rf test_data
	find . -name '.terraform' -exec rm -fr {} +
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	rm -rf .build
	rm -f pytest-*.log

.PHONY: fmt
fmt: format

.PHONY: format
format:  ## Format terraform and Python files
	@echo "Formatting terraform files"
	terraform fmt -recursive
	@echo "Formatting Python files"
	black tests/

define BROWSER_PYSCRIPT
import os, webbrowser, sys

from urllib.request import pathname2url

webbrowser.open("file://" + pathname2url(os.path.abspath(sys.argv[1])))
endef
export BROWSER_PYSCRIPT

BROWSER := python -c "$$BROWSER_PYSCRIPT"

.PHONY: docs
docs:  ## Generate module docs
	terraform-docs markdown .

# Internal function to handle version release
# Args: $(1) = major|minor|patch
define do_release
	@echo "Checking if git-cliff is installed..."
	@command -v git-cliff >/dev/null 2>&1 || { \
		echo ""; \
		echo "Error: git-cliff is not installed."; \
		echo ""; \
		echo "Please install it using one of the following methods:"; \
		echo ""; \
		echo "  Cargo (Rust):"; \
		echo "    cargo install git-cliff"; \
		echo ""; \
		echo "  Arch Linux:"; \
		echo "    pacman -S git-cliff"; \
		echo ""; \
		echo "  Homebrew (macOS/Linux):"; \
		echo "    brew install git-cliff"; \
		echo ""; \
		echo "  From binary (Linux/macOS/Windows):"; \
		echo "    https://github.com/orhun/git-cliff/releases"; \
		echo ""; \
		echo "For more installation options, see: https://git-cliff.org/docs/installation"; \
		echo ""; \
		exit 1; \
	}
	@echo "Checking if bumpversion is installed..."
	@command -v bumpversion >/dev/null 2>&1 || { \
		echo ""; \
		echo "Error: bumpversion is not installed."; \
		echo ""; \
		echo "Please install it using:"; \
		echo "  make bootstrap"; \
		echo ""; \
		exit 1; \
	}
	@BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$BRANCH" != "main" ]; then \
		echo "Error: You must be on the 'main' branch to release."; \
		echo "Current branch: $$BRANCH"; \
		exit 1; \
	fi; \
	CURRENT=$$(grep ^current_version .bumpversion.cfg | head -1 | cut -d= -f2 | tr -d ' '); \
	echo "Current version: $$CURRENT"; \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	PATCH=$$(echo $$CURRENT | cut -d. -f3); \
	if [ "$(1)" = "major" ]; then \
		NEW_VERSION=$$((MAJOR + 1)).0.0; \
	elif [ "$(1)" = "minor" ]; then \
		NEW_VERSION=$$MAJOR.$$((MINOR + 1)).0; \
	elif [ "$(1)" = "patch" ]; then \
		NEW_VERSION=$$MAJOR.$$MINOR.$$((PATCH + 1)); \
	fi; \
	echo "New version will be: $$NEW_VERSION"; \
	printf "Continue? (y/n) "; \
	read -r REPLY; \
	case "$$REPLY" in \
		[Yy]|[Yy][Ee][Ss]) \
			echo "Updating CHANGELOG.md with git-cliff..."; \
			git cliff --unreleased --tag $$NEW_VERSION --prepend CHANGELOG.md; \
			git add CHANGELOG.md; \
			git commit -m "chore: update CHANGELOG for $$NEW_VERSION"; \
			echo "Bumping version with bumpversion..."; \
			bumpversion --new-version $$NEW_VERSION patch; \
			echo ""; \
			echo "✓ Released version $$NEW_VERSION"; \
			echo ""; \
			echo "Next steps:"; \
			echo "  git push && git push --tags"; \
			;; \
		*) \
			echo "Release cancelled"; \
			;; \
	esac
endef

.PHONY: release-patch
release-patch:  ## Release a new patch version (e.g., 1.11.0 -> 1.11.1)
	$(call do_release,patch)

.PHONY: release-minor
release-minor:  ## Release a new minor version (e.g., 1.11.0 -> 1.12.0)
	$(call do_release,minor)

.PHONY: release-major
release-major:  ## Release a new major version (e.g., 1.11.0 -> 2.0.0)
	$(call do_release,major)
