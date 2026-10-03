# DEX Router 薄接口

接口字段、DAG 入口签名及 `sellBase/sellQuote` 格式来自 [OKX Labs 公共仓库](https://github.com/okxlabs/Web3-DEX-Router-EVM-V1/tree/1fc1508df3caeb18a8179dfc0ea4e956099ab481)，commit `1fc1508df3caeb18a8179dfc0ea4e956099ab481`。不把整套上游合约加入 TSV 的编译依赖，避免其固定 Solidity 0.8.17 与项目 0.8.26 冲突。

用户提供的内部仓库 HTTPS 拉取需要登录；本机另已下载公共源码至忽略的 `lib/dexrouter/`。测试只依赖这里提交的 ABI，无需该可选 checkout。

X Layer 指定地址的版本为 `v1.0.10-rfq-anti-arbitrage`，与公共源码当前版本不同。因此这里只复用经实际 fork 调用验证的 ABI，**不声称公共源码与该部署的全部字节码一致**。部署地址、固定区块、执行模块和授权合约 codehash 见 `test/integration/xlayer/deployment.json`。

该部署给 Adapter callback 追加两个 32-byte word，最后一项为 `ORIGIN_PAYER | 原始调用者`。测试 Adapter 只接受固定 DEX 地址的 callback，并校验长度和身份标记；额外的一项不作为身份来源。`test/helpers/v1/DexRouterTestAdapter.sol` 是测试夹具，仍需开发与审查正式 Adapter。
