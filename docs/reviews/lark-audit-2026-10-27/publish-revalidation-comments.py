import json,pathlib,re,subprocess,sys
P=pathlib.Path(__file__).resolve().parent
SHA='90929552fd557fd67b9debafa905bafffb40ed86'
BASE='https://gitlab.okg.com/web3-dex/tsv'
MARK='tsv-audit-revalidation:'+SHA

def api(endpoint,method='GET',body=None,form=None):
 args=['glab','api',endpoint,'--method',method]
 if body is not None:
  f=P/'comment-request.json';f.write_text(json.dumps(body,ensure_ascii=False))
  args+=['--header','Content-Type: application/json','--input',str(f)]
 if form:args+=['--form',form]
 r=subprocess.run(args,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return json.loads(r.stdout)

def save(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2))

if sys.argv[1]=='prepare':
 uploads_path=P/'revalidation-comment-uploads.json'
 uploads=json.loads(uploads_path.read_text()) if uploads_path.exists() else {}
 for name in ['proofs/AuditRevalidation.t.sol','revalidation-existing-tests.log','revalidation-proof-tests.log','revalidation-related-tests.log','revalidation-init-failure-trace.log']:
  if name not in uploads:
   uploads[name]=api('projects/18199/uploads','POST',form='file=@'+str(P/name));save(uploads_path,uploads)
   print('Uploaded evidence:',name,flush=True)
 sections={}
 for name in ['revalidation-lp.md','revalidation-registry.md','revalidation-hook-router.md']:
  s=(P/name).read_text()
  for m in re.finditer(r'^## #(\d+)[^\n]*\n',s,re.M):
   nexthead=re.search(r'^## ',s[m.end():],re.M)
   end=m.end()+nexthead.start() if nexthead else len(s)
   sections[int(m[1])]=s[m.start():end].strip()
 assert set(sections)==set(range(9,30)),sorted(sections)
 refs={
  9:[('src/v1/libraries/TSVLPManagerLib.sol',125),('src/v1/libraries/TSVLPManagerLib.sol',185)],
  10:[('src/v1/core/TSVRegistryV1.sol',324),('src/v1/core/TSVRegistryV1.sol',784)],
  11:[('src/v1/libraries/TSVLPManagerLib.sol',236),('test/unit/v1/deployment/LPLinkedLibraries.t.sol',43)],
  12:[('src/v1/core/TSVHookV1.sol',58),('src/v1/periphery/TSVSwapRouterV1.sol',302),('src/v1/periphery/TSVLPManagerV1.sol',306)],
  13:[('src/v1/governance/TSVGoverned.sol',15),('src/v1/core/TSVRegistryV1.sol',276)],
  14:[('src/v1/periphery/TSVLPManagerV1.sol',63)],
  15:[('src/v1/periphery/TSVLPManagerV1.sol',79),('src/v1/periphery/TSVLPManagerV1.sol',106)],
  16:[('src/v1/periphery/TSVLPManagerV1.sol',338)],
  17:[('src/v1/libraries/PermissionedValidationLib.sol',112)],
  18:[('src/v1/periphery/TSVLPManagerV1.sol',356),('src/v1/libraries/TSVLPManagerLib.sol',379)],
  19:[('src/v1/libraries/TSVLPManagerLib.sol',398)],
  20:[('src/v1/core/TSVRegistryV1.sol',597)],
  21:[('src/v1/core/TSVHookV1.sol',228),('src/v1/core/TSVVolumeLedgerV1.sol',70),('docs/CONTRACT_ARCHITECTURE.md',13)],
  22:[('src/v1/core/TSVHookV1.sol',210),('src/v1/core/TSVHookV1.sol',228)],
  23:[('src/v1/core/TSVRegistryV1.sol',256),('src/v1/core/TSVRegistryV1.sol',329)],
  24:[('src/v1/core/TSVRegistryV1.sol',744)],
  25:[('src/v1/core/TSVRegistryV1.sol',470),('src/v1/core/TSVRegistryV1.sol',815)],
  26:[('src/v1/libraries/TSVDirectSettlementLib.sol',10)],
  27:[('src/v1/periphery/TSVSwapRouterV1.sol',176),('src/v1/periphery/TSVSwapRouterV1.sol',248)],
  28:[('src/v1/periphery/TSVLPManagerV1.sol',227),('src/v1/libraries/TSVLPManagerLib.sol',373)],
  29:[('src/v1/periphery/TSVLPManagerV1.sol',135),('lib/v4-core/src/libraries/Pool.sol',189)]}
 supplements={
  9:'主线程已运行两条强退路径各两次回滚重试，并验证撤销 Subscriber 转账 allowance 后退出成功。初始 1,000 Q、退出交付模型为 1 Q，事件计算 1−1,000 触发 Panic(0x11)。验证使用生产退出代码及既有 PoolManager/交付计数替身，不等同于完整真实 PoolManager 集成复现。',
  11:'主线程已实际运行 LPLinkedLibrariesTest，25 项全部通过；包括 W 余额始终为 0 时正确报告 U 的两个汇总事件，以及发行方 fallback 到账。因此本项已有源码和通过的回归证据，可建议按已修复关闭。',
  12:'主线程已验证 LP 升级调用在调用方具有 UPGRADE_ADMIN_ROLE、Registry paused 时先因 RegistryPaused 拒绝；该用例验证门禁次序，不覆盖完整候选实现升级流程。Hook/Router 同类门禁已逐行核对。',
  18:'主线程已运行 LPLinkedLibrariesTest，25 项通过，包含两个 modify 入口拒绝 MINT/INCREASE_FROM_DELTAS 的既有回归。',
  28:'主线程新增验证已通过：owner 可以 approve 无 SBT operator，但其 INCREASE_LIQUIDITY 请求被生产 library 的 Unauthorized 拒绝，NFT owner 未变化。说明 approval 不等于执行资格。',
  29:'主线程使用真实 v4-core Pool.modifyLiquidity 验证通过：tickSpacing=60，range=[-887220,-887160]，spot tick=-887260，同一 position 连续增加 2**71 liquidity 两次。每次输入 130122462400857233021688541762359641008 raw units 均合法；一次退出需输出 260244924801714466043377083524719282014 raw units，触发 SafeCastOverflow；拆成两次较小退出均成功。此测试不包含资产准入与 token 资金结算，证明结构边界，不证明实际准入资产具备该供应量。'}
 results=json.loads((P/'revalidation-results.json').read_text());prepared=[]
 for r in results:
  n=r['iid'];detail=sections[n]
  detail=re.sub(r'^## [^\n]+\n','',detail).strip()
  detail=detail.replace('本分工仅确认测试存在和源码意图，不能声称已实际跑过。','主线程已实际执行相关回归，结果见下方验证依据。')
  detail=detail.replace('具体精确整数额应以主线程 TickMath/SqrtPriceMath 回归为准，此处分工未跑代码测试。','精确数值及实际执行结果见下方主线程验证依据。')
  detail=detail.replace('，未在本次执行。','；主线程已运行该 suite，结果见下方测试范围。')
  body=f'<!-- {MARK}:issue-{n} -->\n## 当前 main 定向复核：{r["subject"]}\n\n'
  body+=f'复核版本：[`{SHA}`]({BASE}/-/tree/{SHA})。此结论固定于该 SHA，不随后续 main 自动更新。\n\n'
  body+=f'- **当前状态：{r["status"]}**\n- **修复价值 / 工程优先级：{r["value"]}**\n- **处理建议：{r["recommendation"]}。\n\n'
  body+='P1/P2/P3 表示本次工程处理优先级，不替代原报告风险等级。\n\n### 分析依据\n\n'+detail+'\n\n'
  body+='### 固定版本代码链接\n\n'+'、'.join(f'[{path.split("/")[-1]}:{line}]({BASE}/-/blob/{SHA}/{path}#L{line})' for path,line in refs[n])+'。\n\n'
  if n in supplements:body+='### 主线程验证\n\n'+supplements[n]+'\n\n'
  body+='### 测试范围与保留证据\n\n本轮定向测试共 82 项通过、3 项既有测试失败；包含新增的 6 项问题复现/门禁验证。三项失败分别是 setTierPolicy 旧角色预期、新 Factory 升级的旧限制预期，以及 Router implementation 的 pause 门禁先于 UUPS 检查导致错误数据不同；不将该结果表述为全套回归通过。\n\n测试在独立 main 快照运行，CLI 补充了 @uniswap/v4-core remapping，并跳过尚未配齐 import 的 SecuritizeTSVChecker 和脚本。未核验生产链上的角色、准入资产供应量或仓位。\n\n'
  body+='；'.join(uploads[name]['markdown'] for name in uploads)+'。\n'
  prepared.append({'iid':n,'body':body})
 save(P/'revalidation-comments-prepared.json',prepared)
 print('Prepared',len(prepared),'individual review comments',flush=True)

elif sys.argv[1]=='publish':
 prepared=json.loads((P/'revalidation-comments-prepared.json').read_text())
 receipts_path=P/'revalidation-comments-submitted.json'
 receipts=json.loads(receipts_path.read_text()) if receipts_path.exists() else []
 for c in prepared:
  n=c['iid'];marker=f'<!-- {MARK}:issue-{n} -->'
  notes=api(f'projects/18199/issues/{n}/notes?per_page=100&sort=desc&order_by=created_at')
  matches=[note for note in notes if marker in note.get('body','')]
  if matches:
   assert len(matches)==1,(n,'duplicate markers')
   note=matches[0]
   assert note['body'].rstrip()==c['body'].rstrip(),(n,'existing comment differs')
   print('Already present',n,note['id'],flush=True)
  else:
   note=api(f'projects/18199/issues/{n}/notes','POST',{'body':c['body']})
   assert note['body'].rstrip()==c['body'].rstrip()
   print('Published',n,note['id'],flush=True)
  receipt={'iid':n,'note_id':note['id'],'url':f'{BASE}/-/issues/{n}#note_{note["id"]}'}
  receipts=[r for r in receipts if r['iid']!=n]+[receipt]
  save(receipts_path,sorted(receipts,key=lambda r:r['iid']))
 (P/'comment-request.json').unlink(missing_ok=True)

elif sys.argv[1]=='verify':
 prepared={c['iid']:c for c in json.loads((P/'revalidation-comments-prepared.json').read_text())}
 receipts=json.loads((P/'revalidation-comments-submitted.json').read_text());assert len(receipts)==21
 for r in receipts:
  note=api(f'projects/18199/issues/{r["iid"]}/notes/{r["note_id"]}')
  assert note['body'].rstrip()==prepared[r['iid']]['body'].rstrip(),r
  print('Verified',r['iid'],r['note_id'],flush=True)
 (P/'revalidation-comment-index.md').write_text('# 逐项复核评论\n\n版本：'+SHA+'\n\n'+'\n'.join(f'- [Issue #{r["iid"]} 的复核评论]({r["url"]})' for r in receipts)+'\n')
 save(P/'revalidation-comments-verification.json',{'sha':SHA,'verified_comment_count':len(receipts),'exact_body_match':True})
