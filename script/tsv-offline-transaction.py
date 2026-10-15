#!/usr/bin/env python3
"""Prepare and sign one bounded transaction offline; stdout is signed bytes, never log it."""
import argparse,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
FILE=ROOT/'dployment/XLAYER_MAINNET_SMOKE_20261014.json'
def cast(*args):
 return subprocess.check_output(['cast',*args],cwd=ROOT,stderr=subprocess.DEVNULL,text=True).strip()
def linked_artifact(path,manifest):
 a=json.loads(Path(path).read_text()); code=a['bytecode']['object'].removeprefix('0x')
 libraries={'PermissionedValidationLib':manifest['supportingContracts']['permissionedValidationLibrary'],'TSVLPManagerLib':manifest['supportingContracts']['lpManagerLibrary'],'LPPositionMath':manifest['supportingContracts']['lpPositionMathLibrary']}
 for refs in a['bytecode'].get('linkReferences',{}).values():
  for name,positions in refs.items():
   address=libraries[name].removeprefix('0x').lower()
   for pos in positions: code=code[:pos['start']*2]+address+code[(pos['start']+pos['length'])*2:]
 if '__' in code: raise RuntimeError('unlinked artifact')
 return '0x'+code
p=argparse.ArgumentParser();p.add_argument('--nonce',required=True);p.add_argument('--gas-limit',default='6000000');p.add_argument('--to');p.add_argument('--value',default='0');p.add_argument('--data');p.add_argument('--create',choices=['aa-implementation','aa-factory','registry','registry-sbt','ledger','router','lpManager','hook']);args=p.parse_args()
j=json.loads(FILE.read_text()); key=os.environ['PK']; data=args.data
if args.create:
 if args.create=='aa-implementation': data=linked_artifact(ROOT/j['aa']['implementationArtifact'],j)
 elif args.create=='aa-factory': data=linked_artifact(ROOT/j['aa']['factoryArtifact'],j)+cast('abi-encode','constructor(address)',j['aa']['implementation'])[2:]
 else:
  names={'registry':'TSVRegistryV1','registry-sbt':'TSVRegistrySbtMigration','ledger':'TSVVolumeLedgerV1','router':'TSVSwapRouterV1','lpManager':'TSVLPManagerV1','hook':'TSVHookV1'}
  name=names[args.create];data=linked_artifact(ROOT/'out'/f'{name}.sol'/f'{name}.json',j)
  if args.create=='router':data+=cast('abi-encode','constructor(address,address)',j['dependencies']['poolManager'],j['factories']['permissionedAdapter'])[2:]
  if args.create=='lpManager':
   d=j['dependencies'];c=j['configuration'];data+=cast('abi-encode','constructor(address,address,uint256,address,address,address,uint256,address)',d['poolManager'],d['permit2'],str(c['unsubscribeGasLimit']),d['positionDescriptor'],d['wokb'],j['factories']['permissionedAdapter'],str(c['deliveryGasLimit']),j['proxies']['registry'])[2:]
cmd=['cast','mktx','--chain','196','--nonce',args.nonce,'--gas-limit',args.gas_limit,'--gas-price','40000001','--priority-gas-price','1','--value',args.value,'--private-key',key]
cmd+=['--create',data] if args.create else [args.to,data]
r=subprocess.run(cmd,cwd=ROOT,text=True,capture_output=True)
if r.returncode:raise RuntimeError('offline signing failed')
print(r.stdout.strip())
