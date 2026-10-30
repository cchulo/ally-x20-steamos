# SPDX-License-Identifier: GPL-2.0-only
.PHONY: check lint test test-shell test-python fmt

check: lint test

lint:
	./scripts/lint.sh

test: test-shell test-python

test-shell:
	./tests/run.sh

test-python:
	@if ls acpi/tests/test_*.py >/dev/null 2>&1; then python3 -m pytest -q acpi/tests; else echo "no python tests yet"; fi

fmt:
	shfmt -w -i 4 -ci -bn $$(git ls-files '*.sh' '*.bash' 'cmd/*' 'lib/*' 'scripts/*' 2>/dev/null | grep -v '\.bats$$')
