# X Layer Mainnet RWT/USDC Operation Transaction Record

- Date: 2026-10-15
- Network: X Layer Mainnet, Chain ID 196
- Operator Wallet: `0xC2ceBE8485f666874667e500B36028AB2A297f8F`
- Scope: The 16 broadcast transactions for the RWT/USDC registration, pool creation, liquidity provision, quota configuration, and test trade described below. The receipt for each transaction was verified as successful (`status 0x1`).
- Security Notice: This document does not contain RPC credentials or private keys.

## 地址入口

预发地址统一维护于 [deployment/pre/addresses.json](../../deployment/pre/addresses.json)。本文保留操作过程及交易证据，不再维护独立部署地址表。

## Historical Standalone Factory Deployment

The new standalone `PermissionsAdapterFactory` is bound to PoolManager
`0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32`, but the Registry, Swap Router,
and LP Manager still reference the currently bound Factory above. Its deployment
transaction is `0x37bc142199016be5e476f632308bde2fe869216f64eefa607fe008b2267f40b2`
(`status 0x1`). Source verification was not performed.

This paragraph records the original observation date; current Registry bindings are listed in the pre address catalog.

## Transaction Details

### 1. Grant `SYMBOL_ADMIN_ROLE`

Purpose: Allow the operator wallet to register securities and configure security-level policies.

- Block: `0x45e6a09`
- Transaction hash: `0xa8c4f4b6d987694831177dd3d4835aaceda3ccc9ca8373daa52ae1497d61cb24`
- Status: Successful

### 2. Register QuoteToken Q

Purpose: Register `0xb0A8640210A0dA1a59d95Bd51E39b3FA488c244e` as a QuoteToken that can be used in TSV pools.

- Block: `0x45e6a89`
- Transaction hash: `0x5ee8d0d6cd17127095a22feaa9134e6546a2f3cda2d7e0bba3cdb647836ddc04`
- Status: Successful

### 3. Deploy the Legal-share Adapter for RWT

Purpose: Deploy the adapter bound to underlying U (`0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0`), configured with a multiplier of `1e18`.

- New contract: `0x1501e20d4990f4A33f3807a9482AF910bDcD3F68`
- Block: `0x45e6fd0`
- Transaction hash: `0x3738e793d172e9ef6f1cccab30168500e81f2a0c983be4a5624174d80468e27f`
- Status: Successful

### 4. Set the Tier 2 Listing Capacity

Purpose: Set the maximum number of listed securities in Tier 2 to `1`, making a slot available for RWT registration.

- Block: `0x45e7026`
- Transaction hash: `0x607f86e8d8260c5430330cce7ff7fcfdc1f100c1c6f449c349e1a2cba408647c`
- Status: Successful

### 5. Grant `POOL_CREATOR_ROLE`

Purpose: Allow the operator wallet to create TSV pools.

- Block: `0x45e70cf`
- Transaction hash: `0x9b75c9e38da7275e0ae424aa064c5b740901a03381d2eb9299e85451b57c2a51`
- Status: Successful

### 6. Issue an SBT to the Operator Wallet

Purpose: Issue the deployment-configured SBT to the operator wallet. The SBT's SWAP and LP permission bits in the Registry are `0x0003`.

- SBT: `0x053ecef8ccb8844322bee86290dae016b9843b6d`
- Token ID: `0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38`
- Block: `0x45e70f2`
- Transaction hash: `0x03b786cee461c93a4041e872d0222d78e33faa6b8f31e48ec170a16194d93621`
- Status: Successful

### 7. Register RWT and Underlying U

Purpose: Register W as RWT, associate it with underlying U, the Legal-share Adapter, and the Security ID, and list it in Tier 2.

- Block: `0x45e712d`
- Transaction hash: `0x4e012195b4aebddfc5d6ffb18f7d136926901a9249514499202877915b2a34f5`
- Status: Successful

### 8. Create the RWT/USDC Pool

Purpose: Initialize the pool in Pool Manager with a fee of `3000`, tick spacing of `60`, and Hook `0xbc6d8c8a8b681872a93554116f01268f80c9ffff`. Set the initial price to 1 RWT = 1 USDC.

- Block: `0x45e716c`
- Transaction hash: `0x01c675f43de9f7b7175523e3c5115a894aed3ffe64c023e9f9ce96ec5ce0a6d7`
- Status: Successful

### 9. Approve Underlying U for the LP Manager

Purpose: Allow the LP Manager to transfer the underlying U corresponding to 10 RWT (`10e18` raw units) from the operator wallet.

- Block: `0x45e71d1`
- Transaction hash: `0x496599bdf551643e0f025881b693b8bb9d3e3b9121f69c996757b0143fddaddf`
- Status: Successful

### 10. Approve QuoteToken for the LP Manager

Purpose: Allow the LP Manager to transfer 10 USDC (`10,000,000` raw units) from the operator wallet.

- Block: `0x45e71d2`
- Transaction hash: `0xdd569fd48c25db25e3212d9fc00412bc52a384f2068d1f42a6917fccbe6bfbb1`
- Status: Successful

### 11. Add 10 RWT + 10 USDC of Liquidity

Purpose: Add liquidity in a range of ±600 ticks around the current price.

- Range: tick `-276960` to `-275760`
- On-chain liquidity: `319520702996855`
- Position NFT: `#3`
- Block: `0x45e71d2`
- Transaction hash: `0xa29189f7b882c95f63fb14a12c8f1d9b6794e65762ea5d5b60244989ebfba361`
- Status: Successful

### 12. Grant `VOLUME_ORACLE_ROLE`

Purpose: Allow the operator wallet to configure and maintain RWT trading quotas on an ongoing basis.

- Block: `0x45e7298`
- Transaction hash: `0x409d416434ba5fca903232799a979f68a8a4c71f9eeaaff539a0a831f61a09e9`
- Status: Successful

### 13. Set the Initial Daily RWT Quota

Purpose: Set RWT's daily legal-share quota to 0.1 RWT (`1e17` WAD).

- Block: `0x45e72ba`
- Transaction hash: `0x21f4599d05e13d9b4212aa2024bdd6a77b546ea3e3bf5c3389d51d77b1b02f1f`
- Status: Successful

### 14. Increase the Daily RWT Quota to 0.11

Purpose: In accordance with the requirement to set the quota slightly above the 0.1 RWT test trade, adjust the daily quota to 0.11 RWT (`110000000000000000` WAD).

- Block: `0x45e7331`
- Transaction hash: `0x45ae855cfd03a115e8dda51273244ca1f6a6dda8bd63462a6db1805bf85f26cb`
- Status: Successful

### 15. Approve QuoteToken for the Swap Router

Purpose: Allow the Swap Router to spend 0.1 USDC (`100,000` raw units) for the test swap.

- Block: `0x45e7384`
- Transaction hash: `0xfcd047c0e20c25ef95054c0c42e36fe4eaaa44331a13e065f0805a554ae56ce4`
- Status: Successful

### 16. Execute the USDC → RWT Test Trade

Purpose: Buy RWT using 0.1 USDC, with the transaction's minimum output set to 0.09 RWT.

- Actual input: 0.1 USDC
- Actual output: 0.099668900327054221 RWT
- Daily quota used: 0.099668900327054221 / 0.11 RWT
- Block: `0x45e7385`
- Transaction hash: `0xe838e437e26251be7c68f5c840714239bd75bfae04f4bb05ca20958e99c7c326`
- Status: Successful

## Verification Results

- The on-chain receipts for all 16 broadcast transactions have a successful status.
- The RWT/USDC pool is tradable, and the operator wallet's SBT SWAP and LP permissions are both effective.
- The operator wallet holds `POOL_CREATOR_ROLE` and `VOLUME_ORACLE_ROLE`; these roles were not revoked after the quota update.
- Tier 1's only slot was occupied by an existing security. Therefore, the Tier 2 capacity was set to `1`, and RWT was registered in Tier 2.
