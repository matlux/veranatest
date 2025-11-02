package keeper

import (
	"cosmossdk.io/math"
	sdk "github.com/cosmos/cosmos-sdk/types"
	protocolpooltypes "github.com/cosmos/cosmos-sdk/x/protocolpool/types"

	"veranatest/x/td/types"
)

// BeginBlocker handles the fund flow logic every block
func (k Keeper) BeginBlocker(ctx sdk.Context) error {
	// Send calculated yield funds from verana pool to trust deposit module
	if err := k.CalculateAndSendAmountFromYieldIntermediatePool(ctx); err != nil {
		return err
	}

	// Send excess funds back to community pool
	if err := k.SendFundsBackToCommunityPool(ctx); err != nil {
		return err
	}

	return nil
}

// CalculateAndSendAmountFromYieldIntermediatePool calculates yield amount and transfers to trust deposit module
func (k Keeper) CalculateAndSendAmountFromYieldIntermediatePool(ctx sdk.Context) error {
	// Get current params
	params, err := k.Params.Get(ctx)
	if err != nil {
		return err
	}

	// Get blocks per year from mint module (6,311,520 based on your network config)
	blocksPerYear := math.NewInt(6311520)

	// Calculate per-block yield amount
	// Formula: (trust_deposit_value * trust_deposit_yield_rate) / blocks_per_year
	trustDepositValue := math.LegacyNewDecFromInt(math.NewInt(int64(params.TrustDepositValue)))
	yieldRate := params.TrustDepositYieldRate

	// Annual yield amount
	annualYield := trustDepositValue.Mul(yieldRate)

	// Per block yield amount (as LegacyDec to handle decimals)
	perBlockYield := annualYield.Quo(math.LegacyNewDecFromInt(blocksPerYear))

	// Get current accumulated dust
	currentDust, err := k.GetDustAmount(ctx)
	if err != nil {
		return err
	}

	// Add current per-block yield to accumulated dust
	maxPerBlockYieldAmountAllowable := currentDust.Add(perBlockYield)

	// Convert to integer amount (1 micro unit = 1)
	// Since we're dealing with uvna (micro units), 1 micro unit = 1
	microUnitThreshold := math.LegacyNewDec(1)

	if maxPerBlockYieldAmountAllowable.GTE(microUnitThreshold) {
		// Get module addresses
		yieldIntermediatePool := "cosmos1jjfey42zhnwrpv8pmpxgp2jwukcy3emfsewffz"
		yieldIntermediatePoolAddr, _ := sdk.AccAddressFromBech32(yieldIntermediatePool)

		// Convert to integer amount for transfer
		transferAmount := maxPerBlockYieldAmountAllowable.TruncateInt()

		// Create coins to transfer
		transferCoins := sdk.NewCoins(sdk.NewCoin("uvna", transferAmount))

		// Check if verana pool has sufficient balance
		yieldIntermediatePoolBalance := k.bankKeeper.GetAllBalances(ctx, yieldIntermediatePoolAddr)
		if !yieldIntermediatePoolBalance.IsAllGTE(transferCoins) {
			// Not enough funds in verana pool, skip transfer
			return nil
		}

		// Transfer from verana pool to trust deposit module
		if err := k.bankKeeper.SendCoinsFromModuleToModule(ctx, types.YieldIntermediatePoolAccount, types.ModuleName, transferCoins); err != nil {
			return err
		}

		// Calculate remaining dust after transfer
		transferredAmount := math.LegacyNewDecFromInt(transferAmount)
		remainingDust := maxPerBlockYieldAmountAllowable.Sub(transferredAmount)

		// Update dust amount
		if err := k.SetDustAmount(ctx, remainingDust); err != nil {
			return err
		}

		// Log successful transfer
		ctx.Logger().Info("Transferred yield to trust deposit module",
			"amount", transferCoins.String(),
			"remaining_dust", remainingDust.String())
	} else {
		// Amount below threshold, just accumulate dust
		if err := k.SetDustAmount(ctx, maxPerBlockYieldAmountAllowable); err != nil { // dust + min(maxPerBlockYieldAmountAllowable, amount in YieldIntermediatePoolAccount )
			return err
		}

		ctx.Logger().Debug("Accumulated dust amount below threshold",
			"total_dust", maxPerBlockYieldAmountAllowable.String())
	}

	return nil
}

// SendFundsBackToCommunityPool sends excess funds from verana pool back to community pool
func (k Keeper) SendFundsBackToCommunityPool(ctx sdk.Context) error {
	// Get verana pool module address
	yieldIntermediatePool := "cosmos1jjfey42zhnwrpv8pmpxgp2jwukcy3emfsewffz"
	yieldIntermediatePoolAddr, _ := sdk.AccAddressFromBech32(yieldIntermediatePool)

	// Get current balance in verana pool
	yieldIntermediatePoolBalance := k.bankKeeper.GetAllBalances(ctx, yieldIntermediatePoolAddr)

	// If there are no funds, nothing to send back
	if yieldIntermediatePoolBalance.IsZero() {
		return nil
	}

	// Send all remaining funds back to protocol pool
	if err := k.bankKeeper.SendCoinsFromModuleToModule(ctx, types.YieldIntermediatePoolAccount, protocolpooltypes.ModuleName, yieldIntermediatePoolBalance); err != nil {
		return err
	}

	// Log the transfer
	ctx.Logger().Info("Sent excess funds back to community pool",
		"amount", yieldIntermediatePoolBalance.String())

	return nil
}
