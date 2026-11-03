# Securitize 分发合约测试替身

`MockSecuritizeDisperse.sol` 按照 [Securitize distribution contract 文档](https://okg-block.sg.larksuite.com/wiki/PrQCwWK8LiTpg2k8KUulTIGTgNc) 实现最小可用的 ERC-20 批量派息流程，供模拟项目方和事件索引测试使用。这是独立编写的测试合约，非 Securitize 官方实现。

## 本版本约定

- 非代理、不可升级，没有暂停功能。
- 构造参数 `initialAdmin` 指定管理员；管理员需要用 `addOperator(account)` 单独授予付款操作权限，可以授予自己。
- `MAX_BATCH_SIZE = 200`，是本模拟版本选取的上限，原文未给出具体值。
- `DUPLICATE_WINDOW = 10 minutes`，按本次测试需求设定，原文未给出具体值。
- Solidity 使用 `^0.8.22`，兼容原文语言版本及仓库固定的 0.8.26 编译器。
- 使用仓库现有 OpenZeppelin AccessControl、SafeERC20 和 ReentrancyGuard，无新增依赖。

## 模拟付款

1. 部署 `MockSecuritizeDisperse(initialAdmin)`。
2. 管理员调用 `addOperator(operator)`。
3. 给 operator 钱包准备支付代币。
4. **operator 钱包**在支付代币合约调用 `approve(disperseAddress, total)`，其中 `total = sum(amounts)`。
5. **同一个 operator 钱包**调用：

   ```solidity
   disperseToken(
       payoutToken,
       [recipientA, recipientB],
       [amountA, amountB]
   );
   ```

   数组仅为参数示意。`amounts` 是支付代币原始单位：例如测试代币为 6 位精度，支付 100 个代币应填 `100_000_000`。

6. 成功时两个条目产生两条 `Paid`，批次结束产生一条 `Dispersed`。合约先从调用人拉取总额再转出，正常 ERC-20 的本次分发资金不会留在合约里。此前误转的余额不会被当作本次付款的资金，管理员可以用 `rescue` 取回。

## 防重复与失败重试

批次标识为 `keccak256(abi.encode(payoutToken, recipients, amounts))`，与 operator 无关，数组顺序影响标识。成功付款后的 **600 秒内**，相同批次报 `DuplicateBatch`；第 600 秒可以再次支付，成功后重新起算窗口。

任意条目无效、付款授权不足、余额不足、收款人被代币拒绝或入账金额不等于批次总额，整笔交易回滚，包括已执行的转账、事件和防重时间。因此修复原因后可立即重试。重复收款地址按独立条目处理，不自动合并；重排数组或拆批会改变 hash，业务系统仍需防止重复支付。

入账检查拒绝常见的转账扣费代币，但不会逐个检查收款人实际到账余额；测试应使用普通 ERC-20，不用本替身保证扣费、重基或其他特殊代币的净到账行为。

## 角色及维护方法

`isAdmin` / `isOperator` 查询权限。管理员可用 `addOperator`、`revokeOperator` 管理付款人，或用 `changeAdmin` 将自己的管理员角色移交给其他非零地址；已有的其他管理员不受影响。

继承的 `grantRole` 也会发出 `AdminGranted` / `OperatorAdded`。撤销或放弃管理员角色会发出 `AdminRevoked`。操作员角色必须通过 `revokeOperator` 撤销，直接 `revokeRole(OPERATOR_ROLE, ...)` 或 `renounceRole(OPERATOR_ROLE, ...)` 按原文报 `UseRevokeOperator`。

## 本地构建、测试和 ABI

在仓库根目录运行，不需要 RPC 或私钥：

```sh
forge test --root lib/TestToken/securitize-disperse -vv
forge inspect --root lib/TestToken/securitize-disperse MockSecuritizeDisperse abi --json
```

目录自带独立 Foundry 配置，仅编译本合约及其测试，使用仓库已有依赖。部署后只需把该地址当作模拟项目方的分发合约调用；本测试替身不绑定 TSV Registry，也不计算持股快照或分红资格。
