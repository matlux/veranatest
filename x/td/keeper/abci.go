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
	if err := k.SendFundsFromVeranaPool(ctx); err != nil {
		return err
	}

	// Send excess funds back to community pool
	if err := k.SendFundsBackToCommunityPool(ctx); err != nil {
		return err
	}

	return nil
}

// SendFundsFromVeranaPool calculates yield amount and transfers to trust deposit module
func (k Keeper) SendFundsFromVeranaPool(ctx sdk.Context) error {
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
	totalAmount := currentDust.Add(perBlockYield)

	// Convert to integer amount (1 micro unit = 1)
	// Since we're dealing with uvna (micro units), 1 micro unit = 1
	microUnitThreshold := math.LegacyNewDec(1)

	if totalAmount.GTE(microUnitThreshold) {
		// Get module addresses
		veranaPool := "cosmos1jjfey42zhnwrpv8pmpxgp2jwukcy3emfsewffz"
		veranaPoolAddr, _ := sdk.AccAddressFromBech32(veranaPool)

		// Convert to integer amount for transfer
		transferAmount := totalAmount.TruncateInt()

		// Create coins to transfer
		transferCoins := sdk.NewCoins(sdk.NewCoin("uvna", transferAmount))

		// Check if verana pool has sufficient balance
		veranaPoolBalance := k.bankKeeper.GetAllBalances(ctx, veranaPoolAddr)
		if !veranaPoolBalance.IsAllGTE(transferCoins) {
			// Not enough funds in verana pool, skip transfer
			return nil
		}

		// Transfer from verana pool to trust deposit module
		if err := k.bankKeeper.SendCoinsFromModuleToModule(ctx, types.VeranaPoolAccount, types.ModuleName, transferCoins); err != nil {
			return err
		}

		// Calculate remaining dust after transfer
		transferredAmount := math.LegacyNewDecFromInt(transferAmount)
		remainingDust := totalAmount.Sub(transferredAmount)

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
		if err := k.SetDustAmount(ctx, totalAmount); err != nil {
			return err
		}

		ctx.Logger().Debug("Accumulated dust amount below threshold",
			"total_dust", totalAmount.String())
	}

	return nil
}

// SendFundsBackToCommunityPool sends excess funds from verana pool back to community pool
func (k Keeper) SendFundsBackToCommunityPool(ctx sdk.Context) error {
	// Get verana pool module address
	veranaPool := "cosmos1jjfey42zhnwrpv8pmpxgp2jwukcy3emfsewffz"
	veranaPoolAddr, _ := sdk.AccAddressFromBech32(veranaPool)

	// Get current balance in verana pool
	veranaPoolBalance := k.bankKeeper.GetAllBalances(ctx, veranaPoolAddr)

	// If there are no funds, nothing to send back
	if veranaPoolBalance.IsZero() {
		return nil
	}

	// Send all remaining funds back to protocol pool
	if err := k.bankKeeper.SendCoinsFromModuleToModule(ctx, types.VeranaPoolAccount, protocolpooltypes.ModuleName, veranaPoolBalance); err != nil {
		return err
	}

	// Log the transfer
	ctx.Logger().Info("Sent excess funds back to community pool",
		"amount", veranaPoolBalance.String())

	return nil
}
