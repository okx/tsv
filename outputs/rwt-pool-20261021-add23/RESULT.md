# 2026-10-21: additional 23 USDC liquidity

Completed on X Layer Mainnet (chain ID 196).

- Pool ID: `0xcaba439292b23398ddabe09f68668d3969c3d2d3eea90108b3c2ee9766d5c0a3`.
- Payer and LP NFT owner: `0x224467f6640abe0a62d1be98187912627b59722a`.
- Actual USDC input: **23** (`23000000` raw).
- Actual RWT input: **23.779108026286146777** (`23779108026286146777` raw).
- Input limits: 23 USDC and 23.78 RWT.
- New LP NFT: **#12**.
- Tick range: `275720` to `276920`.
- Added position liquidity: `791443376188868`.
- Active pool liquidity after the transaction: `1127596431299100`.
- Pool position count: `3`.
- Verification block: `73784759`.
- Fee: 2000 (0.2%).

All receipts were fetched independently and returned status `0x1`. Exact net token inputs were verified from ERC-20 transfer logs. NFT ownership, full PoolKey, tick range, position liquidity and active pool liquidity were read back.

| Action | Block | Transaction |
| --- | --- | --- |
| USDC approve: ['0xf73D8683B948564D2795C62A2A909012eA168d29', '23000000'] | 73784698 | `0x3a53b884e9bdd4ddf063c16552e3687ca8fa9089d3e016c50f3d85391dd4c3f2` |
| USDC approve: ['0xf73D8683B948564D2795C62A2A909012eA168d29', '0'] | 73784699 | `0x1c49f316300fd1896c973f0e0d626ce0c1711b5ed9e5dca009eb27f17115de2f` |
| RWT approve: ['0xf73D8683B948564D2795C62A2A909012eA168d29', '0'] | 73784700 | `0xdb682f24f07096813cb5e31cf4597746252cd4230b9419b0db6c2e4221f277ee` |
| RWT approve: ['0xf73D8683B948564D2795C62A2A909012eA168d29', '23780000000000000000'] | 73784701 | `0x6bd28fa402fbc4808ce0f0da50b4665fac0bab27b4ce744544f87c41220995c3` |
| Add liquidity and mint NFT #12 | 73784702 | `0x52cdb04584fbc7cea15a70e21d2d3aa95f3277c303ec7e8cc0a939a00b880281` |

The initial attempt stopped before submission because of an RPC DNS failure. No new transaction record was generated, and the USDC balance was unchanged. The retry through the alternate RPC completed successfully.

Lark logging remains unavailable following the earlier `forBidden` rejection; this operation is recorded locally.

Do not repeat the broadcast. Read-only verification:

```sh
XLAYER_RPC_URL=https://xlayerrpc.okx.com python3 outputs/rwt-pool-20261021-add23/verify_liquidity.py
```
