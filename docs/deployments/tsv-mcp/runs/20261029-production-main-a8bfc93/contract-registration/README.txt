TSV 本次生产部署合约登记资料

contracts/ 内一合约一份 JSON，共 15 份：15 份已部署、0 份待部署。
index.json 为索引，不是额外合约记录。全部内容为本地登记草稿，未自动提交到任何合约资产登记平台。

按用户要求，module_name、visibility_scope、业务来源、业务版本 ID、合约属性、合约范围、main_developer、是否进行活跃检查统一为“待确认”。UI 中“请选择…”是提示语，不是另一个字段。尚未选择的正式枚举和业务版本 ID 不推断、不伪造。

代码版本：main / a8bfc93aa2cf40142e6511e5069d90f65b59f420。
网络：XLayer 主网，chain_id=196。本包不包含预发合约、复用外部依赖、未部署辅助合约或未部署资产专属 Adapter。

地址与状态：本次 15 个基础合约均已部署并核验。Hook 代理由用户于 2026-10-30 手动调用 Factory 创建；部署回执、实现槽、初始化参数及角色控制均已核实。辅助中转合约没有部署。
时间：使用实际部署区块 timestamp；部署时间字段为北京时间（UTC+08:00），并另附 UTC 时间。不是编译、文件导出或 MCP 提交时间。
升级：实现地址自身不可升级；关联 ERC1967/UUPS 代理可由 Registry 的 UPGRADE_ADMIN_ROLE 升级；工厂、库不可升级。
所有权：协议使用角色而非 Ownable.owner()。已部署代理的 owner_account 按链上管理/升级账户 0xace2b3e7c752d5debca72210141d464371b3b9b1 登记。工厂、库、实现地址没有独立 owner，填 null；部署钱包不是这些合约的 owner。
代理关系：代理文件的 proxy_address 是自身地址；实现文件的 proxy_address 是已核实关联代理地址。待部署关联只放 expected_proxy_address。
ABI：非代理文件使用编译产物原始 ABI。代理文件合并代理自身 ABI 与业务实现 ABI，保留代理构造函数及 tsvImplementation()，排除实现构造函数，并按类型和签名去重；方便直接对代理进行业务交互。
状态与平台枚举：“已部署”等状态是链上事实说明，不表示平台已经登记、可见性设置完成、活跃检查启用或业务配置已完成。
业务配置：Registry 的 Hook/LPManager/PermissionsAdapterFactory 业务绑定在本次核验时仍为零；本包为部署资产资料，不能据此认定可直接交易。

每份文件包括用户列出的全部 21 项字段；以下划线开头的项目仅是来源、核验证据和填写说明。
SHA256SUMS.txt 为包内文件完整性摘要。原始部署 JSON、回执和代码核验记录保留在上一级生产部署 run 目录。
