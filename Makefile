# SPDX-License-Identifier: GPL-2.0-only
.PHONY: check lint test test-shell test-python fmt

check: lint test

lint:
	./scripts/lint.sh

test: test-shell test-python

test-shell:
	./tests/run.sh

# Prefer the pytest launcher when present (Homebrew's python3 has no pytest
# module); fall back to the module form used by CI's python3-pytest package.
PYTEST := $(shell command -v pytest 2>/dev/null || echo python3 -m pytest)

test-python:
	@if ls acpi/tests/test_*.py >/dev/null 2>&1; then $(PYTEST) -q acpi/tests; else echo "no python tests yet"; fi

fmt:
	shfmt -w -i 4 -ci -bn $$(git ls-files '*.sh' '*.bash' 'cmd/*' 'lib/*' 'scripts/*' 2>/dev/null | grep -v '\.bats$$')
