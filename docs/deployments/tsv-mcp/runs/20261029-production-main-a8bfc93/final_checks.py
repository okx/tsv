"""Read-only final checks; upgrade calls below are eth_call simulations only."""
import json
from pathlib import Path
import continue_deployment as dep

P = Path(__file__).resolve().parent
m = json.loads((P / "manifest.json").read_text())
a = json.loads((P / "addresses.json").read_text())["addresses"]
expected = {"PermissionedValidationLib", "TSVLPManagerLib", "LPPositionMath", "PermissionsAdapterFactory", "TSVHookProxyFactoryV1"}
components = ["TSVRegistryV1", "TSVVolumeLedgerV1", "TSVSwapRouterV1", "TSVLPManagerV1", "TSVHookV1"]
expected.update(components)
expected.update(name + "Proxy" for name in components)
assert set(a) == expected and len(a) == 15
block = dep.result("eth_blockNumber", [])
invalid_init = dep.cast("sig", "InvalidInitialization()")
checks = {"checkedAt": dep.now(), "block": int(block, 16), "components": {}, "scope": m["scope"]}
for name in components:
    impl, proxy = a[name], a[name + "Proxy"]
    if name == "TSVRegistryV1":
        signature, args = "initialize(address)", [m["registryInitialAdmin"]]
    elif name == "TSVSwapRouterV1":
        signature, args = "initialize(address,address)", [m["dependencies"]["poolManager"], a["TSVRegistryV1Proxy"]]
    elif name == "TSVHookV1":
        signature, args = "initialize(address,address,address,address,address)", [m["dependencies"]["poolManager"],
            a["TSVRegistryV1Proxy"], a["TSVVolumeLedgerV1Proxy"], a["TSVSwapRouterV1Proxy"], a["TSVLPManagerV1Proxy"]]
    else:
        signature, args = "initialize(address)", [a["TSVRegistryV1Proxy"]]
    initialization = dep.cast("calldata", signature, *args)
    component = {"implementation": impl, "proxy": proxy}
    for kind, address in [("implementation", impl), ("proxy", proxy)]:
        response = dep.rpc("eth_call", [{"from": m["privilegeAddress"], "to": address, "data": initialization}, block])
        assert "error" in response and invalid_init.lower() in json.dumps(response).lower(), (name, kind, response)
        component[kind + "InitializationBlocked"] = response
    upgrade = dep.cast("calldata", "upgradeToAndCall(address,bytes)", impl, "0x")
    admin = dep.rpc("eth_call", [{"from": m["registryInitialAdmin"], "to": proxy, "data": upgrade}, block])
    assert "result" in admin, (name, "authorized upgrade simulation failed", admin)
    deployer = dep.rpc("eth_call", [{"from": m["privilegeAddress"], "to": proxy, "data": upgrade}, block])
    assert "error" in deployer, (name, "unauthorized deployer upgrade succeeded")
    component["adminSameImplementationUpgradeSimulation"] = admin
    component["deployerUpgradeRejected"] = deployer
    checks["components"][name] = component
    dep.save(P / "final-checks-progress.json", checks)

reg = a["TSVRegistryV1Proxy"]
unconfigured = {}
for getter in ["hook()", "lpManager()", "permissionsAdapterFactory()", "permissionedPoolManager()"]:
    value = dep.call(reg, getter, block=block)
    unconfigured[getter] = value
unconfigured["participantSbt()"] = dep.call(reg, "participantSbt()", block=block)
checks["registryBusinessBindings"] = unconfigured
checks["registryBusinessBindingsConfigured"] = all(int(value, 16) != 0 for value in unconfigured.values())
checks["registryIsPaused"] = bool(int(dep.call(reg, "isPaused()", block=block), 16))
hashed_type = dep.cast("keccak", "EIP712Domain(string name,uint256 chainId,address verifyingContract)")
hashed_name = dep.cast("keccak", "Uniswap v4 Positions NFT")
encoded = dep.cast("abi-encode", "f(bytes32,bytes32,uint256,address)", hashed_type, hashed_name, "196", a["TSVLPManagerV1Proxy"])
expected_domain = dep.cast("keccak", encoded)
actual_domain = dep.call(a["TSVLPManagerV1Proxy"], "DOMAIN_SEPARATOR()", block=block)
assert actual_domain.lower() == expected_domain.lower()
checks["lpProxyEip712DomainMatchesProxyAndChain"] = {"expected": expected_domain, "actual": actual_domain}
assert int(a["TSVHookV1Proxy"], 16) & 0x3FFF == 0x3FFF
checks["hookAddressPermissionBits"] = "0x3fff"
checks["status"] = "ALL_FINAL_CHECKS_PASSED"
checks["noWriteTransactionsPerformedByTheseChecks"] = True
dep.save(P / "final-checks.json", checks)
print(json.dumps({"status": checks["status"], "implementationsLocked": 5, "proxiesLocked": 5,
    "authorizedUpgradeSimulationsPassed": 5, "unauthorizedUpgradeSimulationsRejected": 5,
    "businessBindingsConfigured": checks["registryBusinessBindingsConfigured"], "lpEip712ProxyDomainVerified": True}))
