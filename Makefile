.PHONY: build check test test-unit test-local test-governance test-trading test-liquidity test-operations test-invariants test-xlayer coverage artifacts artifacts-check

build:
	forge build

check:
	python3 script/check-test-layout.py
	python3 script/check-public-docs.py
	forge fmt --check
	git diff --check

test:
	python3 script/check-test-layout.py
	FOUNDRY_PROFILE=default forge test --summary

test-unit:
	FOUNDRY_PROFILE=unit forge test --summary

test-local:
	FOUNDRY_PROFILE=local forge test --summary

test-governance:
	FOUNDRY_PROFILE=default forge test --match-path 'test/**/governance/*.t.sol' --summary

test-trading:
	FOUNDRY_PROFILE=default forge test --match-path 'test/**/trading/*.t.sol' --summary

test-liquidity:
	FOUNDRY_PROFILE=default forge test --match-contract '(TSVLP.*Test|LP.*Test|TSVHookInitializationTest)' --summary

test-operations:
	FOUNDRY_PROFILE=default forge test --match-path 'test/unit/v1/registry/*.t.sol' --summary

test-invariants:
	FOUNDRY_PROFILE=default forge test --match-test '^invariant' --summary

test-xlayer:
	FOUNDRY_PROFILE=xlayer forge test --summary

coverage:
	FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary --exclude-tests

artifacts:
	python3 script/update-contract-artifacts.py

artifacts-check:
	python3 script/update-contract-artifacts.py --check
