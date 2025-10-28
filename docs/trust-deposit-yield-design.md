# Trust Deposit Yield Distribution – High-Level Design

## Overview

This document specifies how to extend the Verana chain to fund, accrue, and distribute Trust Deposit (TD) yield sourced from protocol rewards. It draws on the `veranatest` proof of concept while generalizing the design for production. Developers should use this specification when implementing or reviewing the feature; it deliberately omits low-level scaffolding details.

## Existing POC Behavior (Reference)

The POC (`veranatest`) implements the minimum viable flow:

- Governance (or any account) can send funds into the Verana Pool account via `MsgCreateContinuousFund` or `MsgFundModule`.
- The TD `BeginBlocker` calculates a per-block allowance from static params and, when enough dust accumulates, transfers coins from the Verana Pool module account straight into the TD module account (`x/td/keeper/abci.go`).
- `MsgFundModule` exists primarily to work around [cosmos/cosmos-sdk#25315](https://github.com/cosmos/cosmos-sdk/issues/25315) by seeding module accounts and—in the TD case—incrementing `trust_deposit_value`.
- No further bookkeeping happens after the transfer: the TD ledger is not updated, addresses/denom are hard-coded, and excess funds remain in the Verana Pool until the next sweep.

This document layers production expectations on top of that baseline; each enhancement below lists its reasoning to make review easier.

## Goals & Non‑Goals

- **Goals**
  - Route a protocol-controlled revenue stream into a dedicated yield buffer (“Verana Pool”).
  - Transform accumulated rewards into TD principal growth at a parameterized maximum rate.
  - Preserve existing TD share accounting so that yield accrues proportionally to holders’ shares.
  - Provide governance hooks to configure funding and operational parameters.
  - Ensure unused funds flow back to the community pool, avoiding idle balances.
- **Non‑Goals**
  - Redesign of the core TD share model (already present in Verana).
  - Changes to withdrawal logic or TD product UX.
  - Automated money market strategies beyond fixed-rate yield distribution.

## Architectural Components

| Component | Responsibility |
| --- | --- |
| `x/protocolpool` (existing) | Hosts community/pool funds; governance can create continuous funding streams. |
| **Verana Pool Account** | Module account that buffers continuous funding before TD consumption. |
| `x/td` module | Applies rate limits, dust accounting, and transfers yield into the main TD ledger. |
| `x/td` keeper | Maintains module params, dust totals, and orchestrates BeginBlock actions. |
| **TD Ledger (existing)** | Tracks deposits, withdrawals, and share ownership; receives yield injections. |

The following sections specify the Verana additions in detail.

## Module Accounts & Denoms

- `td` — TD module account (already exists in Verana). Receives yield prior to crediting the TD ledger.
- `verana_pool` — **new** module account dedicated to temporary custody of incoming yield. Must be registered in the auth module configuration with no special permissions and **not** blocked for receiving funds.
- All transfers use the chain base denom (`uvna` unless configured differently). Avoid hard-coded literals where possible; pull the base denom from `sdk.GetConfig().GetBondDenom()` or bank keeper params.

## Parameters (`x/td`)

Extend the TD module parameters to include:

| Param | Type | Description |
| --- | --- | --- |
| `trust_deposit_share_value` | `math.LegacyDec` | Existing invariant share value (should remain 1.0 unless TD economics change). |
| `trust_deposit_total_value` | `sdk.Int` / `uint64` | Total TD base value used to bound annual yield; mirrors the TD ledger TVL. |
| `trust_deposit_max_yield_rate` | `math.LegacyDec` | Maximum annualized yield rate (e.g. 0.15 for 15%). |
| `blocks_per_year` | `uint32` or `sdk.Int` | Chain-specific estimate used when converting annual rate into per-block allowances. |
| `verana_pool_address` | `string` | Bech32 string for the Verana Pool module account (default: module addr derived from name). |

**Justification vs POC:** The POC stores only share value, total value, and rate, with no validation or address configurability. Production requires configurable block cadence (networks may tune it), validated financial caps, and removal of hard-coded addresses to avoid runtime breakage.

Parameter validation must enforce non-negative amounts, rate ≤ 1, and a non-zero block count.

## Keeper State

```go
type Keeper struct {
    Params      collections.Item[types.Params]
    DustAmount  collections.Item[types.DustAmount] // micro-denom fractional remainder
    // External keepers
    BankKeeper      types.BankKeeper
    AccountKeeper   types.AccountKeeper
}
```

- `DustAmount` stores sub-micro-unit residues as `LegacyDec` to prevent lost yield.
- Share accounting (who owns which portion of TD) is already implemented elsewhere in Verana and operates independently of this feature. The keeper only needs to ensure the module account balance grows; existing TD logic can derive updated share value on demand.

**Justification vs POC:** The current keeper only tracks params/dust and stops after moving coins. Production must still surface the increased balance to TD share accounting, but that can remain encapsulated in existing TD code without a new interface.

## Messages & Governance

1. **`MsgFundModule`** (unchanged signature): allows manual funding of module accounts. Require the caller to match the module authority (defaults to the governance module account) so only authorized operations can seed TD funds. Still wrap with an allowlist so only recognized modules (`td`, `verana_pool`) can be targets, and align behavior with parameter/state updates (e.g. refresh `trust_deposit_total_value` if TD is funded).
2. **`MsgUpdateParams`**: governance-authorized update covering all parameters. Enforce that partial updates are validated and maintain invariants.
3. **`MsgCreateContinuousFund`** (protocol pool module, existing): Governance proposal instructing `x/protocolpool` to remit a percentage of community tax each block to the Verana Pool account. Document the expected set-up for operators (see Admin Flow).

**Justification vs POC:** Messages remain the same, but the allowlist/validation guidance prevents misuse (POC accepts any module target and lacks invariant checks).

## Begin Block Flow (`x/td`)

Executed each block after distribution and protocol pool modules:

1. **Load Params & Dust**: `params := k.GetParams(ctx)`, `dust := k.GetDustAmount(ctx)`.
2. **Compute Allowance**:
   ```go
   annualYield := params.TrustDepositTotalValue.Mul(params.TrustDepositMaxYieldRate)
   perBlock := annualYield.Quo(decFrom(params.BlocksPerYear))
   totalDec := dust.Add(perBlock)
   ```
3. **Check Balance**: `available := bankKeeper.GetBalance(ctx, veranaPoolAddr, denom)`.
4. **Determine Transfer**:
   - `transferInt := totalDec.TruncateInt()`
   - `transferInt = min(transferInt, available.Amount)`
   - If `transferInt.IsZero()`: store updated dust (`totalDec`) and exit.
5. **Pull Funds**:
   - `transferCoins := sdk.NewCoins(sdk.NewCoin(denom, transferInt))`
   - `bankKeeper.SendCoinsFromModuleToModule(ctx, VeranaPoolAccount, types.ModuleName, transferCoins)`
6. **Credit TD Ledger**:
   - Ensure the TD module’s existing accounting observes the increased module balance (no new interface required; Verana already exposes share ownership and reacts to balance changes). If the parameters cache `trust_deposit_total_value`, refresh it from the authoritative TD data that already exists.
7. **Update Dust**:
   - `remaining := totalDec.Sub(decFrom(transferInt))`
   - `k.SetDustAmount(ctx, remaining)`
8. **Sweep Excess** (optional but recommended):
   - After crediting yield, read Verana Pool balance again.
   - If non-zero, send residual back to community/protocol pool account (module-to-module transfer) to keep the buffer empty.

Every step must log context-rich messages for operations observability.

**Justification vs POC:** Steps 3–8 mirror the POC flow but make existing gaps explicit: partial payouts (step 4) and sweep (step 8) ensure funds do not stall. Step 6 simply clarifies that existing TD accounting must recognize the balance increase; no additional share logic is specified here.

## Trust Deposit Ledger Integration

The existing TD ledger already maintains a mapping of accounts to shares:

- **Expectations**: yield injections should increase the pool value without changing individual share counts.
- **Interface expectations**: No new methods are required for this feature. Continue to use whatever Verana already exposes to read total TD value (if needed for params) and to maintain share price invariants. If the TD module infers value strictly from its module account balance, no extra plumbing is necessary.

Share ownership is a separate concern, already solved in Verana. This specification assumes that layer continues to function once additional funds reach the TD module account.

## Admin Flow

1. **Governance Funding Setup**
   - Submit `MsgCreateContinuousFund` targeting the Verana Pool account with the desired percentage (e.g. 0.05% of community tax).
   - Include metadata documenting the TD module’s use of funds and the expected burnDown.
2. **Parameter Initialization**
   - Governance issues `MsgUpdateParams` (or `param-change` proposal) to set:
     - `trust_deposit_max_yield_rate`
     - `blocks_per_year`
     - (Optionally) `verana_pool_address`
3. **TD Ledger Alignment**
   - Ensure operational runbooks make it clear how total TD value is measured today (module account balance vs. dedicated keeper state). If the value is cached in params for rate calculations, schedule periodic syncs from the trusted TD source.
4. **Monitoring**
   - Dashboard/CLI queries reference new endpoints:
     - `QueryParams` — verify configuration.
     - `QueryDust` (optional addition) — track accumulated dust above micro precision.
     - Bank queries on the Verana Pool account should remain near zero outside short-lived per-block spikes.

## Payment Flow Summary

```
Community Tax → Protocol Pool → (governance) Continuous Fund → Verana Pool →
BeginBlock (x/td):
  compute allowance
  pull min(allowance, balance)
  forward to x/td ledger (ApplyYield)
  adjust dust + sweep excess back
Result: TD share value increases; per-holder positions grow automatically.
```

By crediting the TD ledger, individual holders accrue yield proportionally without new messages or manual claims.

## Handling Prior Gaps

| Gap Observed in POC | Production Resolution |
| --- | --- |
| Hard-coded addresses/denom | Parameterize addresses, derive denom via bank/mint params. |
| No partial payout when funding < allowance | Use `min(allowance, veranaPoolBalance)` to transfer whatever is available. |
| Funds stranded in intermediate pool | Post-transfer sweep back to community pool. |
| Parameter validation empty | Implement strict validators (non-negative, rate bounds, etc.). |
| Unlimited `MsgFundModule` targets | Enforce allowlist and update `trust_deposit_total_value` only when TD is funded via ledger API. |
| Missing ledger integration | Document how existing TD accounting observes balances; no new interfaces are required, just ensure value tracking matches expectations. |
| FundModule workaround | Keep the existing workaround comment and logic until the upstream SDK bug is resolved; document its purpose for reviewers. |

## Testing Guidelines

- **Unit tests** for BeginBlock cases:
  - Exact multiple of micro units (no dust).
  - Dust accumulation leading to transfer.
  - Available balance < allowance.
  - Empty Verana Pool (no transfer, dust persists).
- **Integration tests**:
  - Governance proposal wiring from protocol pool to Verana Pool → TD module.
  - Verification that TD share values change without altering share counts.
  - Parameter update governance path (positive + failure cases).
- **Invariants**: Ensure total coins in TD ledger + Verana Pool equals protocol pool contributions minus sweeps.

## Developer Notes

- Maintain deterministic ordering in BeginBlock so TD runs after distribution and protocol pool.
- Ensure migrations update params with new fields and initialize dust record if absent.
- Provide CLI/REST handlers mirroring existing module patterns (`query params`, `tx fund-module`, etc.).
- Document operator playbooks alongside this spec in chain operations docs.

---

Ownership: Verana Core Engineering  
Status: Draft for review (2024-XX-XX)
