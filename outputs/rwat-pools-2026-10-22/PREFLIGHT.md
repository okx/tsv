# RWAT 批量建池：执行前检查

日期：2026-10-22。状态：等待业务参数，尚未发送任何写交易。已创建 Pool 数量：0。

## 已确认的范围

- 网络：X Layer Mainnet（196，来自部署记录）。
- Registry：`0x2233ea2044ffa04ccceeef0b9adfe0799505a908`。
- 指定 Factory：`0x92cdb229613da8ca45e375cf69df4b3b645ff48d`；已通过链上 getter 确认 Registry 与 LP Manager 均绑定此地址。
- Factory PoolManager：`0x360e68faccca8ca495c1b759fd9eee466db9fb32`。
- LP Manager：`0xf73d8683b948564d2795c62a2a909012ea168d29`。
- Hook：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- Registry 未暂停。22 个 Token 的 decimals 均为 18、uiMultiplier 均为 1000000000000000000，Underlying 注册记录均为空。
- 已查 tier 1 容量/占用为 1/1，tier 2 为 2/2，tier 3–8 为 0/0；未查询其他 tier。
- 范围：每个 Token 部署 Adapter、直接转入底层 Token、Factory 验证、Underlying 注册、创建一个 Pool。不开启 Adapter 的 TSV wrapper/hook/swapping 权限，不注入流动性，不执行 swap。

## 待补充参数

1. 每个 Adapter 的底层 Token 转入金额。
2. QuoteToken 地址、池子 fee、tickSpacing、初始人类可读价格。
3. Adapter owner 和 allowlistChecker。
4. securityId 分配方式、tier；如无可用容量，是否配置新 tier。
5. 是否按需部署每个 U 对应的 ERC8056DirectLegalShareAdapter。

## Token 清单

| 序号 | Symbol | Underlying Proxy | Registry 注册 | 新 Adapter | 新 Pool ID |
| --- | --- | --- | --- | --- | --- |
| 1 | RWAT | `0x6C9E1F1E6A084e88C1f67f45Ccd473CA90c2fd13` | 未注册 | 未创建 | 未创建 |
| 2 | RWAT1 | `0x4dEEe58e069fd52Ce1db945699f15f03E049b920` | 未注册 | 未创建 | 未创建 |
| 3 | RWAT2 | `0x7AD9D70f30f31E39EA0046C35D196b8a9F3E81E9` | 未注册 | 未创建 | 未创建 |
| 4 | RWAT3 | `0xa9DBCf8904721810513B73cA6f4942dE8f8f99e7` | 未注册 | 未创建 | 未创建 |
| 5 | RWAT4 | `0xc2a611aBd4f3De5dc3BB22Af4063f9aee269255d` | 未注册 | 未创建 | 未创建 |
| 6 | RWAT5 | `0xb14034A0b533a88fc62AC2F577ed59FB0375b130` | 未注册 | 未创建 | 未创建 |
| 7 | RWAT6 | `0x947382f119Fe6f0344123A41B8833B969c9539b3` | 未注册 | 未创建 | 未创建 |
| 8 | RWAT7 | `0xbF6343896f1AdcACE43e810C1758b53A40DCEe95` | 未注册 | 未创建 | 未创建 |
| 9 | RWAT8 | `0x13160af212E62F12Eca804B91fEfe302a4EF4387` | 未注册 | 未创建 | 未创建 |
| 10 | RWAT9 | `0x8A2689465034031bf0F55E65f600CEE17bB0F6D3` | 未注册 | 未创建 | 未创建 |
| 11 | RWAT | `0x9a0E6B7C37873aF042A8959f4D5188B657204Aa6` | 未注册 | 未创建 | 未创建 |
| 12 | RWAT | `0xCCF3e98eb18f35A38fdd162ec5FFf5788FF01801` | 未注册 | 未创建 | 未创建 |
| 13 | RWAT | `0x5aA6dBc1C202cEA406910fe50e5e1d28FAbb5BDa` | 未注册 | 未创建 | 未创建 |
| 14 | RWAT | `0x4bEE53f182F871d1204D256Fe8e4265b23b7A261` | 未注册 | 未创建 | 未创建 |
| 15 | RWAT | `0x7283faBD88b147CD7e49F505AA1F848D6B14a95d` | 未注册 | 未创建 | 未创建 |
| 16 | RWAT | `0x531922E67811467D5dd5137755a38AeD15e5df35` | 未注册 | 未创建 | 未创建 |
| 17 | RWAT | `0xc9B54c9cC12983099fcD49F0357B08A2596f9C54` | 未注册 | 未创建 | 未创建 |
| 18 | RWAT | `0x78FA06BD9e8a7Af4aEe36F9Fa348080D2f27Bf46` | 未注册 | 未创建 | 未创建 |
| 19 | RWAT | `0xb879670887B5328e805309FD37f76A2F598e129D` | 未注册 | 未创建 | 未创建 |
| 20 | RWAT | `0x9eBc3dc2807F7323aCfe4B5f345291A4AD6b3F1B` | 未注册 | 未创建 | 未创建 |
| 21 | RWAT | `0xbaDeDb3F01632Bc1508F2A952472edF1fa3b808C` | 未注册 | 未创建 | 未创建 |
| 22 | RWAT | `0x45e33E9B75A3bd3BcC6aa3FDCa680248904A4cD1` | 未注册 | 未创建 | 未创建 |

## 证据与限制

- 输入：仓库根目录 `rwat-tokens.md`。
- `inventory.json`：22 个代理地址及只读查询映射。
- `rpc-preflight.json`：101 项查询的原始响应，其中 100 项成功；误用 `poolManager()` 的附加 Registry 查询回滚，源码实际 getter 为 `permissionedPoolManager()`。Factory 的 `POOL_MANAGER()` 已单独读取成功。
- `decoded-tokens.json`：Token 元数据和 Underlying 注册状态。
- 读取使用 latest，属于执行前观察，不是固定区块的一致快照。正式执行前需要重新检查参数相关状态及账户权限、余额。
- 所有成功写入的交易哈希、Adapter、LegalShareAdapter、securityId、PoolKey、Pool ID、初始化价格及零流动性校验，待实际执行后另行记录；本文件不代表部署成功。
