.PHONY: check test test-unit test-local test-governance test-trading test-liquidity test-operations test-invariants test-xlayer coverage

check:
	python3 script/check-test-layout.py
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
	FOUNDRY_PROFILE=default forge test --match-path 'test/**/liquidity/*.t.sol' --summary

test-operations:
	FOUNDRY_PROFILE=default forge test --match-path 'test/**/{registry,reports,operations}/*.t.sol' --summary

test-invariants:
	FOUNDRY_PROFILE=default forge test --match-contract 'TSVStateful.*Test' --summary

test-xlayer:
	FOUNDRY_PROFILE=xlayer forge test --summary

coverage:
	FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary --exclude-tests
