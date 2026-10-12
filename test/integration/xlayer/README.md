# X Layer 历史部署清单

此目录当前只有 `deployment.json`，没有可执行的 `.t.sol` fork 套件。旧 `DexRouterFlow.t.sol` 已移除，历史通过数、部分成交退款与六组件部署说明不适用于当前代码。

`xlayer` Foundry profile 和 `make test-xlayer` 仍为后续恢复链上集成测试保留；执行时可能匹配零项，不能作为测试通过或链上验收证据。

当前 DEX、交易和 LP 的离线集成场景分别见 `test/integration/local/trading/` 和 `test/integration/local/deployment/LPHook.t.sol`。如恢复 fork 测试，需要按当前 Registry/Ledger/Hook/Router/LP 与 TSVAdapter ABI 重新接入，并重新核实部署清单、依赖版本和固定区块。
