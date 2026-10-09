.PHONY: check build

check:
	forge fmt --check
	git diff --check

build:
	forge build src
