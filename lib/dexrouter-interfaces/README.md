# DexRouter thin ABI

`IDexRouter.sol` is a small ABI boundary for the DAG ERC-20 structs and `dagSwapTo` call used by the optional operator. Its upstream source revision is recorded in the Solidity header. This directory does not contain a router implementation.

Supply reviewed DexRouter, TokenApprove and TokenApproveProxy addresses in an explicitly selected deployment configuration; see the [operator guide](../../script/xlayer/README.md). The operator verifies `tokenApprove()` and `isAllowedProxy(dexRouter)` before simulation.

The external TSV adapter implementation is not a source dependency. [ITSVDEXAdapter.sol](../../src/v1/interfaces/external/ITSVDEXAdapter.sol) defines the unsigned `MoreInfo(PoolKey, expectedMultiplier, amountIn)` boundary. No backend signature or nonce is encoded. See [adapter integration](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md) for funding and allowlist requirements. Local ABI tests do not validate the deployed external implementation.
