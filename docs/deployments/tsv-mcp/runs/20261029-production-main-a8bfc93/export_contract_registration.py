"""Export one public registration draft per actual/planned production contract."""
import copy
import datetime
import hashlib
import json
import zipfile
from pathlib import Path
from zoneinfo import ZoneInfo

RUN = Path(__file__).resolve().parent
OUT = RUN / "contract-registration"
CONTRACTS = OUT / "contracts"
CONTRACTS.mkdir(parents=True, exist_ok=True)
MANIFEST = json.loads((RUN / "manifest.json").read_text())
ADDRESSES = json.loads((RUN / "addresses.json").read_text())["addresses"]
SNAPSHOT = json.loads((RUN / "contract-registration-chain-snapshot.json").read_text())
CHAIN_RESULTS = {r["id"]: r["result"] for r in SNAPSHOT["responses"]}
HOOK_CHECK = json.loads((RUN / "contract-registration-hook-check.json").read_text())
MANUAL = json.loads((RUN / "manual-hook-deployment.json").read_text())
VERIFICATIONS = {json.loads(p.read_text())["contract"]: json.loads(p.read_text()) for p in (RUN / "verification").glob("*.json")}
COMMIT = MANIFEST["source"]["commit"]
REPO = "https://gitlab.okg.com/web3-dex/tsv"
PENDING_FIELDS = ["module_name", "visibility_scope", "业务来源", "业务版本 ID", "合约属性", "合约范围", "main_developer", "是否进行活跃检查"]

SPECS = [
    ("PermissionedValidationLib", "Library", "src/v1/libraries/PermissionedValidationLib.sol", "Registry 链接使用的权限资产、身份权限与证券准入验证库。"),
    ("TSVLPManagerLib", "Library", "src/v1/libraries/TSVLPManagerLib.sol", "LPManager 链接使用的权限校验、强制退出、结算和资产交付逻辑库。"),
    ("LPPositionMath", "Library", "src/v1/vendor/permissionedPools/libraries/LPPositionMath.sol", "计算 tick 对应平方根价格及代币数量对应流动性的数学库。"),
    ("PermissionsAdapterFactory", "Factory", "src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol", "创建并验证股票 U 对应的 PermissionsAdapter（W），固定绑定本次确认的外部 PoolManager。"),
    ("TSVHookProxyFactoryV1", "Factory", "src/v1/deployment/TSVHookProxyFactoryV1.sol", "公开的 Hook 代理 CREATE2 部署工厂，预测并校验地址低 14 位权限标志，在创建代理时原子执行初始化。"),
    ("TSVRegistryV1", "Implementation", "src/v1/core/TSVRegistryV1.sol", "TSV 角色、暂停策略、证券、U/W/Q 资产、身份及池配置管理的实现逻辑。"),
    ("TSVRegistryV1Proxy", "Proxy", "src/v1/deployment/TSVERC1967Proxy.sol", "Registry 的生产业务入口，使用 ERC1967 代理委托调用 TSVRegistryV1，初始化指定管理员与升级角色。"),
    ("TSVVolumeLedgerV1", "Implementation", "src/v1/core/TSVVolumeLedgerV1.sol", "记录按证券、日口径统计的成交股数及日额度的实现逻辑。"),
    ("TSVVolumeLedgerV1Proxy", "Proxy", "src/v1/deployment/TSVERC1967Proxy.sol", "VolumeLedger 的生产业务入口，代理到 TSVVolumeLedgerV1，并绑定本次 Registry 代理。"),
    ("TSVSwapRouterV1", "Implementation", "src/v1/periphery/TSVSwapRouterV1.sol", "TSV 交易路由及结算实现逻辑；PoolManager 和 PermissionsAdapterFactory 固定在实现合约中。"),
    ("TSVSwapRouterV1Proxy", "Proxy", "src/v1/deployment/TSVERC1967Proxy.sol", "SwapRouter 的生产业务入口，代理到 TSVSwapRouterV1，初始化验证 PoolManager 并绑定 Registry。"),
    ("TSVLPManagerV1", "Implementation", "src/v1/periphery/TSVLPManagerV1.sol", "LP NFT、流动性管理、退出和权限检查的实现逻辑；使用本次已部署的两个 LP 库及已确认外部依赖。"),
    ("TSVLPManagerV1Proxy", "Proxy", "src/v1/deployment/TSVERC1967Proxy.sol", "LPManager 的生产业务入口，代理到 TSVLPManagerV1，初始化 Registry、NFT 名称和 nextTokenId。"),
    ("TSVHookV1", "Implementation", "src/v1/core/TSVHookV1.sol", "Uniswap V4 Hook 回调实现逻辑，用于 TSV 池初始化、LP 和交易权限检查及额度协作。"),
    ("TSVHookV1Proxy", "Proxy", "src/v1/deployment/TSVERC1967Proxy.sol", "通过 TSVHookProxyFactoryV1 创建的 Hook 代理；地址低 14 位为 0x3FFF，初始化信任本次 Registry、Ledger、Router 和 LPManager 代理。"),
]

def artifact(name):
    return json.loads((RUN / "artifacts" / (name + ".json")).read_text())

def canonical_type(arg):
    if arg["type"].startswith("tuple"):
        return "(" + ",".join(canonical_type(c) for c in arg["components"]) + ")" + arg["type"][5:]
    return arg["type"]

def abi_key(entry):
    return (entry["type"], entry.get("name", ""), tuple(canonical_type(x) for x in entry.get("inputs", [])))

def proxy_abi(implementation):
    # Keep the physical proxy constructor, fallback, tsvImplementation(), errors and event.
    # Add delegatecall interfaces, excluding the implementation constructor.
    entries = copy.deepcopy(artifact("TSVERC1967Proxy")["abi"])
    seen = {abi_key(entry) for entry in entries}
    for entry in artifact(implementation)["abi"]:
        if entry["type"] == "constructor":
            continue
        if abi_key(entry) not in seen:
            entries.append(copy.deepcopy(entry))
            seen.add(abi_key(entry))
    return entries

def confirmed_time(record):
    block = CHAIN_RESULTS["block:" + str(record["block"])]
    timestamp = int(block["timestamp"], 16)
    utc = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc)
    return utc.astimezone(ZoneInfo("Asia/Shanghai")).isoformat(), utc.isoformat()

index = []
for old in CONTRACTS.glob("*.json"):
    if any(old.name.endswith("_" + spec[0] + suffix + ".json") for spec in SPECS for suffix in ["", "_PENDING"]):
        old.unlink()
for number, (name, category, source, description) in enumerate(SPECS, 1):
    is_proxy = category == "Proxy"
    implementation_name = name.removesuffix("Proxy") if is_proxy else name
    pending = name not in ADDRESSES
    if pending:
        assert name == "TSVHookV1Proxy" and HOOK_CHECK["codeResponse"]["result"] == "0x"
        address, record, local_time, utc_time = None, None, None, None
    else:
        address, record = ADDRESSES[name], VERIFICATIONS[name]
        assert CHAIN_RESULTS["code:" + name] != "0x"
        assert record["address"].lower() == address.lower()
        local_time, utc_time = confirmed_time(record)
    associated_proxy = ADDRESSES.get(name + "Proxy") if category == "Implementation" else address if is_proxy else None
    abi = proxy_abi(implementation_name) if is_proxy else copy.deepcopy(artifact(name)["abi"])
    raw_abi_path = "artifacts/TSVERC1967Proxy.json" if is_proxy else "artifacts/" + name + ".json"
    owner = MANIFEST["registryInitialAdmin"] if is_proxy and not pending else None
    data = {
        "合约地址": address,
        "合约名称": name,
        "module_name": "待确认",
        "visibility_scope": "待确认",
        "业务来源": "待确认",
        "业务版本 ID": "待确认",
        "合约属性": "待确认",
        "合约范围": "待确认",
        "合约描述": description,
        "部署时间": local_time,
        "ABI": abi,
        "状态": "待部署：预测地址当前无链上代码" if pending else "已部署：链上代码及部署记录已核验",
        "是否可升级": "可升级" if is_proxy else "不可升级",
        "是否进行活跃检查": "待确认",
        "git_branch/tag": "main",
        "commit_id": COMMIT,
        "proxy_address": associated_proxy,
        "owner_account": owner,
        "repo_path": REPO,
        "release_note": "TSV 首次生产部署；冻结 main commit " + COMMIT + "。仅部署及代理原子初始化；不创建 W、不做业务绑定或资产/池配置。" +
            ("本项为手动 Factory 部署待办，尚未确认上链。" if pending else "本项已部署且与该版本构建记录核对。"),
        "main_developer": "待确认",
        "_技术分类": category,
        "_环境": {"用途": "生产", "网络": "XLayer 主网", "chain_id": 196},
        "_代码来源": {"source_path": source, "source_link": REPO + "/-/blob/" + COMMIT + "/" + source,
                        "artifact": raw_abi_path},
        "_部署证据": {"交易哈希": record["txHash"] if record else None, "部署区块": record["block"] if record else None,
                      "receipt_status": 1 if record else None, "部署时间_UTC": utc_time,
                      "核验区块": int(SNAPSHOT["block"], 16), "核验时间_UTC": SNAPSHOT["checkedAt"],
                      "区块链浏览器源码认证": "本次未进行", "证据路径": "verification/" + name + ".json" if record else "contract-registration-hook-check.json"},
        "_字段解释": {"状态": "登记草稿中的事实说明，不代表已选择平台状态枚举或启用业务。",
                      "owner_account": "代理按链上管理/升级控制账户登记；不是 Ownable.owner()、部署账户或仓库负责人。非代理地址没有独立 owner 时填 null。",
                      "proxy_address": "代理文件填写自身代理地址；实现文件填写已确认关联代理；不适用或尚未部署填 null。",
                      "部署时间": "部署交易所在区块的时间，Asia/Shanghai（UTC+08:00）；未部署填 null。",
                      "git_branch/tag": "部署时选择 main，精确版本由 commit_id 固定，不随 main 后续变化。",
                      "是否进行活跃检查": "按用户要求待确认；本次未修改平台监控配置。"},
        "_待确认字段": PENDING_FIELDS,
    }
    if category in {"Library", "Factory"}:
        data["_升级与所有权说明"] = "直接部署的普通合约/库，无代理升级机制和独立 owner；部署者不因部署自动获得协议管理权限。"
    elif category == "Implementation":
        data["_升级与所有权说明"] = "本实现地址的代码不可替换，不能把实现地址当成可升级代理。关联代理可在 Registry 的 UPGRADE_ADMIN_ROLE 授权下更换实现；实现合约构造时禁用初始化。"
        data["_关联代理管理账户"] = MANIFEST["registryInitialAdmin"]
    else:
        data["_升级与所有权说明"] = "ERC1967 代理，通过实现合约的 UUPS 升级入口升级；权限由 Registry 的 UPGRADE_ADMIN_ROLE 控制。" + ("当前仍未部署，属于预期配置。" if pending else "相关角色及 Registry 指向已有链上核验记录。")
    if category in {"Implementation", "Proxy"}:
        data["_代理关系"] = {"角色": category, "implementation_address": ADDRESSES[implementation_name],
                           "proxy_address": associated_proxy,
                           "registry_address": ADDRESSES["TSVRegistryV1Proxy"],
                           "升级管理角色": "UPGRADE_ADMIN_ROLE",
                           "升级管理员": MANIFEST["registryInitialAdmin"],
                           "关联代理部署状态": "待部署" if associated_proxy is None else "已部署"}
        if name.startswith("TSVHookV1"):
            data["_代理关系"]["expected_proxy_address"] = MANUAL["expectedHookProxy"]
    if is_proxy:
        data["_ABI说明"] = {"模式": "代理业务交互合并 ABI", "构造函数": "取 TSVERC1967Proxy 的 constructor(address,bytes)",
                          "包含": "代理自身 tsvImplementation()/fallback/错误/事件，以及实现合约的函数、错误、事件和接收接口；排除实现合约构造函数。",
                          "逻辑ABI来源": "artifacts/" + implementation_name + ".json",
                          "代理ABI来源": "artifacts/TSVERC1967Proxy.json"}
    else:
        data["_ABI说明"] = {"模式": "本次编译产物原始完整 ABI", "来源": raw_abi_path,
                          "artifact_sha256": hashlib.sha256((RUN / raw_abi_path).read_bytes()).hexdigest()}
    if pending:
        data["_预期合约地址"] = MANUAL["expectedHookProxy"]
        data["_预期管理账户"] = MANIFEST["registryInitialAdmin"]
        data["_待部署参数"] = {"factory": MANUAL["to"], "method": MANUAL["method"], "args": MANUAL["args"],
                              "完整交易参数路径": "manual-hook-deployment.json"}
    filename = f"{number:02d}_{name}" + ("_PENDING" if pending else "") + ".json"
    (CONTRACTS / filename).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    index.append({"文件": "contracts/" + filename, "合约名称": name, "合约地址": address,
                  "预期地址": MANUAL["expectedHookProxy"] if pending else None,
                  "技术分类": category, "状态": data["状态"], "是否可升级": data["是否可升级"],
                  "ABI条目数": len(abi)})

deployed_count = sum(item["合约地址"] is not None for item in index)
pending_count = len(index) - deployed_count
summary = {"导出时间_UTC": datetime.datetime.now(datetime.timezone.utc).isoformat(), "commit_id": COMMIT,
           "网络": "XLayer 主网", "chain_id": 196, "独立合约文件数": len(index), "已部署": deployed_count, "待部署": pending_count,
           "待确认字段统一值": "待确认", "文件": index,
           "不在本包范围": ["未部署的 TSVHookProxyMcpBootstrap 辅助合约", "未提供 U 地址、暂缓部署的 LegalShareAdapter", "未创建的 W", "沿用的外部 PoolManager/Permit2/WOKB/PositionDescriptor", "所有预发 TSV 合约"]}
(OUT / "index.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
readme = """TSV 本次生产部署合约登记资料

contracts/ 内一合约一份 JSON，共 15 份：14 份已部署、1 份待部署 Hook 代理。
index.json 为索引，不是额外合约记录。全部内容为本地登记草稿，未自动提交到任何合约资产登记平台。

按用户要求，module_name、visibility_scope、业务来源、业务版本 ID、合约属性、合约范围、main_developer、是否进行活跃检查统一为“待确认”。UI 中“请选择…”是提示语，不是另一个字段。尚未选择的正式枚举和业务版本 ID 不推断、不伪造。

代码版本：main / a8bfc93aa2cf40142e6511e5069d90f65b59f420。
网络：XLayer 主网，chain_id=196。本包不包含预发合约、复用外部依赖、未部署辅助合约或未部署资产专属 Adapter。

地址与状态：Hook 的预测地址尚未发现代码，其合约地址、部署时间、交易哈希和 owner_account 都留 null；预期地址及部署参数单独列出，不能将待部署文件登记为已部署。
时间：使用实际部署区块 timestamp；部署时间字段为北京时间（UTC+08:00），并另附 UTC 时间。不是编译、文件导出或 MCP 提交时间。
升级：实现地址自身不可升级；关联 ERC1967/UUPS 代理可由 Registry 的 UPGRADE_ADMIN_ROLE 升级；工厂、库不可升级。
所有权：协议使用角色而非 Ownable.owner()。已部署代理的 owner_account 按链上管理/升级账户 0xace2b3e7c752d5debca72210141d464371b3b9b1 登记。工厂、库、实现地址没有独立 owner，填 null；部署钱包不是这些合约的 owner。
代理关系：代理文件的 proxy_address 是自身地址；实现文件的 proxy_address 是已核实关联代理地址。待部署关联只放 expected_proxy_address。
ABI：非代理文件使用编译产物原始 ABI。代理文件合并代理自身 ABI 与业务实现 ABI，保留代理构造函数及 tsvImplementation()，排除实现构造函数，并按类型和签名去重；方便直接对代理进行业务交互。
状态与平台枚举：“已部署”等状态是链上事实说明，不表示平台已经登记、可见性设置完成、活跃检查启用或业务配置已完成。
业务配置：Registry 的 Hook/LPManager/PermissionsAdapterFactory 业务绑定在本次核验时仍为零；本包为部署资产资料，不能据此认定可直接交易。

每份文件包括用户列出的全部 21 项字段；以下划线开头的项目仅是来源、核验证据和填写说明。
SHA256SUMS.txt 为包内文件完整性摘要。原始部署 JSON、回执和代码核验记录保留在上一级生产部署 run 目录。
"""
readme = readme.replace("共 15 份：14 份已部署、1 份待部署 Hook 代理。", f"共 {len(index)} 份：{deployed_count} 份已部署、{pending_count} 份待部署。")
if pending_count == 0:
    readme = readme.replace("地址与状态：Hook 的预测地址尚未发现代码，其合约地址、部署时间、交易哈希和 owner_account 都留 null；预期地址及部署参数单独列出，不能将待部署文件登记为已部署。",
        "地址与状态：本次 15 个基础合约均已部署并核验。Hook 代理由用户于 2026-10-30 手动调用 Factory 创建；部署回执、实现槽、初始化参数及角色控制均已核实。辅助中转合约没有部署。")
(OUT / "README.txt").write_text(readme)
files = sorted(p for p in OUT.rglob("*") if p.is_file() and p.name != "SHA256SUMS.txt")
(OUT / "SHA256SUMS.txt").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + str(p.relative_to(OUT)) + "\n" for p in files))
archive = RUN / "TSV-production-contract-registration-20261029.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
    for path in sorted(OUT.rglob("*")):
        if path.is_file():
            output.write(path, "TSV-production-contract-registration/" + str(path.relative_to(OUT)))
print(json.dumps({"contractFiles": len(index), "deployed": deployed_count, "pending": pending_count, "directory": str(OUT),
                  "zip": str(archive), "zipBytes": archive.stat().st_size, "totalAbiEntries": sum(x["ABI条目数"] for x in index)}, ensure_ascii=False))
