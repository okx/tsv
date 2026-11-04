# X Layer 角色授权记录（2026-10-29）

Registry：`0x2233ea2044ffa04ccceeef0b9adfe0799505a908`
操作账户：`0x224467f6640AbE0A62D1be98187912627b59722A`

各写操作先模拟后广播；交易参数由链上 calldata 解码，已验证成功回执、RoleGranted 事件及 hasRole。

| 角色 | 地址 | 交易 | 区块 | 结果 |
| --- | --- | --- | --- | --- |
| HALT_REPORTER_ROLE | `0x3936b9299821a108bDa6dc31Caf3Ebd2FF7ADd3C` | [0x6ddb833a719639553acd7c1987104709e93a5f25bd304b4cc159f26fe5745917](https://www.oklink.com/xlayer/tx/0x6ddb833a719639553acd7c1987104709e93a5f25bd304b4cc159f26fe5745917) | 74489832 | hasRole=true |
| HALT_REPORTER_ROLE | `0x94b9097cCA1A368F7bD6aBa0e38a6333bFD42936` | [0xd01c44c1b31fdb4842ef3493676a1b8965054c6a0470519a61a65ae79abe06ce](https://www.oklink.com/xlayer/tx/0xd01c44c1b31fdb4842ef3493676a1b8965054c6a0470519a61a65ae79abe06ce) | 74489832 | hasRole=true |
| FORCE_EXIT_ADMIN_ROLE | `0x466Ef4a1008772Af2D0FA52cD2Fc8b5391863a76` | [0x5b7fe6ae37678b5832be32dc54bb2abe4a480664b88fc4c971430b6ffee64ab5](https://www.oklink.com/xlayer/tx/0x5b7fe6ae37678b5832be32dc54bb2abe4a480664b88fc4c971430b6ffee64ab5) | 74489833 | hasRole=true |
| FORCE_EXIT_ADMIN_ROLE | `0x323ef02B3CE1a90D631f461A1EEec23cd639651f` | [0xa2c3a66abce67ccdd8a0f88482e1cafc538ef19e67fd975b3e5106f45d469ed3](https://www.oklink.com/xlayer/tx/0xa2c3a66abce67ccdd8a0f88482e1cafc538ef19e67fd975b3e5106f45d469ed3) | 74489834 | hasRole=true |

最终核验区块：74489840。四组角色/地址均为 true。

Lark 日志此前返回 forBidden，本次不自动重试；交易证据保留于本目录。
