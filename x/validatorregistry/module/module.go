package validatorregistry

import (
	"context"
	"encoding/json"
	"fmt"

	"cosmossdk.io/core/appmodule"
	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/cosmos/cosmos-sdk/x/group"
	"github.com/grpc-ecosystem/grpc-gateway/runtime"
	"google.golang.org/grpc"

	"veranatest/x/validatorregistry/keeper"
	"veranatest/x/validatorregistry/types"
)

var (
	_ module.AppModuleBasic = (*AppModule)(nil)
	_ module.AppModule      = (*AppModule)(nil)
	_ module.HasGenesis     = (*AppModule)(nil)

	_ appmodule.AppModule       = (*AppModule)(nil)
	_ appmodule.HasBeginBlocker = (*AppModule)(nil)
	_ appmodule.HasEndBlocker   = (*AppModule)(nil)
)

// AppModule implements the AppModule interface that defines the inter-dependent methods that modules need to implement
type AppModule struct {
	cdc         codec.Codec
	keeper      keeper.Keeper
	authKeeper  types.AuthKeeper
	bankKeeper  types.BankKeeper
	groupKeeper types.GroupKeeper // Add group keeper for auto-execution
}

func NewAppModule(
	cdc codec.Codec,
	keeper keeper.Keeper,
	authKeeper types.AuthKeeper,
	bankKeeper types.BankKeeper,
	groupKeeper types.GroupKeeper,
) AppModule {
	return AppModule{
		cdc:         cdc,
		keeper:      keeper,
		authKeeper:  authKeeper,
		bankKeeper:  bankKeeper,
		groupKeeper: groupKeeper,
	}
}

// IsAppModule implements the appmodule.AppModule interface.
func (AppModule) IsAppModule() {}

// Name returns the name of the module as a string.
func (AppModule) Name() string {
	return types.ModuleName
}

// RegisterLegacyAminoCodec registers the amino codec
func (AppModule) RegisterLegacyAminoCodec(*codec.LegacyAmino) {}

// RegisterGRPCGatewayRoutes registers the gRPC Gateway routes for the module.
func (AppModule) RegisterGRPCGatewayRoutes(clientCtx client.Context, mux *runtime.ServeMux) {
	if err := types.RegisterQueryHandlerClient(clientCtx.CmdContext, mux, types.NewQueryClient(clientCtx)); err != nil {
		panic(err)
	}
}

// RegisterInterfaces registers a module's interface types and their concrete implementations as proto.Message.
func (AppModule) RegisterInterfaces(registrar codectypes.InterfaceRegistry) {
	types.RegisterInterfaces(registrar)
}

// RegisterServices registers a gRPC query service to respond to the module-specific gRPC queries
func (am AppModule) RegisterServices(registrar grpc.ServiceRegistrar) error {
	types.RegisterMsgServer(registrar, keeper.NewMsgServerImpl(am.keeper))
	types.RegisterQueryServer(registrar, keeper.NewQueryServerImpl(am.keeper))

	return nil
}

// DefaultGenesis returns a default GenesisState for the module, marshalled to json.RawMessage.
// The default GenesisState need to be defined by the module developer and is primarily used for testing.
func (am AppModule) DefaultGenesis(codec.JSONCodec) json.RawMessage {
	return am.cdc.MustMarshalJSON(types.DefaultGenesis())
}

// ValidateGenesis used to validate the GenesisState, given in its json.RawMessage form.
func (am AppModule) ValidateGenesis(_ codec.JSONCodec, _ client.TxEncodingConfig, bz json.RawMessage) error {
	var genState types.GenesisState
	if err := am.cdc.UnmarshalJSON(bz, &genState); err != nil {
		return fmt.Errorf("failed to unmarshal %s genesis state: %w", types.ModuleName, err)
	}

	return genState.Validate()
}

// InitGenesis performs the module's genesis initialization. It returns no validator updates.
func (am AppModule) InitGenesis(ctx sdk.Context, _ codec.JSONCodec, gs json.RawMessage) {
	var genState types.GenesisState
	// Initialize global index to index in genesis state
	if err := am.cdc.UnmarshalJSON(gs, &genState); err != nil {
		panic(fmt.Errorf("failed to unmarshal %s genesis state: %w", types.ModuleName, err))
	}

	if err := am.keeper.InitGenesis(ctx, genState); err != nil {
		panic(fmt.Errorf("failed to initialize %s genesis state: %w", types.ModuleName, err))
	}
}

// ExportGenesis returns the module's exported genesis state as raw JSON bytes.
func (am AppModule) ExportGenesis(ctx sdk.Context, _ codec.JSONCodec) json.RawMessage {
	genState, err := am.keeper.ExportGenesis(ctx)
	if err != nil {
		panic(fmt.Errorf("failed to export %s genesis state: %w", types.ModuleName, err))
	}

	bz, err := am.cdc.MarshalJSON(genState)
	if err != nil {
		panic(fmt.Errorf("failed to marshal %s genesis state: %w", types.ModuleName, err))
	}

	return bz
}

// ConsensusVersion is a sequence number for state-breaking change of the module.
// It should be incremented on each consensus-breaking change introduced by the module.
// To avoid wrong/empty versions, the initial version should be set to 1.
func (AppModule) ConsensusVersion() uint64 { return 1 }

// BeginBlock contains the logic that is automatically triggered at the beginning of each block.
// The begin block implementation is optional.
func (am AppModule) BeginBlock(_ context.Context) error {
	return nil
}

// EndBlock contains the logic that is automatically triggered at the end of each block.
// It automatically executes group proposals after their voting period ends.
func (am AppModule) EndBlock(ctx context.Context) error {
	sdkCtx := sdk.UnwrapSDKContext(ctx)

	// Execute pending group proposals
	if err := am.executePendingGroupProposals(sdkCtx); err != nil {
		// Log error but don't panic - continue block processing
		sdkCtx.Logger().Error("failed to execute pending group proposals", "error", err)
		return nil
	}

	return nil
}

// executePendingGroupProposals checks for group proposals that have ended their voting period
// and automatically executes them if they meet the decision policy requirements.
func (am AppModule) executePendingGroupProposals(ctx sdk.Context) error {
	currentTime := ctx.BlockTime()
	ctx.Logger().Debug("checking for pending group proposal executions", "current_time", currentTime)

	// Get all groups
	groupsResp, err := am.groupKeeper.Groups(ctx, &group.QueryGroupsRequest{})
	if err != nil {
		ctx.Logger().Error("failed to query groups", "error", err)
		return fmt.Errorf("failed to query groups: %w", err)
	}

	// Iterate through all groups
	for _, groupInfo := range groupsResp.Groups {
		// Get group policies for this group
		policiesResp, err := am.groupKeeper.GroupPoliciesByGroup(ctx, &group.QueryGroupPoliciesByGroupRequest{
			GroupId: groupInfo.Id,
		})
		if err != nil {
			ctx.Logger().Error("failed to query group policies", "group_id", groupInfo.Id, "error", err)
			continue
		}

		// Iterate through all policies
		for _, policy := range policiesResp.GroupPolicies {
			// Get proposals for this policy
			proposalsResp, err := am.groupKeeper.ProposalsByGroupPolicy(ctx, &group.QueryProposalsByGroupPolicyRequest{
				Address: policy.Address,
			})
			if err != nil {
				ctx.Logger().Error("failed to query proposals", "policy", policy.Address, "error", err)
				continue
			}

			// Check each proposal
			for _, proposal := range proposalsResp.Proposals {
				// Skip if voting period hasn't ended
				if currentTime.Before(proposal.VotingPeriodEnd) {
					continue
				}

				// Skip if already executed
				if proposal.ExecutorResult == group.PROPOSAL_EXECUTOR_RESULT_SUCCESS {
					continue
				}

				// Skip if already failed
				if proposal.ExecutorResult == group.PROPOSAL_EXECUTOR_RESULT_FAILURE {
					continue
				}

				// Execute the proposal if it's accepted
				if proposal.Status == group.PROPOSAL_STATUS_ACCEPTED {
					ctx.Logger().Info("executing accepted group proposal",
						"proposal_id", proposal.Id,
						"group_policy", policy.Address,
						"voting_period_end", proposal.VotingPeriodEnd,
						"current_time", currentTime)

					// Use TryExecute to execute the proposal
					err := am.tryExecuteProposal(ctx, proposal.Id)
					if err != nil {
						ctx.Logger().Error("failed to execute proposal",
							"proposal_id", proposal.Id,
							"error", err)
						// Continue with other proposals even if one fails
					}
				}
			}
		}
	}

	return nil
}

// tryExecuteProposal attempts to execute a group proposal
// Note: Full execution requires message routing which is complex to implement in EndBlocker
// For now, we log that the proposal is ready for execution
func (am AppModule) tryExecuteProposal(ctx sdk.Context, proposalID uint64) error {
	// Get the proposal to check its status
	proposalResp, err := am.groupKeeper.Proposal(ctx, &group.QueryProposalRequest{
		ProposalId: proposalID,
	})
	if err != nil {
		return fmt.Errorf("failed to get proposal %d: %w", proposalID, err)
	}

	proposal := proposalResp.Proposal

	// Verify proposal is in ACCEPTED status
	if proposal.Status != group.PROPOSAL_STATUS_ACCEPTED {
		return fmt.Errorf("proposal %d is not in ACCEPTED status: %s", proposalID, proposal.Status)
	}

	// Check voting period has ended
	currentTime := ctx.BlockTime()
	if currentTime.Before(proposal.VotingPeriodEnd) {
		return fmt.Errorf("proposal %d voting period hasn't ended yet", proposalID)
	}

	// Log that the proposal is ready for execution
	ctx.Logger().Info("group proposal ready for automatic execution",
		"proposal_id", proposalID,
		"group_policy", proposal.GroupPolicyAddress,
		"status", proposal.Status,
		"voting_period_end", proposal.VotingPeriodEnd,
		"current_time", currentTime,
		"messages_count", len(proposal.Messages))

	// Execute the proposal by calling the group keeper's Exec method
	msgExec := &group.MsgExec{
		ProposalId: proposalID,
		Executor:   proposal.GroupPolicyAddress,
	}

	// Call the group keeper's Exec method to execute the proposal
	_, err = am.groupKeeper.Exec(ctx, msgExec)
	if err != nil {
		ctx.Logger().Error("failed to execute proposal",
			"proposal_id", proposalID,
			"error", err)
		return fmt.Errorf("failed to execute proposal %d: %w", proposalID, err)
	}

	ctx.Logger().Info("successfully executed group proposal",
		"proposal_id", proposalID,
		"group_policy", proposal.GroupPolicyAddress)

	return nil
}
