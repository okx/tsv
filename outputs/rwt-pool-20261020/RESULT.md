# RWT / TSV_INSPECT_Q_1 pool — 2026-10-20

## Latest result: liquidity added successfully

The user subsequently authorized liquidity provision to the existing pool. The operation completed on X Layer mainnet.

- Pool ID: `0xcaba439292b23398ddabe09f68668d3969c3d2d3eea90108b3c2ee9766d5c0a3`.
- Payer and LP NFT owner: `0x224467f6640abe0a62d1be98187912627b59722a`.
- Actual net USDC input: `9.868657` (`9868657` raw).
- Actual net RWT input: `9.999999999999997666` (`9999999999999997666` raw).
- Maximum input caps: 10 USDC + 10 RWT. Tick alignment and rounding explain the lower actual USDC amount.
- LP NFT token ID: `8`.
- Tick range: `275720` to `276920`; current tick: `276324`, within the position range.
- Position liquidity and pool active liquidity: `336153055110232`.
- Pool position count: `1`.
- Fee remains `2000` (0.2%); sqrtPriceX96 remains `79228162514264337593543950336000000`.
- Verification block: `73718666`.
- Remaining payer balances: `1.534941` USDC and `90.000000000000002333` RWT.

All receipts were independently checked with status `0x1`. Actual input amounts were derived from net ERC-20 transfer logs. The NFT owner, full PoolKey, tick range, position liquidity and active pool liquidity were independently read back.

| Purpose | Block | Transaction |
| --- | --- | --- |
| Approve USDC for LP Manager | 73718638 | `0x97c34481b3a07d5cf4b1486c3b25152afb886825b47f416c72b7617fe6ffca5e` |
| Approve RWT underlying for LP Manager | 73718639 | `0xa3383babd23d7bc6f9e79571001a9480caf6fc974019a95ceb392901aad328f7` |
| Add liquidity and mint LP NFT #8 | 73718639 | `0x5fc3169bad4a16aa7bcbc9689aa54ed4f96e3d278f8dda629cb156ee522971f0` |

Evidence is saved in `liquidity-receipts.json` and `liquidity-final-verification.json`. Do not repeat the liquidity broadcast; it would create another position.

```sh
python3 outputs/rwt-pool-20261020/verify_liquidity.py
```

Lark logging remains unavailable following the earlier `forBidden` rejection. This complete transaction record is saved locally.

## Prior result: both SBTs issued successfully

The SBT-only step completed before the user authorized the liquidity operation above.

- Confirmed successful transaction: `0xd42f5e9d5047ed190bb5691374520e0dc88babd9fb5a9e244adc77016d4dafaf`.
- Receipt status: `0x1`, transaction block: `73718224`.
- At verification block `73718294`, both recipients held exactly one specified SBT; Registry SWAP and LP permission checks were true for both.
- No liquidity transaction was submitted during the SBT-only step.
- Confirmed signing wallet: `0x486371f86335dd1d3420bffad40959dd6e4d034c`.
- SBT: `0x053ecef8ccb8844322bee86290dae016b9843b6d`.
- Token ID: `0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38`.
- Recipients: `0x224467f6640abe0a62d1be98187912627b59722a` and `0x486371f86335dd1d3420bffad40959dd6e4d034c`, one SBT each.
- Direct `eth_call` and the SDK Forge simulation both succeeded for the batch. The simulation verified SWAP and LP permissions for both recipients.
- The first broadcast attempt failed before submission because the sender had zero native balance. After native funds arrived, a fresh simulation and broadcast succeeded.
- Independent receipt and balance verification is saved in `sbt-final-verification.json`.
- Lark logging remains unavailable because the earlier append was rejected with `forBidden`; this record is saved locally.

Do not rerun issuance. Read-only verification:

```sh
python3 outputs/rwt-pool-20261020/verify_sbt.py
```

The remaining sections describe the earlier pool work and resolved SBT blocker. Do not rerun their continuation commands: the liquidity operation has now completed.

## Historical result: pool creation before SBT issuance

Pool creation is complete on X Layer mainnet (chain ID 196). Liquidity provision is pending because the operation wallet lacks the required LP SBT.

- Operator: `0x224467f6640AbE0A62D1be98187912627b59722A`
- Pool ID: `0xcaba439292b23398ddabe09f68668d3969c3d2d3eea90108b3c2ee9766d5c0a3`
- currency0 / quote: `0xb6ceceab302e2e4948951ee7843fc24e92933061` (`TSV_INSPECT_Q_1`, 6 decimals)
- currency1 / RWT wrapper: `0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c`
- RWT underlying: `0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0` (18 decimals)
- Fee: `2000` = 0.2%
- Tick spacing: `40`
- Hook: `0xbc6d8c8a8b681872a93554116f01268f80c9ffff`
- Initial price: 1 RWT = 1 quote token
- Initial sqrtPriceX96: `79228162514264337593543950336000000`
- Initial tick: `276324`

The requested quote address returns `USDC` from `symbol()`. The user explicitly selected this address after clarification; no token metadata was changed.

## Confirmed transactions

All four receipts were independently retrieved from RPC with status `0x1`.

| Purpose | Block | Transaction |
| --- | --- | --- |
| Grant SYMBOL_ADMIN_ROLE to the existing Registry administrator/operator | 73714656 | `0x0dfb1f4c02ff00866c25b76beaef7165fc4b8a157f97e60b9d7369b6e0ab01b5` |
| Register the specified RWT wrapper against the existing RWT security | 73714834 | `0x298a4294605945727d95a77352516f8184f6dacf8ace036d54037dd8ceb6cb83` |
| Grant POOL_CREATOR_ROLE to the operator | 73714878 | `0xdb83e78624d96c98dc72de859e6cae4873961fe428898de2987e3bc490b58a8e` |
| Register and initialize the pool | 73714938 | `0xe7e03bc03ffafd0234bc0610e924f4573028e3714bb83cfa2595f7e5389c127f` |

The two newly granted roles remain assigned to the operator.

## State verified at block 73715019

- Registry recognizes the wrapper's underlying.
- Pool known: true.
- Registry `isTradable`: true. This is the Registry gate; it does not imply available liquidity.
- Position count: 0.
- Active liquidity: 0.
- Initial price and tick match the selected configuration.
- Operator RWT balance: `99999999999999999999` raw.
- Operator quote balance: `11403598` raw.
- Operator LP SBT permission: false.

## Historical liquidity blocker (resolved)

Selected maximum inputs are 10 quote tokens (`10000000` raw) and 10 RWT (`10000000000000000000` raw), with a tick radius of 600. Actual amounts may differ because of tick alignment and rounding.

The SDK simulation failed at `operator lacks LP permission`, before token approvals or transfers. No liquidity transaction was broadcast.

The operation wallet lacks both the SBT issuer role and the SBT default administrator role, so it cannot issue this credential itself.

An authorized SBT issuer must issue the configured credential to the operator:

- SBT: `0x053ecef8ccb8844322bee86290dae016b9843b6d`
- Recipient: `0x224467f6640AbE0A62D1be98187912627b59722A`
- Token ID: `0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38`
- Issuer role: `0x29076c22c58df1b92016e29d27616ab6f4ed4d26165244781b49c58b7a75839d`

After issuance, rerun the simulation and then broadcast:

```sh
XLAYER_RPC_URL=https://xlayerrpc.okx.com python3 outputs/rwt-pool-20261020/operate_pool.py liquidity
XLAYER_RPC_URL=https://xlayerrpc.okx.com python3 outputs/rwt-pool-20261020/operate_pool.py liquidity --broadcast
python3 outputs/rwt-pool-20261020/verify_pool.py
```

Do not rerun already-completed registration or initialization actions. If the signing account is changed, recheck the intended payer, recipient, permissions and balances before broadcasting.

The task runner uses the existing SDK credential loader. It compiles operator scripts and their dependencies, excluding the unrelated incompatible DexRouter script. No contract source or global Foundry configuration was changed.
