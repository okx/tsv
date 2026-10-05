# DEX Router 薄接口

接口字段、DAG 入口签名及 `sellBase/sellQuote` 格式来自 [OKX Labs 公共仓库](https://github.com/okxlabs/Web3-DEX-Router-EVM-V1/tree/1fc1508df3caeb18a8179dfc0ea4e956099ab481)，commit `1fc1508df3caeb18a8179dfc0ea4e956099ab481`。不把整套上游合约加入 TSV 的编译依赖，避免其固定 Solidity 0.8.17 与项目 0.8.26 冲突。

用户提供的内部仓库 HTTPS 拉取需要登录；本机另已下载公共源码至忽略的 `lib/dexrouter/`。测试只依赖这里提交的 ABI，无需该可选 checkout。

X Layer 指定地址的版本为 `v1.0.10-rfq-anti-arbitrage`，与公共源码当前版本不同。因此这里只复用经实际 fork 调用验证的 ABI，**不声称公共源码与该部署的全部字节码一致**。部署地址、固定区块、执行模块和授权合约 codehash 见 `test/integration/xlayer/deployment.json`。

正式 Adapter 使用 `lib/dex-adapters` 子模块的固定提交 `e38c6b109875893ad037677eb8d8221fa4b5687b`，实现为 `src/adapters/uniswap-v4/TSVAdapter.sol`。测试直接部署该上游合约，不再使用本地重实现。`test/helpers/v1/TSVAdapterFixture.sol` 仅构造测试签名和路由数据。

Adapter 要求 callback 的最后两个 32-byte word 分别为 `DEX_ROUTER_CALLER_MARKER | DexRouter调用者`、`ORIGIN_PAYER | refundTo`；前者用于 SBT，后者仅退款。身份不再从退款字段提取。固定部署的实际兼容性由 `test/integration/xlayer/DexRouterFlow.t.sol` 验证。

初始化依赖：`git submodule update --init lib/dex-adapters`。Foundry 使用上下文 remapping，仅为该依赖解析 `@interfaces` / `@libraries`，不替换 TSV 自身依赖。
