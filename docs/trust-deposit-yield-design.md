# Trust Deposit Yield Distribution – High-Level Design

## Overview

This document specifies how to extend the Verana chain to fund, accrue, and distribute Trust Deposit (TD) yield sourced from protocol rewards. It draws on the `veranatest` proof of concept while generalizing the design for production. Developers should use this specification when implementing or reviewing the feature; it deliberately omits low-level scaffolding details.

## Existing POC Behavior (Reference)

The POC (`veranatest`) implements the minimum viable flow:

- Governance proposal is created to send continously a % added amount to the community Pool to the `Yield Intermediate Pool` account via `MsgCreateContinuousFund`. *
- The TD `BeginBlocker` calculates a per-block allowance from static params and, when enough dust accumulates, transfers coins from the Yield Intermediate Pool module account straight into the TD module account (`x/td/keeper/abci.go`).
- `MsgFundModule` exists primarily to work around [cosmos/cosmos-sdk#25315](https://github.com/cosmos/cosmos-sdk/issues/25315) by seeding module accounts and—in the TD case—incrementing `trust_deposit_value`.




* example of a governance proposal:
```json
{
 "messages": [
  {
   "@type": "/cosmos.protocolpool.v1.MsgCreateContinuousFund",
   "authority": "cosmos10d07y265gmmuvt4z0w9aw880jnsr700j6zn9kn",  // this is the governance module account 
   "recipient": "cosmos1jjfey42zhnwrpv8pmpxgp2jwukcy3emfsewffz",  // this is the Yield Intermediate Pool account
   "percentage": "0.005000000000000000",                          // This is the % taken from each the community pool contribution and sent immediately to the Yield Intermediate Pool account
   "expiry": null
  }
 ],
 "metadata": "ipfs://CID",
 "deposit": "10000000uvna",
 "title": "This is the proposal to allow continuous funding of the Yield Intermediate Pool account",
 "summary": "to send the amount to the Yield Intermediate Pool account address in order to distribute yield to the trust deposit holders",
 "expedited": false
}
```

## Goals & Non‑Goals

- **Goals**
  - Route block reward revenue stream into a dedicated yield buffer (“Yield Intermediate Pool Account”).
  - process the intermediary funds held in the YIPA and send the calculated amount at a parameterized maximum rate to the `Trust Deposit account`. Update the `Trust Deposit Share Value` and all the relevant TD variables as necessary for the Trust Deposit to implemented all its transactions (`Reclaim Trust Deposit`,`Reclaim Trust Deposit Yield` ) as per [MOD-TD-MSG-2] and [MOD-TD-MSG-3] specs.
  - Preserve existing TD share accounting so that yield accrues proportionally to holders’ shares.
  - Provide governance hooks to configure funding and operational parameters.
  - Ensure unused funds flow back to the community pool, avoiding idle balances.
  - Ensure potential fractional per block block yields are accumulated in Dust to ensure fair accumulation of yield over long period of time.
- **Non‑Goals**
  - Redesign of the core TD share model (already present in Verana specs, see [MOD-TD-MSG-1-7]).
  - Changes to withdrawal logic or TD module.

## Architectural Components

| Component | Responsibility |
| --- | --- |
| `x/protocolpool` | Provides its own module account to hold community funds and sends the community-tax funds to the `Yield Intermediate Pool` account.  |
| `Yield Intermediate Pool` account | Module account that buffers continuous funding before TD consumption. |
| `td` module | Module managing the user trust deposits |
| `trust_deposit` account | Account holding the trust deposit on behalf of the account. |




## Parameters (`x/td`)

Existing TD module parameters:

| Param | Type | Description |
| --- | --- | --- |
| `trust_deposit_reclaim_burn_rate` | fix point number | Percentage of the deposit burnt when an account executes a reclaim of capital amount. (mandatory) |
| `trust_deposit_share_value` | fix point number | Value of one share of trust deposit, in denom. Default an initial value: 1. Increase over time, when yield is produced. (mandatory) |
| `trust_deposit_rate` | fix point number | Rate used to dynamically calculate trust deposits from trust fees. Default: 0.20 (20%). (mandatory) |
| `wallet_user_agent_reward_rate` | fix point number | Rate used to dynamically calculate wallet user-agent rewards from trust fees. Default: 0.20 (20%). (mandatory) |
| `user_agent_reward_rate` | fix point number | Rate used to dynamically calculate user-agent rewards from trust fees. Default: 0.20 (20%). (mandatory) |


Extend the TD module parameters to include:

| Param | Type | Description |
| --- | --- | --- |
| `trust_deposit_max_yield_rate` | fix point number  | Maximum annualized yield rate (e.g. 0.15 for 15%). |
| `blocks_per_year` | number | Chain-specific estimate used when converting annual rate into per-block allowances. |
| `yield_intermediat_pool` | `string` | Bech32 string for the Yield Intermediate Pool module account (default: module addr derived from name). |




## Messages & Governance

1. **`MsgFundModule`** : allows manual funding of module accounts. Require the caller to match the module authority (defaults to the governance module account) so only authorized operations can seed TD funds. 
3. **`MsgCreateContinuousFund`** (protocol pool module, existing): Governance proposal instructing `x/protocolpool` to remit a percentage of community tax each block to the Yield Intermediate Pool account.

## Begin Block Flow (`x/td`)

Executed each block after distribution and protocol pool modules:

1. **Begin Block Flow (`x/protocolpool`)**:
   - Begin Block Flow (`x/protocolpool`) is executed ahead of Begin Block Flow (`x/td`)
   - `yield_intermediat_pool` therefore contains the portion of the block reward distributed by the `x/protocolpool` module. The Begin Block Flow allows for the flow of tokens between modules to transact atomically as part of the same block. 
2. **Compute Yield Allowance**:
   ```javascript
   `allowance` := dust + `trust_deposit` * `trust_deposit_max_yield_rate`/ `blocks_per_year`
   ```
2. **Determine Transfer**:
   - `transfer_amount` = min(`allowance`,`yield_intermediat_pool`).TruncateInt()
5. **Transfer Yield to Trust Deposit**:
   - transfer `transfer_amount` from `yield_intermediat_pool` to `trust_deposit`
6. **Adjust Trust Deposit Share Value**:
   - update the `trust_deposit_share_value`  
   - e.g. `trust_deposit_share_value` = `trust_deposit` / `total_number_of_shares_issued`  
7. **Update Dust**:
   - `dust` = min(`allowance`,`yield_intermediat_pool`).remainder()
8. **Return Rest of YIP Account to Community Pool**:
   - send residual `yield_intermediat_pool` account's amount back to community/protocol pool (`x/protocolpool`) account to keep the buffer empty.


## Trust Deposit Integration

The existing TD module already maintains a mapping of accounts to shares:

- **Expectations**: yield injections should increase the pool value without changing individual share counts. That's why the `GlobalVariables.trust_deposit_share_value` is updated to 
- **Interface expectations**: No new methods are required for this feature.

## Admin Flow

1. **Governance Funding Setup**
   - Submit `MsgCreateContinuousFund` targeting the Yield Intermediate Pool account with the desired percentage (e.g. 0.05% of community tax).
   - Include metadata documenting the TD module’s use of funds and the expected burnDown.
2. **Parameter Initialization**
   - Governance issues `MsgUpdateParams` (or `param-change` proposal) to set:
     - `trust_deposit_max_yield_rate`
     - `blocks_per_year`
     - (Optionally) `yield_intermediate_pool_address`
4. **Monitoring**
   - Dashboard/CLI queries reference new endpoints:
     - `QueryParams` — verify configuration.
     - `QueryDust` (optional addition) — track accumulated dust above micro precision.
     - Bank queries on the Yield Intermediate Pool account should remain near zero outside short-lived per-block spikes.

## Payment Flow Summary

```
Community Tax → Protocol Pool → (governance) Continuous Fund → Yield Intermediate Pool →
BeginBlock (x/td):
  compute allowance
  pull min(allowance, balance)
  transfer `transfer_amount` from `yield_intermediat_pool` to `trust_deposit`
  adjust dust + sweep excess back to `x/protocolpool` account 
  Adjust Trust Deposit Share Value
Result: TD share value increases; per-holder positions grow automatically.
```

By crediting the TD `trust_deposit` account and by adjusting `trust_deposit_share_value`, individual holders accrue yield proportionally without new messages or manual claims.



```plantuml
@startuml
title Trust Deposit Yield Flow (Conceptual)

skinparam backgroundColor #ffffff
skinparam activity {
  BackgroundColor<<calc>> #FFEFD5
  BorderColor #999999
  ArrowColor #B44
}
skinparam note {
  BackgroundColor #FFFFCC
  BorderColor #999999
}

start

floating note left
Parameters:
- trust_deposit_share_value: 1.0
- blocks_per_year: 6311620
- max_td_yield_rate: 15%
- trust_deposit_value: 0 (initial)
end note

floating note right
Example:
- 100,000 uvna Trust Deposit
- 1 uvna per share
- Excess funds collected
Solved:
- No missed rewards
- Controlled distribution
- Dust handling
end note

partition "Network Rewards Flow" {
  :Block rewards;
  :Community tax = 2%;
  fork
    :98% goes to validator;
  fork again
    :2% to community pool;
    :Community Pool / Protocol Pool Module;
    :Send to Yield Intermediate Pool Account;
  end fork
}

partition "Yield Intermediate Pool Account" {
  :Buffer incoming funds;
}

partition "Trust Deposit Module" {
  :Amount calculation;
  :Compute max_per_block = (trust_deposit_value * max_td_yield_rate) / blocks_per_year;
  :Compute amount_to_send = min(max_per_block, YIPA_balance);

  if (amount_to_send >= 1 micro unit?) then (yes)
    :Transfer amount_to_send from YIPA -> TD module;
  else (no)
    :Store in dust_amount (below precision);
    :Accumulate dust;
    if (dust_amount >= 1 micro unit?) then (yes)
      :Transfer dust_amount from YIPA -> TD module;
      :Reset dust_amount to 0;
    else (no)
      :Wait for next block;
    endif
  endif

  :Distribute yields;
  :Trust Deposit Holders;
}

note left
- Governance config sets percentage routed from Community Pool to YIPA.
- Residuals may be swept back to the community pool after transfers.
end note

stop
@enduml
```