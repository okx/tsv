# MSTR、BTGO、SECZ Security Token 及关联服务地址

链：X Layer  
RPC：`https://rpc.xlayer.tech`  
读取区块：`74835869`  
读取时间：2026-11-02（Asia/Shanghai）

## Token 与服务地址

代币服务地址通过各 Token 的 `getDSService(uint256)` 读取。ID 4 为 Registry，ID 8 为 Compliance Service，ID 8197 为 BlackListManager，ID 64 为 InvestorLockManager。代理实现地址通过 EIP-1967 implementation slot 读取。

| Token | Issuer | Token 代理 | Token 实现 | Registry / GlobalRegistryService 代理 | Registry 实现 | Compliance Service 代理 | Compliance 实现 | BlackListManager 代理 | BlackListManager 实现 | InvestorLockManager 代理 | InvestorLockManager 实现 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| MSTR | Securitize | `0xf83D29cA0F926CEf42597ac57e807ad452Ce5B43` | `0x731cc731d35b174805608a17c496c302656fd82b` | `0x017D40856467f36B0B86775314f04BA8ED0D65b3` | `0xdd341bf2de8e899c2465afe3a7dffea721fd9580` | `0x2fc11aD109c41aB1d347D45D32A31Eb3d09e66F6` | `0xa1ce2629dc41ed665a8bf08025993885902ece5d` | `0x5aB344e3e14A5dd7313b864D9e7b079415560D70` | `0x2f4d7517cb3770db213ad0072f6bc3ed62f7ade9` | `0x4f16B5EeD5c6b8bCc309DaA52eef1b19023bf04D` | `0x2c7b94f5e83fcf5b3d575e1e430a7b26cacf3ccc` |
| BTGO | Securitize | `0xA57157574E6Efd4E26F08B97cAa0BEE6c8A80E4F` | `0x731cc731d35b174805608a17c496c302656fd82b` | `0x017D40856467f36B0B86775314f04BA8ED0D65b3` | `0xdd341bf2de8e899c2465afe3a7dffea721fd9580` | `0x10eC8b3504d3e376465EBd4d7D576D5b5775A1E0` | `0xa1ce2629dc41ed665a8bf08025993885902ece5d` | `0x5aB344e3e14A5dd7313b864D9e7b079415560D70` | `0x2f4d7517cb3770db213ad0072f6bc3ed62f7ade9` | `0xFfbA4ebc0c0cde436D5aaafc48aB9Fa098A6629C` | `0x2c7b94f5e83fcf5b3d575e1e430a7b26cacf3ccc` |
| SECZ | Securitize | `0x811EEf1eF8033743109D45af69dC9E59F79f4b5c` | `0x731cc731d35b174805608a17c496c302656fd82b` | `0x017D40856467f36B0B86775314f04BA8ED0D65b3` | `0xdd341bf2de8e899c2465afe3a7dffea721fd9580` | `0xdC558A87642119468d2cf14Beaa4F47F77381743` | `0xa1ce2629dc41ed665a8bf08025993885902ece5d` | `0x5aB344e3e14A5dd7313b864D9e7b079415560D70` | `0x2f4d7517cb3770db213ad0072f6bc3ed62f7ade9` | `0xA2202C98b2593ade7190A59aC893E19121cdEB61` | `0x2c7b94f5e83fcf5b3d575e1e430a7b26cacf3ccc` |

## SecuritizeTSVChecker

这是外部发行方 checker 的地址记录，不表示 main 提供其可独立部署的实现。本仓库核心合约通过公开 checker 接口集成，TSV 默认构建不依赖发行方实现源码。

以下地址由请求方提供；它不是上述 4 个 Token service ID 的读取结果。对其 EIP-1967 implementation slot 做了只读核对：

| 组件 | 代理 | 实现 |
|---|---|---|
| SecuritizeTSVChecker | `0xbB1716d2a3fc6215C306a8942A2842F486e1C4B1` | `0x1e79dc934f528c1b1d405cb38a322235c2cf9b62` |

## 与已知 VOLOROST2 地址交叉核对

对已知 VOLOROST2 Token `0xC03484ab791B5BD2C3DA860BEa2Ba96C76248BFD` 读取 service ID 4、8、8197、64，分别得到 `0xCf931e565efD7b9A980370f66ba62D62a606b494`、`0xD205cF5f1317015a19a5dF03b7D40578104D1615`、`0xa8dfFa95D60a75962266Ea7f63DB4CA067a93937`、`0xff8145c1Ae0b47D1b69f726Aa725aA5593cdce71`，与请求方提供的 VOLOROST2 地址一致。MSTR、BTGO、SECZ 的 service 地址按各 Token 自身读取，不能直接把 VOLOROST2 的代理地址套用到它们。

## 查询边界

- Token 的 service 映射来自当前 X Layer RPC 上的只读 `eth_call`。
- 所列实现地址来自代理 implementation slot 读取；这确认当前 slot 值，不证明实现源码已验证或审计。
- “Issuer: Securitize”按请求方提供的信息记录；本次 RPC 查询不验证发行方身份。
- SecuritizeTSVChecker 地址按请求方提供；本次只读取其代理实现槽，没有证明它是每个 Token/W 当前配置的 checker。具体 W 的 checker 需从对应 Permissions Adapter 的 `allowListChecker()` 另行读取。
