PYTHON ?= python3

.PHONY: check-all check-shell test

check-all: check-shell test

check-shell:
	@for script in bin/*.sh; do bash -n "$$script" || exit 1; done

test:
	$(PYTHON) -W error -m unittest discover -s tests -p 'test_*.py' -v
