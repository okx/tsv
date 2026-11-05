# External TSV DEX adapter boundary

TSV integrates an independently deployed adapter through the public `ITSVDEXAdapter` ABI in [src](../src/v1/interfaces/external/ITSVDEXAdapter.sol). No private adapter implementation or submodule is required to build or test TSV.

Use the deployment-configured adapter address. The operator checks its TSV_ROUTER binding, its DexRouter allowlist, the TSV Router adapter allowlist and settlement-currency mappings. The operator targets the unsigned seven-word MoreInfo payload: PoolKey, expectedMultiplier and amountIn; it does not encode a backend signature or nonce. Signed adapter versions are incompatible.

Repository tests cover TSV's own route authorization, settlement and operator encoding. External-adapter implementation tests were removed with the private dependency; they are not replaced by an assertion that a deployed adapter is safe. See [integration requirements](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).
