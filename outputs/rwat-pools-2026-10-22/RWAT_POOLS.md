# RWAT / USD₮0 新建池清单

已完成最终链上核验：22/22 个池。网络：X Layer Mainnet（chainId 196）。

## 参数与范围

- 操作钱包 / Adapter owner：`0x224467f6640AbE0A62D1be98187912627b59722A`。
- Factory：`0x92cdb229613da8ca45e375cf69df4b3b645ff48d`。
- Registry：`0x2233ea2044ffa04ccceeef0b9adfe0799505a908`。
- PoolManager：`0x360e68faccca8ca495c1b759fd9eee466db9fb32`。
- LP Manager：`0xf73d8683b948564d2795c62a2a909012ea168d29`。
- Hook：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 所有 Adapter 使用同一 allowListChecker：`0xb4110157542283aecacb7483b7029d2216507525`。
- QuoteToken：USD₮0，`0x779ded0c9e1022225f8e0630b35a9b54be713736`，精度 6。
- fee = 2000（0.2%）；tickSpacing = 60；初始价格：1 枚 RWAT = 1 枚 USD₮0。
- 每个 Token 分配独立 securityId，每个 Token 使用独立 ERC8056DirectLegalShareAdapter。
- 每种 Token 只补 mint 至操作钱包足够转入 0.1 枚；每个 Adapter 转入 100000000000000000 raw units（0.1 枚），转入与 Factory 验证为独立交易。
- tier 3 容量 40；本次登记 22 个独立证券。
- 本次不部署、不修改 Token 的 Trust、Compliance、Rebasing 等底层服务；这些服务由其他流程完成。
- 本次没有执行 LP 添加或 swap，也没有配置 Adapter 的 TSV wrapper / hook / swapping 权限。
- Pool 是 PoolManager 中由 Pool ID 标识的状态，不是独立部署的池合约地址。

## 全部池子

| 序号 | Symbol | Underlying Proxy | PermissionsAdapter（W） | Pool ID | 状态 |
| --- | --- | --- | --- | --- | --- |
| 1 | RWAT | `0x6C9E1F1E6A084e88C1f67f45Ccd473CA90c2fd13` | `0xae70703be08420fa38c5125d7e6d9143375975a8` | `0x87a89c9da7d95df8c6e4f3f443d37ae53cbcf94d88dc6594d44306c2d6869eea` | 已初始化且零流动性 |
| 2 | RWAT1 | `0x4dEEe58e069fd52Ce1db945699f15f03E049b920` | `0x9435381c64bb197b8d971f4d9a1cabffbbd7d733` | `0x7bbfd3997e8e0fc1c4b0e77c92d8d0ba553b9ede2078f64f7027fbceb7e4ed24` | 已初始化且零流动性 |
| 3 | RWAT2 | `0x7AD9D70f30f31E39EA0046C35D196b8a9F3E81E9` | `0x029f2be299620af8e706be5dcc3186fe4f0446ca` | `0x4ae54606e22c06f56deb415ebc4e75e5dc32d83a7156a5e45abbbf3c587ea1b2` | 已初始化且零流动性 |
| 4 | RWAT3 | `0xa9DBCf8904721810513B73cA6f4942dE8f8f99e7` | `0x8fc8579ca22303a8ae7524ad4f66d31643e875d9` | `0x4d77e1f42965fb2582f61bb26447b9fa3d3337e8af5882d1a84a8c046437fe87` | 已初始化且零流动性 |
| 5 | RWAT4 | `0xc2a611aBd4f3De5dc3BB22Af4063f9aee269255d` | `0xb9e7a695504d552af393060f10b6692ecccab6d5` | `0xb37c498fb62bb9c601b0503c5eea7a311c847982ac2ce7ec84811d1c7a70bd18` | 已初始化且零流动性 |
| 6 | RWAT5 | `0xb14034A0b533a88fc62AC2F577ed59FB0375b130` | `0x700fc130cf7a649a5bda021951da6d36c9b855ab` | `0xcf05955111b2ffd34aa9a023731f79709f9e7416eae8af2e91a8076d4cda3aff` | 已初始化且零流动性 |
| 7 | RWAT6 | `0x947382f119Fe6f0344123A41B8833B969c9539b3` | `0xc285e84d4675fef05da1ebc2d90a1378ce0e4037` | `0x69cd3904a8527658b249e2ab83049befaffe3a3adbb543800fe6aed07d0a301c` | 已初始化且零流动性 |
| 8 | RWAT7 | `0xbF6343896f1AdcACE43e810C1758b53A40DCEe95` | `0xb366b707fe7ba69d7269bede781adb8ad88d6b89` | `0xcf39995248aa9dbbf9c861b167804db1266df7d9f925fd36bdd9083f710c464b` | 已初始化且零流动性 |
| 9 | RWAT8 | `0x13160af212E62F12Eca804B91fEfe302a4EF4387` | `0xe4c6ed06fa534af10d485e6ba7dcbab0ee26d08e` | `0x479bf6ea441eb01b3ab1671334da45fb4798939ef815bbb5c94d288d9cdc18d0` | 已初始化且零流动性 |
| 10 | RWAT9 | `0x8A2689465034031bf0F55E65f600CEE17bB0F6D3` | `0x5e1e82e224a9b94e44e18387bb3215ccf983541d` | `0x0739e42171ec8b67a8da444a8402c4bccd162bb0d3bafb90fde1a34acda4f00a` | 已初始化且零流动性 |
| 11 | RWAT | `0x9a0E6B7C37873aF042A8959f4D5188B657204Aa6` | `0x21927b0605a709982ea406fde14011394b98aa0b` | `0x0b6f66c839bcb500f2dad4b3ecfda479dcf0ce626586791da945422b7131d638` | 已初始化且零流动性 |
| 12 | RWAT | `0xCCF3e98eb18f35A38fdd162ec5FFf5788FF01801` | `0xb09860def268f7949b0ced031cf756824218ac5c` | `0x39c2ccbf621dcb4a8966251de57c79a8e5e0ad26dfb6891e98a4e9b448b9ca68` | 已初始化且零流动性 |
| 13 | RWAT | `0x5aA6dBc1C202cEA406910fe50e5e1d28FAbb5BDa` | `0xbc37c72e62fed3c29e3c6baa0e7677fedca64f78` | `0xc7aad6239e71df094177e4fceb3e33a9131a8f29b6a453be44984050aa1a4418` | 已初始化且零流动性 |
| 14 | RWAT | `0x4bEE53f182F871d1204D256Fe8e4265b23b7A261` | `0x6d0158fe5e1fc6e3756c7b66527b2ea86b8adb9d` | `0xa1595d030614370c0129d23379a19e120d1bc1fb0448907d17752b4675ad23b9` | 已初始化且零流动性 |
| 15 | RWAT | `0x7283faBD88b147CD7e49F505AA1F848D6B14a95d` | `0x24b89fdbd2aea020fe0b0d2a6973620201d42dfc` | `0x87dcbc0b521ffef9bff90f53d1f26af14802c1d0c59678aa1ffa89b766b92c09` | 已初始化且零流动性 |
| 16 | RWAT | `0x531922E67811467D5dd5137755a38AeD15e5df35` | `0x74a3537c526e05e413184b82d57b62c40b4abb61` | `0x7b95c0fb6fc6cb090e14fb103f8a6afa9d082b27b8565e47dc13427a6749427a` | 已初始化且零流动性 |
| 17 | RWAT | `0xc9B54c9cC12983099fcD49F0357B08A2596f9C54` | `0xb5c940504e04e3642f98973bd1b04aa103cb1382` | `0xbadc45b04cc2d2d7d36f958a2626c15224438cfe3ed4d878e70b56b99f9d2b96` | 已初始化且零流动性 |
| 18 | RWAT | `0x78FA06BD9e8a7Af4aEe36F9Fa348080D2f27Bf46` | `0xfb2b022ae90e5a54f74d0805fd64f7843a73be7e` | `0x19bbe53c3d4484c5cd23ac94ff8bbea842f0e68bf69150ef5f8d4c4f85015f40` | 已初始化且零流动性 |
| 19 | RWAT | `0xb879670887B5328e805309FD37f76A2F598e129D` | `0xafc4dc44d30e266c59d11ac05f14a60a802a2682` | `0x200cedf5334b104e0e3b584d1da24610a480412dea804282fb2798ab25133978` | 已初始化且零流动性 |
| 20 | RWAT | `0x9eBc3dc2807F7323aCfe4B5f345291A4AD6b3F1B` | `0x22af80b3e786d0e4557bde7cde3810411d2768a7` | `0xff00ddfc76c89cdf639fc293b39535133d663b0b739c327db62656171f08c18b` | 已初始化且零流动性 |
| 21 | RWAT | `0xbaDeDb3F01632Bc1508F2A952472edF1fa3b808C` | `0x3647e495a1c79ab9e5506715c5112ef1ad77082a` | `0x463b34d1387559a8c4f561b01c299e36dd9959987177fc79dd510514acd5c5f8` | 已初始化且零流动性 |
| 22 | RWAT | `0x45e33E9B75A3bd3BcC6aa3FDCa680248904A4cD1` | `0x1a352ed00823a605924136d852723a3386348930` | `0x63c674a75f3c967f98c0cb8b61701f0bac87071c41fde6dcd6624a752f42749e` | 已初始化且零流动性 |

## PoolKey、证券与交易明细

### 1. RWAT — 0x6C9E1F1E6A084e88C1f67f45Ccd473CA90c2fd13

- securityId：`0x3649324d08e698f327a2965df41a0f6ec8d5847c5484a7dd975cf4e09d571283`。
- LegalShareAdapter：`0x0b5d53f6ff36e99f984cc9252dfe926fff7ddd6d`。
- Pool ID：`0x87a89c9da7d95df8c6e4f3f443d37ae53cbcf94d88dc6594d44306c2d6869eea`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xae70703be08420fa38c5125d7e6d9143375975a8`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xb484d4c18d882d66099c9cd9bb01816af6673c9949086c80a968195b1f8be82f` | 73886050 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xe78b557dd4692705d8b7b78ed10516026f88d21abd62091528eeb0bdcc895356` | 73886521 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xe33c27a89df5a797a931dd165e5ac374d2a3512e3bcfa948c8fd5642609ed513` | 73886522 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x4cac28e7bb5c8c450347dd012f4402c061e7eb4b0d158086eb396b4d9acd6783` | 73886890 | 成功（status=1） |
| Factory 验证 Adapter | `0xcfc0f48a325b3c4846fb0bab35c7655557908dbda6682a85fab4acb650a4bbee` | 73886891 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x707151b33dd8e260766be013251f339ffc9ba03dd39abb89f5ac0e4706a67bab` | 73887643 | 成功（status=1） |
| 创建并初始化 Pool | `0xe332dd6a92a6af1e206baac65bdfa14f37b6794ad000a4745685d47765c7ae5c` | 73887973 | 成功（status=1） |

### 2. RWAT1 — 0x4dEEe58e069fd52Ce1db945699f15f03E049b920

- securityId：`0x46225a5a5ea978b6bf1de54e3595786df33478289b8a02784f7e2ef4ef1a5485`。
- LegalShareAdapter：`0xdb4c6c56fa3bc1b3de6054cb3a7b34c517411369`。
- Pool ID：`0x7bbfd3997e8e0fc1c4b0e77c92d8d0ba553b9ede2078f64f7027fbceb7e4ed24`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0x9435381c64bb197b8d971f4d9a1cabffbbd7d733`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xc463f3db17acef4b68f67df39a461fbd8e0fecddc70305287b855c5c60582eb9` | 73886051 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x83bf2422e7350c79bea103749f1e3e77bab679a78592728710a141382e6f4ed4` | 73886523 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xb69a8b1d4837d5efb6f71814a4961f7e4d647120017e957b35351055864894d7` | 73886524 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x8bf79b24c77f5c1c01b5d86595c5d030678b156767d4a4f9aafd8467f8f311a4` | 73886891 | 成功（status=1） |
| Factory 验证 Adapter | `0x616fa2d44d9b47ca2ac327f000d2c39dfbf6b4f197bb7170ade02a615df3cace` | 73886891 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x3114e78d950778b60ca4ad9643e13f0a0b6f8d57abe649b87685a90a7b056799` | 73887643 | 成功（status=1） |
| 创建并初始化 Pool | `0x28c7967fd363d22ba13d02c35248c7f31aa0cf63f224f45c78c768050c7c42da` | 73887974 | 成功（status=1） |

### 3. RWAT2 — 0x7AD9D70f30f31E39EA0046C35D196b8a9F3E81E9

- securityId：`0x6e5b9afba3b7659e8951c969c1b4a7d36aa468fd4b6013c4990f34eac4bccf85`。
- LegalShareAdapter：`0x74d59db9e084570a607b0528dca77f1c87a29e96`。
- Pool ID：`0x4ae54606e22c06f56deb415ebc4e75e5dc32d83a7156a5e45abbbf3c587ea1b2`。
- currency0：`0x029f2be299620af8e706be5dcc3186fe4f0446ca`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xfa6e56e7fb0b69b5c37b29f80686f52f8463b642d740d5c46a1ae204ed3dcc8b` | 73886052 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x5781375840e90951afb07925849283957d20806533f4d658eb2df196409d45fb` | 73886525 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x542b82eda44b6aa4a096d6ea27fe82724adec4e4f9ecb6cdf8f2304bd931d45d` | 73886526 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x41a928d6fb4cea715abd2e503e3bd100fac81cb171449b6ae34f6f9189494bf0` | 73886891 | 成功（status=1） |
| Factory 验证 Adapter | `0xdc7174f9d23e94423eed0947bfeac2014bdde17763268a2e449953c8986c2ece` | 73886892 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x8b685f3eda30a127f0f6df994c8f300efd377aa035f9a022d2c6907bb0424395` | 73887644 | 成功（status=1） |
| 创建并初始化 Pool | `0x9467c101caf87e2e50ab3366c058d4beffaa9ab1a02679d187571509cadf187b` | 73887974 | 成功（status=1） |

### 4. RWAT3 — 0xa9DBCf8904721810513B73cA6f4942dE8f8f99e7

- securityId：`0x0c88e9bb379383c19efc287a083a33129aecf9d39c97fd564bb800fd114bdc67`。
- LegalShareAdapter：`0x03213db496edd19d39138ceb47f6ebd91d2d58f5`。
- Pool ID：`0x4d77e1f42965fb2582f61bb26447b9fa3d3337e8af5882d1a84a8c046437fe87`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0x8fc8579ca22303a8ae7524ad4f66d31643e875d9`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x0754757271d7aad64868e4fdadaf59c9195af85e5409b7d1bba8f1d3fa9d5bac` | 73886052 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xc380c79fdbc19153cd7db4bf7d0fe76aa38a16b37eb28a34bf20b39100665521` | 73886526 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x899d4f50714847035982bf104dd7bd1bb7c1eccb7e9443effa0baa029124aa70` | 73886527 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x9a8b45daa509b60b0e6da92e01cd381d122f0db79e34816f21da27a669b368b9` | 73886893 | 成功（status=1） |
| Factory 验证 Adapter | `0x5f58cc588c24dffd00fd821bc8af5720364a2ee52ef772cc08c7d0363c7893b3` | 73886893 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x4639107f5ab99d69b70d0da5ccec039112386d3fd8dfb9821bfb3fe8385dd742` | 73887645 | 成功（status=1） |
| 创建并初始化 Pool | `0xd9fb0b9ac933da37f91ba84dcd9a9b26cdb05e20c4153d5db9385718a8527e5f` | 73887974 | 成功（status=1） |

### 5. RWAT4 — 0xc2a611aBd4f3De5dc3BB22Af4063f9aee269255d

- securityId：`0x0d12051a48a804abdd431301cba0a450428942c9a631c059af71fdec446b896f`。
- LegalShareAdapter：`0x4aedecf4c909b1a0950895611acb9cdd7042e4c6`。
- Pool ID：`0xb37c498fb62bb9c601b0503c5eea7a311c847982ac2ce7ec84811d1c7a70bd18`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xb9e7a695504d552af393060f10b6692ecccab6d5`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x8b8a35c7ad8d21c3b1360d1b942b819ba520ef4a74f3c3041341ec22a69132fe` | 73886053 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xe88cb7b41d1a8a368710d5ec0358c2f753446e3b8d112621a0357b7aa5a443b9` | 73886527 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x9e9e3febf87673578704c6e2820c0c65ca5f6b3cb9173ef81a95ae577ee87c3f` | 73886528 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xebbcf963e3b9da00352cf3174da1430222f2d90d60a0301541934db489d1e55e` | 73886894 | 成功（status=1） |
| Factory 验证 Adapter | `0x379aca6316b52deb2738048198e5e64148e3821ec619fd9c4134971fc8f0faff` | 73886895 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x18d91aba3cf4401684375b33fd689ccae2204d2b5f8b891992fa9b4182fd7207` | 73887646 | 成功（status=1） |
| 创建并初始化 Pool | `0x69cba30d823c09efbbce6bcd00ffcf7b43a5af023446240748395a1426e7dfe5` | 73887975 | 成功（status=1） |

### 6. RWAT5 — 0xb14034A0b533a88fc62AC2F577ed59FB0375b130

- securityId：`0xb3cba3e03201470914176de877d97445a413a8b9792271518cabead3b5e2f255`。
- LegalShareAdapter：`0xb666b952513af8acc2303929306f2cd2e1815c63`。
- Pool ID：`0xcf05955111b2ffd34aa9a023731f79709f9e7416eae8af2e91a8076d4cda3aff`。
- currency0：`0x700fc130cf7a649a5bda021951da6d36c9b855ab`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x9e47eae6e1461628c6e7e73372e68f89880d6fb3f35ddba8a7ef45b747f48fa4` | 73886054 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xad673a4647362197bda2c2403f4c09d5eb52f81ff07f649688fa54fd7057fc5b` | 73886528 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x0e85f1ab650e40db99ee98d45c088dbcb08008c681410e5ab0d728e919146765` | 73886529 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x2a9dd13c8bd0b1806acada045e9ccd4ce6079466d296e1b08147075b58289da0` | 73886895 | 成功（status=1） |
| Factory 验证 Adapter | `0x59afecfe34f8736c591a3f6fe37cb57bccb4037bac099ff8b5da906177b32ec8` | 73886895 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xd5b398b2e033adb360838c4bd1b5087c9c7da4edb5ad17b2935edd2b1a3790a2` | 73887647 | 成功（status=1） |
| 创建并初始化 Pool | `0x62b8fb2a2cc6f00ceff1355f95aeecd8e70e143eaaf6969f67350b56503dd5e4` | 73887975 | 成功（status=1） |

### 7. RWAT6 — 0x947382f119Fe6f0344123A41B8833B969c9539b3

- securityId：`0x0cc77bd30bdad30c15938ffdeb503c0dca70523070b5ad58e694a3f2c57a00b9`。
- LegalShareAdapter：`0x996f92847816a9e5c66b2e7336ca270357105d7e`。
- Pool ID：`0x69cd3904a8527658b249e2ab83049befaffe3a3adbb543800fe6aed07d0a301c`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xc285e84d4675fef05da1ebc2d90a1378ce0e4037`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xf9a71143352808b07bea490e89c6d44cef36ba99a75c51eae17dbf05311421e6` | 73886054 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x946d916225e09ad414197f11d9a96202fd686e157ad5dcd5b6c847486e3a2a52` | 73886529 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x6f8d45e8e5e0ae727f74349482a8a4337bd4ee35e1fdf87207a61d243b9c55d9` | 73886530 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x032424e26419dad3d98ecab570696aa629397fcb001a0644dcb026f494d64042` | 73886895 | 成功（status=1） |
| Factory 验证 Adapter | `0x3c7997093fc0116bf12df36fdecb845c38955f283457af213a9b91d7a8b7c368` | 73886896 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x9d1c2ee73dd89da526bc496a66f39537d467ca87a4dca45eecc107f18a217332` | 73887648 | 成功（status=1） |
| 创建并初始化 Pool | `0x7678ac4443115588a0e9a473eb4fd47dde4822940c13a3b55ab6e2c38efc8d36` | 73887976 | 成功（status=1） |

### 8. RWAT7 — 0xbF6343896f1AdcACE43e810C1758b53A40DCEe95

- securityId：`0x430deabda3d51007b9865149f985e940c2f1f56405e6c6f8433ef34252efe8ba`。
- LegalShareAdapter：`0x8a41b5c979febf6865affbe28a1aa21b323ab38f`。
- Pool ID：`0xcf39995248aa9dbbf9c861b167804db1266df7d9f925fd36bdd9083f710c464b`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xb366b707fe7ba69d7269bede781adb8ad88d6b89`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x0cfc2d19c767ddf48bad508cf825c118a2595f8f28799fccc64c99f5a454b303` | 73886054 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x71d3b740996c4ba78c4e336aa9765f5544f431080891ff4084df73b7bb48f327` | 73886531 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xf54ced5c12c2c561c23db8add6d6e9d899971b48c4c24279863e4da3af74d90b` | 73886531 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xdae0afd3b91f2e23ac7debe2efeb349abf9994836cbc4d86930bde6fd0e3b452` | 73886897 | 成功（status=1） |
| Factory 验证 Adapter | `0x20096dcb7f0a6406a3beaf8893063762f528a6e4759c6c993b84992b7ff374f0` | 73886897 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xc6079869b5f6d071279cd06efd8a2975237d8c80bd4a747ba5a9db7f1fe1e576` | 73887649 | 成功（status=1） |
| 创建并初始化 Pool | `0x15a3f428194badc1cc6213db251f823523c468b4c79de839cc33a9dd7088b23f` | 73887977 | 成功（status=1） |

### 9. RWAT8 — 0x13160af212E62F12Eca804B91fEfe302a4EF4387

- securityId：`0x4c9858867b488d2d4fe8a41804798793b5da76942815206d4fc36445c9684c2b`。
- LegalShareAdapter：`0xc2297f1001323fef4a1376cf5b57a711428ade65`。
- Pool ID：`0x479bf6ea441eb01b3ab1671334da45fb4798939ef815bbb5c94d288d9cdc18d0`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xe4c6ed06fa534af10d485e6ba7dcbab0ee26d08e`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x0fe87506c2a5b6da3186d2ad340344c3c1cc2dfc1e151f21b6824d65b1d56a1b` | 73886055 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xb5c83f06119361c670d1559d49c696a28bc8e5dc40065782b60976fc057b125f` | 73886532 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xe6144b4ae9cbe8ef21b5df018e6b374199099b06d3d7ebf97b414b096e914b31` | 73886533 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x50f6291ef94b7562ac9b0aaf022bf4dbc744873d942b55bc1daa2fa4a8053131` | 73886897 | 成功（status=1） |
| Factory 验证 Adapter | `0x93d8b62b2618cb5c44601aa647101cca2536806096c6253530cc3dae07e0d1f9` | 73886897 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x40b4d5d246183d7bd8ee46d805d89c8c546226e21fc153de7e8b75ea2511bed5` | 73887650 | 成功（status=1） |
| 创建并初始化 Pool | `0x890726361d5a35f64d3e2c12705e7dacf52074232e9a20786c0a950362fb635e` | 73887977 | 成功（status=1） |

### 10. RWAT9 — 0x8A2689465034031bf0F55E65f600CEE17bB0F6D3

- securityId：`0xf0c02e3510331a43a58c1502d6285d2d6e34b3c622f9ac638f00c6e1beca1c4d`。
- LegalShareAdapter：`0xae02b3aca3fedb66db5b2b2df3f5241c5921950e`。
- Pool ID：`0x0739e42171ec8b67a8da444a8402c4bccd162bb0d3bafb90fde1a34acda4f00a`。
- currency0：`0x5e1e82e224a9b94e44e18387bb3215ccf983541d`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xfe804084b1d9d0c4b08fa933ec49006ef26ec1310fd8ac443d3417e852ed8732` | 73886056 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xb7f1c7a981a8463bf291e051da12691e63acd4df8b77df95f64b2c30f22ee07b` | 73886533 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xe5f864d9ff0bf9e59ff862614cbbaff0a958e636c4ca220d37e209e340a91699` | 73886534 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x5e792c643c451b7ee40ef726357ceff3c97564c1484ee142fb70c134f10caa75` | 73886897 | 成功（status=1） |
| Factory 验证 Adapter | `0x48aec559f88dd6956db0a8934afd25977e84aac553ad8094745bece4d17cfec0` | 73886897 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xc5c818ebcd5c6d7594917f8fd4fad3487a59517a0a77488bb2c7487fdb31e20e` | 73887651 | 成功（status=1） |
| 创建并初始化 Pool | `0x565144aa638b75035e8ce0c3f92cf0792b80ac0708a89ae94c2f1a2da58fb18d` | 73887977 | 成功（status=1） |

### 11. RWAT — 0x9a0E6B7C37873aF042A8959f4D5188B657204Aa6

- securityId：`0x317cef0c8441d6485feee95e29ac74880a27eb5df69b537f4071f2be96e999d2`。
- LegalShareAdapter：`0x135ae585eb92cfcddbf532aab0af70db89b69966`。
- Pool ID：`0x0b6f66c839bcb500f2dad4b3ecfda479dcf0ce626586791da945422b7131d638`。
- currency0：`0x21927b0605a709982ea406fde14011394b98aa0b`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xeef8dcc53485180ef4e804b0b5d0eeba55b36ea24f8893c94ea2a002adc485a3` | 73886056 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xf54bdb69c19780c0369dacdcdaf196fef6d058980edacdd7793df899898ac624` | 73886535 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xb3966257ab67f039fb59f92aa141c0e78e93219ece8f53aa26fa9ba2f1b8a660` | 73886536 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x71ed12049d3f9f9d0bbc94bc15b103fab2f8848dc90fccece044fd9dbead0f22` | 73886897 | 成功（status=1） |
| Factory 验证 Adapter | `0x014e8dfe8a7bc38f186596374b3251f4519fd415b264fb8f6043602ecb98b94b` | 73886897 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xf51a726c32627ada812eee6a0ee6650836d7dd8914186fdca5d0e6b91b0646e1` | 73887652 | 成功（status=1） |
| 创建并初始化 Pool | `0x174e3bb9f69a50e415c41b8fee8f764480ca280b6ef19d373b245833f1ee9e8c` | 73887977 | 成功（status=1） |

### 12. RWAT — 0xCCF3e98eb18f35A38fdd162ec5FFf5788FF01801

- securityId：`0x1063b79d080cd08337e4b7beef747c27ec4aac0f99914acd310f34aa458ab7a9`。
- LegalShareAdapter：`0x3672d3b4206180824a4198420c33b3b82492b082`。
- Pool ID：`0x39c2ccbf621dcb4a8966251de57c79a8e5e0ad26dfb6891e98a4e9b448b9ca68`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xb09860def268f7949b0ced031cf756824218ac5c`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x62534cfbeaecd1799f16b64b8904a42c94ba66f12df56b33c3c13a92bc2357e5` | 73886057 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x17f9201130fcf061c58b6261381be20bbb69e9c37a9bf484dc1aedfd6109f6aa` | 73886537 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xf35b7a6aca605364cbd11d794f35f097641c982ae389531d40804d27601c3f8f` | 73886537 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xe69fa0b0827832e8959a9e3d5a42657a31b3f67784eee04473648b7e51435efb` | 73886898 | 成功（status=1） |
| Factory 验证 Adapter | `0x8411b3bb682a3edc60787627109e5b5e2eb2538baf1d81a7b56b7969740690f8` | 73886899 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xb21c90aaed030c8d79b39f19d9d60edda7b0a3c5efb5bdf80659701a4f621442` | 73887652 | 成功（status=1） |
| 创建并初始化 Pool | `0xc46e595e1988c3e9f349499171f3f63c3dbe6c3cd099773d32d2df67e48fd2e2` | 73887978 | 成功（status=1） |

### 13. RWAT — 0x5aA6dBc1C202cEA406910fe50e5e1d28FAbb5BDa

- securityId：`0x34240984ad4070f0eda44c35d776a2f39936938777952bd2039a279874840c23`。
- LegalShareAdapter：`0xfa54f72c50f7cdbafa1ba06b452ab23ac207b983`。
- Pool ID：`0xc7aad6239e71df094177e4fceb3e33a9131a8f29b6a453be44984050aa1a4418`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xbc37c72e62fed3c29e3c6baa0e7677fedca64f78`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x0335a28d654c8b98b71c613fe8e64f1f5f0fd832b1723a89d3efd3e3ac898353` | 73886058 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x65f271259adace31eaa6fa201f08f752021ab1db2a4b0c947b70206a1349fca6` | 73886539 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xfdaff0e8d17d5c9461441b145f9f762bc6207b5be7cb9d3c84105598e249a44a` | 73886540 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x7ad5bee9decbd133a75fd44f16dab0d29f0190aa79e12f7c3d731bffd84d48a2` | 73886899 | 成功（status=1） |
| Factory 验证 Adapter | `0x6ad79cd202601ae61764e8d6b3223e22f4825e58c8b59b79ab6f51269d0464e2` | 73886899 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x15e6fd2b68ed437f5054249a74bdacfbdf0aa07b3d855baed82554dcd9e42c18` | 73887652 | 成功（status=1） |
| 创建并初始化 Pool | `0x72b276f14a50fcf86a856cb9c7c8873bbf8d9716f981ed6675e6d3b5a93e1f0e` | 73887978 | 成功（status=1） |

### 14. RWAT — 0x4bEE53f182F871d1204D256Fe8e4265b23b7A261

- securityId：`0xca0740572d1f7b7721971c850dd0c11cd443e30388fe86bfde58afdd435aef8a`。
- LegalShareAdapter：`0x88a9c745219274b562ed06abd22ff4906ab6f6d8`。
- Pool ID：`0xa1595d030614370c0129d23379a19e120d1bc1fb0448907d17752b4675ad23b9`。
- currency0：`0x6d0158fe5e1fc6e3756c7b66527b2ea86b8adb9d`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x18770b876aaca2889d4c4bcb21c10ff2c0b2557c4552f36b966b64e40835812e` | 73886058 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x320baa5acd1af3ad5646c852aa81709ea1389563ef46a40146f13448ae4cec9a` | 73886540 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xb088bb01efe0175e54db86e50c1d53ae7a01dfca1aae5189ca6c423e731589b2` | 73886541 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xc03d4558ec570c43778dc6fa751332231befa40b52fb709b00b58f5b3502645d` | 73886900 | 成功（status=1） |
| Factory 验证 Adapter | `0xa4bde862a6865f8a8bf21a41fae0c44b62825ed779d8fabc05595164b96d6e69` | 73886900 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xda49adcbe432b21f669fe843a57bd56a70c6f952b56c83f44596f5100a40b30d` | 73887653 | 成功（status=1） |
| 创建并初始化 Pool | `0x8cfa10a17a79f8a75f1158e94ca7beb98bb78b975b7161c8de00fa9a73b79899` | 73887979 | 成功（status=1） |

### 15. RWAT — 0x7283faBD88b147CD7e49F505AA1F848D6B14a95d

- securityId：`0x47a9f769362d5692af66388a33346c0abb94eeda9be8153c055f143a5b7e017c`。
- LegalShareAdapter：`0x009c72e074014f4e8f0efa4a114138ab8babadce`。
- Pool ID：`0x87dcbc0b521ffef9bff90f53d1f26af14802c1d0c59678aa1ffa89b766b92c09`。
- currency0：`0x24b89fdbd2aea020fe0b0d2a6973620201d42dfc`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x6d3227862d168547c4c287d572ad8331d536979796ca1d5e1e355c2b93f339ef` | 73886058 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x7982e7831f6b6f48801f6811bdab15e4d0214d1c6f08f0c7fe884386bb14ada6` | 73886542 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x60ba5aa386cd339816976d7b2a991e2b3168fbd8ade02b77d7e60e7809cfc03e` | 73886542 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x961653152e8a3d22a91eebb104091d0c8aa8c4fda0d1b3b36b5d26e6c4617092` | 73886901 | 成功（status=1） |
| Factory 验证 Adapter | `0x85831ec125101d98973f424792355d887d3ee611dad63245aad62d833cb94a5c` | 73886902 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xe2efcfd703edb6841c74fc1fb9b225ca2f16898ed412f22b13d32958f38a9f2e` | 73887654 | 成功（status=1） |
| 创建并初始化 Pool | `0x855c52a975eba173e9cdbc9efe60810e230264edccef317ba33466e1213e0940` | 73887980 | 成功（status=1） |

### 16. RWAT — 0x531922E67811467D5dd5137755a38AeD15e5df35

- securityId：`0x1e581453c588e394b5f0634ffc49d72844237d818e5e95bd9eba22af10e382e4`。
- LegalShareAdapter：`0x912ea2f4256a68036a110c10fed93d532b325804`。
- Pool ID：`0x7b95c0fb6fc6cb090e14fb103f8a6afa9d082b27b8565e47dc13427a6749427a`。
- currency0：`0x74a3537c526e05e413184b82d57b62c40b4abb61`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x030181d8d2ac1e1559d85560194e531ac9751d5e2ddd0ddd45dc402ec2d04f3b` | 73886059 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xeeadc6df71a42d7244f950e7a3943e3fbcd534fc31c4ccad9d0677f7a6c45370` | 73886542 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xf96d896e594628e52a1a9f50ba0028294ed14f533319527bc3018a16ac4a64f4` | 73886543 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x4848c3fcb423d8b459109062adce6c3d43381bc50eb461f9739d5c6af6f15cbc` | 73886903 | 成功（status=1） |
| Factory 验证 Adapter | `0x217c70344d9e9a8baa39559644f36f5d547d4846e059f248986c29103399ba4e` | 73886903 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x0410547ecb10ca59fecdce703d123948db072fb875e031c44b9924811a668cb1` | 73887654 | 成功（status=1） |
| 创建并初始化 Pool | `0x6d4ececc1e8c0b690315dce977ac4fe06e3fe8d567f9d1c95400b7cfa3c99373` | 73887981 | 成功（status=1） |

### 17. RWAT — 0xc9B54c9cC12983099fcD49F0357B08A2596f9C54

- securityId：`0xc1ef2fbc72c1a8f5bf6896c9549fe09c4b998abb8f7d3f892185e9f716508ab5`。
- LegalShareAdapter：`0x5fa272d3a2edec34107c7bf27d45641c81a897b3`。
- Pool ID：`0xbadc45b04cc2d2d7d36f958a2626c15224438cfe3ed4d878e70b56b99f9d2b96`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xb5c940504e04e3642f98973bd1b04aa103cb1382`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x3e921d733c408216b5f5c3856d1aa54e726fce24546243122e0778a04d056fd1` | 73886060 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xf5d0c8131192205c646f486513ab03fc77503102141884e7b14d714c8ac30c85` | 73886544 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x89d69d2be9e1b8386b20f4fb5f5c4347bcfdc726885acb23786e8fc74b6cbf72` | 73886545 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xe0c60e061a293ead6bd0bc4fba9b429f9f88fc9da1acaef408efee12b84fb73d` | 73886904 | 成功（status=1） |
| Factory 验证 Adapter | `0xe880157aa01a1d590af78a216f8bcc58213a720b364b466e72c7bbea6418bfbc` | 73886905 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xe117bdd6d9c916b0eacd25fd8d5c824ecca76c309c9b287f4bc18349b642ff35` | 73887654 | 成功（status=1） |
| 创建并初始化 Pool | `0xe920d1f34265ffba6c8fe09e3e736e095114c2628eeb12eef9433f1a55f80ffa` | 73887982 | 成功（status=1） |

### 18. RWAT — 0x78FA06BD9e8a7Af4aEe36F9Fa348080D2f27Bf46

- securityId：`0x4de15752d9b8120f45f5ee50690c43a383b81d8f3769b9456132f627482f5f60`。
- LegalShareAdapter：`0xe9e8a762cb745754003be80229558aac0aada314`。
- Pool ID：`0x19bbe53c3d4484c5cd23ac94ff8bbea842f0e68bf69150ef5f8d4c4f85015f40`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xfb2b022ae90e5a54f74d0805fd64f7843a73be7e`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0xaebb813cd102f138053aaf3a4b35365dc8856e7fedbf7bb3119030b3e89cb74b` | 73886061 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x81d759043bd3ee84466d82e4a290d3b9b87fb88be7376d269e48ce62c340b9c0` | 73886546 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xe400e83d38f15c5660fff4b8d64d90b96a3ace0c7adc2dc58eb6531e9840e770` | 73886546 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x8a7a00b9987ad2c070e0e6b029e05713ac3e4ca85af8880b11129a8bd0242ef0` | 73886905 | 成功（status=1） |
| Factory 验证 Adapter | `0xcf8078ccf7d493c9571c0cb7573b777c578f217c14a53ddd142d14564ea08add` | 73886905 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x5b8c2f6f7ed0a76767becc90af13e2f2ca40d06f29c7667c9b4d953dc9fe98f6` | 73887654 | 成功（status=1） |
| 创建并初始化 Pool | `0x31a4daa0922a120c69cc3368de91f3bed61fca556a89ba70f96ef74e00d558fd` | 73887983 | 成功（status=1） |

### 19. RWAT — 0xb879670887B5328e805309FD37f76A2F598e129D

- securityId：`0xa2fab2fcdd9676434ac69cbb15d7e46e0a10b461463b38694e0ba509d871d296`。
- LegalShareAdapter：`0x61f6c564813fe39d239487c9dc7f4f9d069a4507`。
- Pool ID：`0x200cedf5334b104e0e3b584d1da24610a480412dea804282fb2798ab25133978`。
- currency0：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- currency1：`0xafc4dc44d30e266c59d11ac05f14a60a802a2682`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543950336000000`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x33ad11d52ca0597cef2fed51c0eb705d68555a73f498735d73030cd9437c24ce` | 73886061 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x95760f50c7306193a897aee0553a2f32ea6775540ef3e2b59821e0827af086a7` | 73886546 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x1683bab7c5cc60212c3dabda4053ece913e2087404fc19915997157d5d2633ac` | 73886546 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xf1ee0861bfd175555310431483e1a520a7ea80964b0b2c8532003b5749bf8160` | 73886905 | 成功（status=1） |
| Factory 验证 Adapter | `0x2cb0db4e42798658073af37d209f425a49ecf98861876fd894122a2824cf43c6` | 73886905 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x70485a8184797b6154ad38fd9f47c1a478f6c0540cd7f4bad96af2d241d94286` | 73887654 | 成功（status=1） |
| 创建并初始化 Pool | `0x3d1b6739c815f17feed6ed8b483b15be9339fa38ac5fc9ce83df890eeda46a14` | 73887984 | 成功（status=1） |

### 20. RWAT — 0x9eBc3dc2807F7323aCfe4B5f345291A4AD6b3F1B

- securityId：`0x353db7828fcac8a3753fc59248247e1f0c19197e08cec1feb522115bbc471f95`。
- LegalShareAdapter：`0x15a58b2dd1ccba6756650377dc9f50f16b548107`。
- Pool ID：`0xff00ddfc76c89cdf639fc293b39535133d663b0b739c327db62656171f08c18b`。
- currency0：`0x22af80b3e786d0e4557bde7cde3810411d2768a7`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x2f2faf83c13c7284a51122b6991b01be91d57e462e3a122cf0b20fcc324be44d` | 73886062 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x32eabdfa62a612b04ef9c9b8bd73ef5933dcabb54e8ce21a0bd8d1190bb3ddcf` | 73886546 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xc9562b431ecc8d9197fb9ba4a7f797e633edbee6238dfc473945569de52d7f7c` | 73886546 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0xf9d16b370ca8f1a1bc9b6a6bb26149f2cb7148ab9982b3f231c316ef06f50315` | 73886905 | 成功（status=1） |
| Factory 验证 Adapter | `0x71cde6849c52890fe2bc4f4dda37273fe552b2cac32f93f04e1969d3420b9478` | 73886906 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x4e71e8eae1e53c4f9f81f67dbf0a68d5df415d13ce763efd5c8101292831bf30` | 73887655 | 成功（status=1） |
| 创建并初始化 Pool | `0x897822d0d6f0cb1340193b48e0b1453d0acd7d34c1ea2120dcea9b645484916e` | 73887985 | 成功（status=1） |

### 21. RWAT — 0xbaDeDb3F01632Bc1508F2A952472edF1fa3b808C

- securityId：`0xbc27234fb6e9d3f5109453d7db67f41aba1bb3f0f62052d34d5638ab19d8cfcd`。
- LegalShareAdapter：`0xfda4ed7f284369a7bc85dfb40e18fa3aa520e67e`。
- Pool ID：`0x463b34d1387559a8c4f561b01c299e36dd9959987177fc79dd510514acd5c5f8`。
- currency0：`0x3647e495a1c79ab9e5506715c5112ef1ad77082a`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x070683b298191f56814bb51cf2b951ff0deb2058265045a879014419c7cb77a3` | 73886062 | 成功（status=1） |
| 部署 LegalShareAdapter | `0x9d08f229bf0659c9161a1b614700da5474bea5af11871bd2ee80f3ad7b01eba2` | 73886547 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0x70acd3fc6457e39b6d7e704b87329709b306ba0a258b0cb3cd136fa278eb8860` | 73886548 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x37450c82753f447b2408d22f4ba6fa78e95c073b9694e4c038b1b0568dcb75a3` | 73886906 | 成功（status=1） |
| Factory 验证 Adapter | `0xfac825c526005a8cc9bf76e29f21e493c6f1d5e655b25e4a7e60d40b6be4ecc5` | 73886907 | 成功（status=1） |
| Registry 注册 Underlying / security | `0x3fe46b654ac752b354e61b270790b4ad533c31c0374617458b377d0744538f64` | 73887656 | 成功（status=1） |
| 创建并初始化 Pool | `0xf72dae22304f5b8585fbbddd69585f49020998e438b82770c2e9113ee445ba98` | 73887986 | 成功（status=1） |

### 22. RWAT — 0x45e33E9B75A3bd3BcC6aa3FDCa680248904A4cD1

- securityId：`0xbba5353baea22eb72902ef82f80d2d2f045c1b3c7e965183981de38539dd68d8`。
- LegalShareAdapter：`0x99e61f27c8d70e16da82c6f22d83bf7210931d3a`。
- Pool ID：`0x63c674a75f3c967f98c0cb8b61701f0bac87071c41fde6dcd6624a752f42749e`。
- currency0：`0x1a352ed00823a605924136d852723a3386348930`。
- currency1：`0x779ded0c9e1022225f8e0630b35a9b54be713736`。
- fee：2000；tickSpacing：60；hooks：`0xbc6d8c8a8b681872a93554116f01268f80c9ffff`。
- 初始 sqrtPriceX96：`79228162514264337593543`（整数，按币种排序和小数位换算）。
- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。
- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。

| 操作 | 交易哈希 | 区块 | 回执 |
| --- | --- | --- | --- |
| Mint 余额缺口 | `0x41edae937d0fa5837b686df36a3dbf9c7e3deed6564fb1b7527cbb56bd0eda17` | 73886063 | 成功（status=1） |
| 部署 LegalShareAdapter | `0xdcc0c7183e66cec95a3e0350d21a3721b53270c1d49184d0e84fa40a982e4c8a` | 73886548 | 成功（status=1） |
| Factory 部署 PermissionsAdapter | `0xf126f9b9172e683958ea08042a06edb5954559798990a782fd18a9517a054953` | 73886548 | 成功（status=1） |
| 转入 0.1 枚底层 Token | `0x4ed16b560aa40a6893f20a36dbe2c05f59a4bc4d0d91919a0b29196d8e05a655` | 73886908 | 成功（status=1） |
| Factory 验证 Adapter | `0x0fcc88338d13ebab4c0e8bdd80a69ba08d22c35ea96d4d16ab31da1b866c3336` | 73886909 | 成功（status=1） |
| Registry 注册 Underlying / security | `0xaa8dd64c2b0f544b7ec430245ea590fd4ebb571a40e3a9403eb935719cd9ad89` | 73887656 | 成功（status=1） |
| 创建并初始化 Pool | `0xd91f4172b0a57596591a859a3c9f032e75c50a039ea7b70659e2a582bc6e93e6` | 73887987 | 成功（status=1） |

## 共用交易与最终核验

- 设置 tier 3 容量为 40：`0xf5b0ca97efaf480b110a105ad12c2d13883bf3608927d1c93d53a1941f7bb3bc`。
- 已核验成功交易 155 笔；实际 Gas 费用合计 `0.001186151019307548` OKB（按各回执 gasUsed × effectiveGasPrice 求和）。
- 最终池状态核验使用固定区块 73888050；先前阶段复用已保存的成功回执。
- tier 3 最终容量/占用：40 / 22。
- 22 个池的 sqrtPriceX96 均与初始化参数一致，liquidity 和 Registry tickCount 均为零。

## 证据文件

- `execution.json`：完整地址、PoolKey、securityId、交易哈希和最终状态。
- `mint/create/tier/verify/register/pools.receipts.json`：各阶段从 RPC 获取的交易回执。
- 对应的 `.broadcast.json`：Foundry 广播记录；`.simulation.log`：模拟结果。
- 每次发送前通过 SDK 模拟；每个阶段发送后检查 status=1 和状态回读。
- `diagnostic.json` 为执行前服务与 mint 只读模拟结果；历史 `PREFLIGHT.md` 中未就绪状态已由本报告的执行结果取代。
