# TSVLPManagerV1_multicall_接口ABI与calldata构建说明

本文参照《TSV_证券暂停_额度维护与授权强退_接口事件》的接口定义方式，说明 multicall 的 ABI、参数、返回值、调用权限、calldata 构建及后台验收方式，并以批量调用 unwindPositionByTsv 为例。

核对日期：2026-10-21。依据当前本地源码及编译产物；仓库 HEAD 为 bcdace150aadd84c1215437e64f857e6975ed26e，工作区存在其他未提交改动。本次未核对线上代理的实际 implementation，未发送链上交易。示例 tokenId 123、456 仅用于编码演示。

## 1. 接口所属合约与调用约定

| 项目 | 定义 |
| --- | --- |
| 所属合约 | TSVLPManagerV1 |
| 交易目标 to | 目标网络的 TSVLPManagerV1 代理地址；无需单独部署 Multicall 合约 |
| Solidity 签名 | multicall(bytes[] data) payable returns (bytes[] results) |
| 标准函数签名 | multicall(bytes[]) |
| 函数 selector | 0xac9650d8 |
| stateMutability | payable |
| 执行方式 | 按数组顺序，对 address(this) 执行 delegatecall |
| 全局限制 | Registry 未暂停；暂停时抛出 RegistryPaused() |
| 身份与状态 | 子调用沿用外层 msg.sender、msg.value 和 LP Manager 的存储上下文 |
| 原子性 | 任一子调用失败，整笔交易回滚；原样向上传递该子调用的 revert data |
| 数量限制 | 本实现未设置数组长度上限；实际受交易/区块 gas、calldata 和 RPC 限制 |
| 自有事件 | multicall 本身不定义成功或失败事件；监听具体子调用事件 |

一次 multicall 是一笔交易，内部包含 N 次函数调用，不是 N 笔独立交易。全部执行成功时，返回数组与输入数组一一对应。前面的调用修改状态后，后面的调用立即看到修改后的状态。

这是同一 LP Manager 的批量入口，不是带有 target、allowFailure、value 字段的通用 Multicall3。不能向 data 数组直接放入 Registry 或其他合约的调用并期待其自动转发。

## 2. 可直接使用的 ABI

### 2.1 multicall 标准 JSON ABI

以下 ABI 与本地 out/TSVLPManagerV1.sol/TSVLPManagerV1.json 中的条目一致。

```json
[
  {
    "type": "function",
    "name": "multicall",
    "inputs": [
      {
        "name": "data",
        "type": "bytes[]",
        "internalType": "bytes[]"
      }
    ],
    "outputs": [
      {
        "name": "results",
        "type": "bytes[]",
        "internalType": "bytes[]"
      }
    ],
    "stateMutability": "payable"
  }
]
```

### 2.2 ethers.js human-readable ABI

事件定义来自 TSVLPManagerLib。若仅使用 LP Manager 编译 ABI 而没有库事件条目，监听端需要合并该事件 ABI。

```javascript
const ABI = [
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function unwindPositionByTsv(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "error RegistryPaused()",
  "error AccessControlUnauthorizedAccount(address account,bytes32 neededRole)",
  "event TsvPositionUnwound(uint256 indexed tokenId,address indexed lpOwner,address indexed issuer,address token0,address token1,uint256 lpReceivedAmount0,uint256 issuerReceivedAmount0,uint256 lpReceivedAmount1,uint256 issuerReceivedAmount1)"
];
```

注意大小写：真实函数名是 unwindPositionByTsv，不是 unwindPositionByTSV。其 selector 为 0xa661b4c0。

## 3. 参数、返回值与交易字段

### 3.1 multicall 入参

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| data | bytes[] | 子调用的完整 calldata 数组，按下标顺序执行 |
| data[i] | bytes | 4 字节子函数 selector，加上该函数参数的标准 ABI 编码；不包含目标地址 |
| data.length | 数组长度 | 本次子调用数量；传空数组时，仅经过外层暂停检查后返回空数组 |

不能只传 tokenId 数组，也不能只传 abi.encode 参数而省略子函数 selector。bytes[] 是“多个字节串”，与将所有子调用拼接成一个 bytes 不同。

### 3.2 返回值

| 返回项 | 类型 | 说明 |
| --- | --- | --- |
| results | bytes[] | 与 data 等长；只有全部调用成功时才整体返回 |
| results[i] | bytes | 第 i 个子调用的原始 ABI 编码返回数据；按对应子函数输出 ABI 解码 |
| 强退子调用返回值 | 0x | unwindPositionByTsv 没有输出参数；两次成功强退的 results 为 ["0x", "0x"] |

eth_call 或 ethers staticCall 可取得返回数据，但不会持久化模拟产生的状态变化。发送交易后的标准 receipt 不包含 Solidity 返回值；实际执行结果需通过 receipt.status、日志及状态回读确认。

### 3.3 外层交易字段

| 字段 | 批量强退时的填写方式 |
| --- | --- |
| to | LP Manager 代理地址 |
| from | 拥有 Registry FORCE_EXIT_ADMIN_ROLE 的调用账户 |
| data | 对 multicall(bytes[]) 编码得到的完整外层 calldata |
| value | 0 |
| gasLimit | 对整个批次估算，留出符合业务要求的余量 |

虽然 multicall 本身 payable，但 unwindPositionByTsv 是 nonpayable，批量强退必须发送 value = 0。delegatecall 不会把 msg.value 自动分摊到各子调用；非零 value 会使该 nonpayable 子调用失败并回滚整批。

## 4. 批量强退子接口的参数与权限

```solidity
function unwindPositionByTsv(
    uint256 tokenId,
    uint128 amount0Min,
    uint128 amount1Min,
    bytes calldata hookData
) external;
```

| 参数 | 类型 | 定义与构建方式 |
| --- | --- | --- |
| tokenId | uint256 | LP NFT 编号；单次子调用处理一个 NFT；批量处理需编码多条子调用 |
| amount0Min | uint128 | currency0 最小本金输出量；按池内币种的原始整数单位填写 |
| amount1Min | uint128 | currency1 最小本金输出量；按池内币种的原始整数单位填写 |
| hookData | bytes | 当前 TSVHookV1 支持 0x；非空时需为 abi.encode(uint256 expectedMultiplier)，共 32 字节 |

amount0Min 和 amount1Min 对应 PoolKey.currency0 / currency1 的顺序，不应按业务端显示的证券/报价币顺序猜测。当前底层 burn 对“移除流动性的 delta 减去 accrued fees”做最低输出检查；它不直接表示解包后 underlying 的最终到账下限。零流动性 NFT 的 burn 不进入该段最低输出检查。金额需要先确定币种单位，避免使用浮点数。

权限和效果：

1. multicall 本身不要求业务角色，但每个子调用仍独立执行权限检查。
2. unwindPositionByTsv 要求原始调用者在 Registry 持有 FORCE_EXIT_ADMIN_ROLE，同时检查全局暂停和 PoolManager 未锁定。拥有 DEFAULT_ADMIN_ROLE 不自动等于拥有该业务角色。
3. NFT 必须存在；退出全部流动性并销毁该 NFT，将两侧资产结算给退出前的 LP owner。接口没有 recipient、deadline 或部分流动性数量参数。
4. 该路径内部建立 burn 所需授权，不要求 LP owner 事先 approve 操作员。
5. 同一批次重复传入同一个 tokenId 时，第一次销毁后，第二次会因 NFT 不存在而失败，导致整个批次回滚。
6. 若调用者通过另一个合约转发，LP Manager 看到的是该转发合约地址；应核对该地址角色，而不是只核对发起者 EOA。

版本差异：参考文档将 UNWIND_ALLOWED 标志与 unwindPositionByTsv 关联；当前源码的 TSVLPManagerLib.unwindPositionByTsv 不执行该标志检查，相关 _getLpStatus 检查位于另一个 unwindPosition 路径。本文以当前源码为准；线上接入前应对照目标代理实际部署版本。

## 5. calldata 两层构建规则

### 5.1 内层：分别编码每个强退调用

```text
call0 = selector(unwindPositionByTsv(uint256,uint128,uint128,bytes))
        + abi.encode(123, 0, 0, 0x)

call1 = selector(unwindPositionByTsv(uint256,uint128,uint128,bytes))
        + abi.encode(456, 0, 0, 0x)
```

示例中的两个最低输出量均为 0，仅用于离线编码验证；真实交易应按报价和滑点策略填写业务认可的下限。

### 5.2 外层：将多个完整子调用作为 bytes[] 编码

```text
data = [call0, call1]
transaction.data = 0xac9650d8 + abi.encode(data)
transaction.to = LP Manager 代理地址
transaction.value = 0
```

应使用 ABI 编码器处理动态偏移和补齐，不能通过 call0 + call1 的字符串拼接代替数组编码，也不能把包含 to/data/value 的交易对象直接传入 bytes[]。

### 5.3 可核验的编码结构

对于 tokenId 123、456，两个最低输出量均为 0、hookData 均为 0x 的示例：

| 编码部分 | 内容 |
| --- | --- |
| 子调用 selector | 0xa661b4c0 |
| 单个完整子调用长度 | 164 字节，十六进制长度值为 0xa4 |
| 外层 selector | 0xac9650d8 |
| 外层参数头的数组偏移 | 0x20 |
| 数组长度 | 2 |
| 两个元素偏移 | 0x40、0x120；相对于数组长度字之后的元素头部起点 |
| 每个 bytes 元素 | 32 字节长度值，加上补齐至 192 字节的子调用数据 |
| 最终外层 calldata 长度 | 580 字节，包含 4 字节 selector |

## 6. ethers.js v6 编码、模拟与返回值解码

以下代码运行于已安装 ethers v6 的 Node.js 环境。代码只构建、解码、模拟和估算，不自动广播。LP_MANAGER、OPERATOR、RPC_URL 由部署配置或环境变量提供。

```javascript
import {
  Interface,
  JsonRpcProvider,
  getAddress
} from "ethers";

const ABI = [
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function unwindPositionByTsv(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "error RegistryPaused()",
  "error AccessControlUnauthorizedAccount(address account,bytes32 neededRole)"
];
const iface = new Interface(ABI);

// 编码示例：上线时替换 tokenId 和最低输出量。
const requests = [
  { tokenId: 123n, amount0Min: 0n, amount1Min: 0n, hookData: "0x" },
  { tokenId: 456n, amount0Min: 0n, amount1Min: 0n, hookData: "0x" }
];

// 第 1 层：每一个元素都是完整的子函数 calldata。
const calls = requests.map((r) =>
  iface.encodeFunctionData("unwindPositionByTsv", [
    r.tokenId, r.amount0Min, r.amount1Min, r.hookData
  ])
);

// 第 2 层：[calls] 是 multicall 的参数列表，其中唯一参数是 bytes[]。
const calldata = iface.encodeFunctionData("multicall", [calls]);
console.log("calls:", calls);
console.log("calldata:", calldata);
console.log("calldata bytes:", (calldata.length - 2) / 2); // 580

// 反向解码：先解外层，再逐条解内层。
const [decodedCalls] = iface.decodeFunctionData("multicall", calldata);
for (const call of decodedCalls) {
  const decoded = iface.decodeFunctionData("unwindPositionByTsv", call);
  console.log({
    tokenId: decoded.tokenId.toString(),
    amount0Min: decoded.amount0Min.toString(),
    amount1Min: decoded.amount1Min.toString(),
    hookData: decoded.hookData
  });
}

// 以下开始读取目标链；from 必须与实际执行身份一致。
const provider = new JsonRpcProvider(process.env.RPC_URL);
const txRequest = {
  to: getAddress(process.env.LP_MANAGER),
  from: getAddress(process.env.OPERATOR),
  data: calldata,
  value: 0n
};
const rawReturn = await provider.call(txRequest);
const [results] = iface.decodeFunctionResult("multicall", rawReturn);
console.log("results:", Array.from(results)); // 成功时 ["0x", "0x"]

const estimatedGas = await provider.estimateGas(txRequest);
console.log("estimatedGas:", estimatedGas.toString());

// 对本例的每个无返回值子函数，解码结果均为空参数集合。
for (const result of results) {
  const decoded = iface.decodeFunctionResult("unwindPositionByTsv", result);
  console.log("output count:", decoded.length); // 0
}
```

模拟成功只说明该模拟状态下可执行。正式签名前核对 signer 地址与 OPERATOR 一致；提交时的链上状态可能已变化，需要按业务策略重估或处理 revert。

若需要非空 hookData，可在业务确定当前 expectedMultiplier 后使用：

```javascript
import { AbiCoder } from "ethers";
const hookData = AbiCoder.defaultAbiCoder().encode(
  ["uint256"],
  [expectedMultiplier] // 来自业务确认的当前倍率，使用 bigint
);
```

## 7. Foundry cast 构建与模拟示例

以下前半段完全离线，不需要私钥、RPC 或真实 NFT。

```bash
# 可选：仅屏蔽 Foundry nightly 提示。
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

CALL_123=$(cast calldata \
  "unwindPositionByTsv(uint256,uint128,uint128,bytes)" \
  123 0 0 0x)

CALL_456=$(cast calldata \
  "unwindPositionByTsv(uint256,uint128,uint128,bytes)" \
  456 0 0 0x)

CALLS="[$CALL_123,$CALL_456]"
CALLDATA=$(cast calldata "multicall(bytes[])" "$CALLS")

printf '%s\n' "$CALLDATA"

# 解码外层和每一个子调用，核对方法及参数。
cast calldata-decode "multicall(bytes[])" "$CALLDATA"
cast calldata-decode \
  "unwindPositionByTsv(uint256,uint128,uint128,bytes)" "$CALL_123"
cast calldata-decode \
  "unwindPositionByTsv(uint256,uint128,uint128,bytes)" "$CALL_456"
```

替换为真实 tokenId 和最低输出量，并通过环境设置 RPC_URL、LP_MANAGER、OPERATOR 后，模拟整个批次：

```bash
# eth_call：执行模拟并将返回值解码为 bytes[]，不会发送交易。
cast call "$LP_MANAGER" \
  "multicall(bytes[])(bytes[])" "$CALLS" \
  --from "$OPERATOR" --value 0 --rpc-url "$RPC_URL"

# 估算同一完整批次的 gas。
cast estimate "$LP_MANAGER" \
  "multicall(bytes[])" "$CALLS" \
  --from "$OPERATOR" --value 0 --rpc-url "$RPC_URL"
```

## 8. 事件监听与执行后回读

multicall 不产生专用批次事件。批量调用 unwindPositionByTsv 成功后，每个成功退出的 tokenId 分别产生 TsvPositionUnwound。事件发出地址为 LP Manager 的执行上下文地址，正常代理调用时是代理地址。

```solidity
event TsvPositionUnwound(
    uint256 indexed tokenId,
    address indexed lpOwner,
    address indexed issuer,
    address token0,
    address token1,
    uint256 lpReceivedAmount0,
    uint256 issuerReceivedAmount0,
    uint256 lpReceivedAmount1,
    uint256 issuerReceivedAmount1
);
```

| 字段 | 含义 |
| --- | --- |
| tokenId | 本次退出并销毁的 LP NFT 编号 |
| lpOwner | 退出前 NFT owner |
| issuer | 池关联 issuer |
| token0 / token1 | 池的两侧 currency 地址 |
| lpReceivedAmount0 / lpReceivedAmount1 | 按两侧 currency 对 LP 的余额增量记录 |
| issuerReceivedAmount0 / issuerReceivedAmount1 | 当前 ByTsv 路径填 0 |

若 adapter 将包装币解包后直接交付 underlying，包装币的余额增量可能为 0；不能直接将事件金额视为 underlying 实际到账额，需关联 underlying Transfer 日志或读取对应余额。

后台确认流程：

1. 校验 receipt.status = 1，并按 LP Manager 代理地址和事件 topic 解析日志；核对预期 tokenId 集合。
2. 一笔交易的多条强退事件通过 tokenId 和 logIndex 区分；不要仅使用 txHash 去重整笔交易的所有事件。
3. 使用 chainId + transactionHash + logIndex 作为日志幂等键，保存 blockHash 以支持重组撤回和重放。
4. NFT 已销毁，退出后调用 ownerOf(tokenId) 会失败；需要的 owner、PoolKey 和 poolId 关联应预先保存，或从历史记录与日志恢复。
5. 按 receipt.blockNumber 作为 blockTag 回读 Registry.getPoolTickCount(poolId) 等关联状态；这是区块末状态，包含同区块内后续交易的影响。
6. 所有子调用都处于同一笔交易中；后续子调用失败会撤销此前子调用的状态及日志。模拟返回结果不应触发业务落库确认。

如需解析 tokenId 与每条操作的入参，可对链上交易 input 先解 multicall，再解 data[i]；不应假定该入口里的每个子调用都一定是强退函数。

## 9. 常见失败、批次大小与验证范围

| 场景 | 结果与处理 |
| --- | --- |
| Registry 全局暂停 | RegistryPaused()；外层即停止 |
| 调用账户未持有业务角色 | 子调用抛出 AccessControlUnauthorizedAccount；整批回滚 |
| tokenId 不存在或批内重复 | 子调用在 NFT 查询或后续操作失败；整批回滚 |
| 最低输出不足、倍率变化或资产交付失败 | 相应业务路径 revert；整批回滚 |
| 批量强退携带非零 value | nonpayable 子调用失败；使用 value = 0 |
| data[i] 不是合法子调用 calldata | ABI 解码或函数分派失败；整批回滚 |
| gas 或 calldata 超过网络/RPC 限制 | 交易可能被拒绝，或执行时耗尽 gas；按完整批次估算并拆分 |
| 期望跳过失败条目继续执行 | 本接口不支持 allowFailure，需在业务层拆批 |
| 只得到 revert data，没有失败下标 | 当前实现不额外封装下标；通过完整批次模拟、trace 或有状态 fork 定位 |

合约没有“最多 10 个”或“最多 100 个”的固定数量限制。应对候选批次逐步估算 gas，以目标链当前限制为准；单个强退成本会受仓位、费用、Hook、订阅及交付路径影响，不能用一个固定数量保证成功。分成多笔交易后，只能保证每笔批次内部原子性。

本次已完成的验证：对照本地源码与 ABI，使用本机 cast 生成两条强退调用及完整 multicall calldata，并反向解码核对 tokenId 和参数。单条子调用 164 字节、外层 580 字节，两个 selector 均已通过 cast 核验。ethers v6 示例未在本次环境执行；未进行目标链模拟或广播，不代表示例 NFT 在链上存在或当前账户已获授权。

核对来源：

- src/v1/periphery/TSVLPManagerV1.sol：multicall、unwindPositionByTsv 入口及修饰器。
- src/v1/vendor/permissionedPools/base/Multicall_v4.sol：delegatecall 循环、结果数组及回滚传播。
- src/v1/libraries/TSVLPManagerLib.sol：强退实现、事件和与 unwindPosition 的路径差异。
- src/v1/vendor/permissionedPools/PositionManager.sol：burn、手续费和最低输出检查。
- src/v1/core/TSVHookV1.sol：hookData 的倍率校验格式。
- out/TSVLPManagerV1.sol/TSVLPManagerV1.json：multicall 和 unwindPositionByTsv 的 ABI。

