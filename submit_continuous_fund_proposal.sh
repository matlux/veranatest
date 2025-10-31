#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CHAIN_ID="vna-testnet-1"
KEYRING_BACKEND="test"
BINARY="veranatestd"
NODE="http://localhost:26657"
FEES="500000uvna"
DRAFT_PROPOSAL="draft_proposal.json"
PROPOSER_KEY="cooluser"  # Default proposer key name

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Step 1: Check prerequisites
log "Step 1: Checking prerequisites..."
log "--------------------------------"

if [ ! -f "$DRAFT_PROPOSAL" ]; then
    error "Draft proposal file not found: $DRAFT_PROPOSAL"
fi

if ! command -v jq &> /dev/null; then
    error "jq is required but not installed. Please install jq."
fi

if ! command -v $BINARY &> /dev/null; then
    error "$BINARY not found. Please ensure the binary is in your PATH."
fi

log "✅ Prerequisites check passed"

# Step 2: Validate draft proposal structure
log ""
log "Step 2: Validating draft proposal..."
log "------------------------------------"

# Check required fields
if ! jq -e '.messages' "$DRAFT_PROPOSAL" > /dev/null 2>&1; then
    error "Draft proposal missing 'messages' field"
fi

if ! jq -e '.title' "$DRAFT_PROPOSAL" > /dev/null 2>&1; then
    error "Draft proposal missing 'title' field"
fi

if ! jq -e '.summary' "$DRAFT_PROPOSAL" > /dev/null 2>&1; then
    error "Draft proposal missing 'summary' field"
fi

if ! jq -e '.deposit' "$DRAFT_PROPOSAL" > /dev/null 2>&1; then
    error "Draft proposal missing 'deposit' field"
fi

DEPOSIT=$(jq -r '.deposit' "$DRAFT_PROPOSAL")
TITLE=$(jq -r '.title' "$DRAFT_PROPOSAL")
SUMMARY=$(jq -r '.summary' "$DRAFT_PROPOSAL")
METADATA=$(jq -r '.metadata // "ipfs://CID"' "$DRAFT_PROPOSAL")
EXPEDITED=$(jq -r '.expedited // false' "$DRAFT_PROPOSAL")

log "✅ Draft proposal validated"
info "   Title: $TITLE"
info "   Deposit: $DEPOSIT"
info "   Expedited: $EXPEDITED"
info "   Messages: $(jq '.messages | length' "$DRAFT_PROPOSAL") message(s)"

# Step 3: Check proposer account
log ""
log "Step 3: Checking proposer account..."
log "------------------------------------"

if ! $BINARY keys show "$PROPOSER_KEY" --keyring-backend $KEYRING_BACKEND > /dev/null 2>&1; then
    warn "Proposer key '$PROPOSER_KEY' not found. Using first available key..."
    PROPOSER_KEY=$($BINARY keys list --keyring-backend $KEYRING_BACKEND -o json | jq -r '.[0].name // "cooluser"')
    if [ -z "$PROPOSER_KEY" ] || [ "$PROPOSER_KEY" == "null" ]; then
        error "No keys found in keyring. Please create a key first."
    fi
fi

PROPOSER_ADDR=$($BINARY keys show "$PROPOSER_KEY" -a --keyring-backend $KEYRING_BACKEND)
log "✅ Proposer: $PROPOSER_KEY ($PROPOSER_ADDR)"

# Check proposer balance
PROPOSER_BALANCE=$($BINARY query bank balances "$PROPOSER_ADDR" --node $NODE -o json 2>/dev/null | \
    jq -r ".balances[] | select(.denom == \"uvna\") | .amount // \"0\"" || echo "0")

DEPOSIT_AMOUNT=$(echo "$DEPOSIT" | sed 's/uvna//')
# Simple numeric comparison (works for integers)
if [ -z "$PROPOSER_BALANCE" ] || [ "$PROPOSER_BALANCE" == "0" ] || [ "$PROPOSER_BALANCE" == "null" ]; then
    warn "Proposer balance not found or zero. Make sure the proposer has funds for deposit ($DEPOSIT) + fees ($FEES)"
elif [ "$PROPOSER_BALANCE" -lt "$DEPOSIT_AMOUNT" ] 2>/dev/null; then
    warn "Proposer balance ($PROPOSER_BALANCE uvna) may be insufficient for deposit ($DEPOSIT)"
    warn "Make sure the proposer has enough funds for deposit + fees"
else
    log "✅ Proposer has balance: $PROPOSER_BALANCE uvna"
fi

# Step 4: Fund module accounts
log ""
log "Step 4: Funding module accounts..."
log "----------------------------------"

FUND_AMOUNT="10000000000"

# Function to fund a module account
fund_module() {
    local MODULE_NAME=$1
    log "Funding $MODULE_NAME with $FUND_AMOUNT uvna..."
    
    FUND_RESULT=$($BINARY tx td fund-module $FUND_AMOUNT $MODULE_NAME \
        --from "$PROPOSER_KEY" \
        --keyring-backend $KEYRING_BACKEND \
        --chain-id $CHAIN_ID \
        --fees $FEES \
        --node $NODE \
        --yes \
        --output json 2>&1)
    
    if echo "$FUND_RESULT" | grep -q '"code":0'; then
        log "✅ Successfully funded $MODULE_NAME with $FUND_AMOUNT uvna"
        
        # Wait for transaction to be included in a block
        info "Waiting for funding transaction to be included in a block..."
        sleep 5
        
        # Verify the funding by checking module account balance (optional)
        MODULE_ADDR=$($BINARY query auth module-accounts --node $NODE -o json 2>/dev/null | \
            jq -r ".accounts[] | select(.name == \"$MODULE_NAME\") | .address" | head -1)
        
        if [ -n "$MODULE_ADDR" ] && [ "$MODULE_ADDR" != "null" ]; then
            MODULE_BALANCE=$($BINARY query bank balances "$MODULE_ADDR" --node $NODE -o json 2>/dev/null | \
                jq -r ".balances[] | select(.denom == \"uvna\") | .amount // \"0\"" || echo "0")
            if [ -n "$MODULE_BALANCE" ] && [ "$MODULE_BALANCE" != "0" ]; then
                log "✅ Verified: $MODULE_NAME account balance is $MODULE_BALANCE uvna"
            fi
        fi
        return 0
    else
        warn "Failed to fund $MODULE_NAME. Error: $(echo "$FUND_RESULT" | jq -r '.raw_log // .' | head -1)"
        return 1
    fi
}

# Fund verana_pool module
fund_module "verana_pool"

# Fund td module
fund_module "td"

log "✅ Module funding steps completed"

# Step 5: Submit governance proposal
log ""
log "Step 5: Submitting governance proposal..."
log "----------------------------------------"

# Submit the proposal using the draft proposal file
SUBMIT_RESULT=$($BINARY tx gov submit-proposal "$DRAFT_PROPOSAL" \
    --from "$PROPOSER_KEY" \
    --keyring-backend $KEYRING_BACKEND \
    --chain-id $CHAIN_ID \
    --fees $FEES \
    --node $NODE \
    --yes \
    --output json 2>&1)

if echo "$SUBMIT_RESULT" | grep -q '"code":0'; then
    log "✅ Proposal submitted successfully"
    
    # Extract transaction hash
    TX_HASH=$(echo "$SUBMIT_RESULT" | jq -r '.txhash')
    log "   Transaction Hash: $TX_HASH"
    
    # Wait for transaction to be included in a block
    info "Waiting for transaction to be included in a block..."
    sleep 5
    
    # Query the transaction to get proposal ID
    TX_RESULT=$($BINARY query tx $TX_HASH --node $NODE --output json 2>/dev/null || echo "")
    
    if [ -n "$TX_RESULT" ]; then
        # Extract proposal ID from submit_proposal event
        PROPOSAL_ID=$(echo "$TX_RESULT" | jq -r '.events[] | select(.type == "submit_proposal") | .attributes[] | select(.key == "proposal_id") | .value' | head -1)
        
        if [ -z "$PROPOSAL_ID" ] || [ "$PROPOSAL_ID" == "null" ]; then
            # Alternative: try different event type
            PROPOSAL_ID=$(echo "$TX_RESULT" | jq -r '.events[] | select(.type == "message") | .attributes[] | select(.key == "proposal_id") | .value' | head -1)
        fi
        
        if [ -z "$PROPOSAL_ID" ] || [ "$PROPOSAL_ID" == "null" ]; then
            # Fallback: query all proposals and get the latest
            info "Extracting proposal ID from governance queries..."
            sleep 3
            PROPOSAL_ID=$($BINARY query gov proposals --node $NODE --output json 2>/dev/null | \
                jq -r '[.proposals[] | select(.status == "PROPOSAL_STATUS_DEPOSIT_PERIOD" or .status == "PROPOSAL_STATUS_VOTING_PERIOD")] | sort_by(.id) | last | .id // empty')
        fi
    else
        # Fallback: query all proposals
        warn "Could not query transaction. Trying alternative method..."
        sleep 5
        PROPOSAL_ID=$($BINARY query gov proposals --node $NODE --output json 2>/dev/null | \
            jq -r '[.proposals[] | select(.status == "PROPOSAL_STATUS_DEPOSIT_PERIOD" or .status == "PROPOSAL_STATUS_VOTING_PERIOD")] | sort_by(.id) | last | .id // empty')
    fi
    
    if [ -z "$PROPOSAL_ID" ] || [ "$PROPOSAL_ID" == "null" ]; then
        warn "Could not automatically extract proposal ID. Please query manually:"
        warn "$BINARY query gov proposals --node $NODE"
        exit 1
    fi
    
    log "✅ Proposal ID: $PROPOSAL_ID"
else
    error "Failed to submit proposal. Error: $SUBMIT_RESULT"
fi

# Step 6: Vote on proposal
log ""
log "Step 6: Voting on proposal..."
log "----------------------------"

# Check if we need to wait for deposit period to end
PROPOSAL_STATUS=$($BINARY query gov proposal $PROPOSAL_ID --node $NODE --output json 2>/dev/null | \
    jq -r '.proposal.status // "UNKNOWN"' || echo "UNKNOWN")

if [ "$PROPOSAL_STATUS" == "PROPOSAL_STATUS_DEPOSIT_PERIOD" ]; then
    warn "Proposal is still in deposit period. Cannot vote yet."
    warn "You may need to deposit more funds or wait for the deposit period to end."
    info "Current status: $PROPOSAL_STATUS"
    info "You can check proposal status with: $BINARY query gov proposal $PROPOSAL_ID --node $NODE"
    exit 0
fi

if [ "$PROPOSAL_STATUS" != "PROPOSAL_STATUS_VOTING_PERIOD" ]; then
    warn "Proposal is not in voting period. Status: $PROPOSAL_STATUS"
    info "Proposal may have already been voted on or executed."
    exit 0
fi

log "Proposal is in voting period. Voting YES..."

# Vote on the proposal
VOTE_RESULT=$($BINARY tx gov vote $PROPOSAL_ID yes \
    --from "$PROPOSER_KEY" \
    --keyring-backend $KEYRING_BACKEND \
    --chain-id $CHAIN_ID \
    --fees $FEES \
    --node $NODE \
    --yes \
    --output json 2>&1)

if echo "$VOTE_RESULT" | grep -q '"code":0'; then
    log "✅ Voted YES on proposal $PROPOSAL_ID"
    sleep 3
else
    warn "Failed to vote on proposal. Error: $(echo "$VOTE_RESULT" | jq -r '.raw_log // .' | head -1)"
    warn "You can manually vote with:"
    warn "$BINARY tx gov vote $PROPOSAL_ID yes --from $PROPOSER_KEY --keyring-backend $KEYRING_BACKEND --chain-id $CHAIN_ID --fees $FEES -y"
fi

# Step 7: Query proposal status
log ""
log "Step 7: Querying proposal status..."
log "-----------------------------------"

sleep 3

PROPOSAL_INFO=$($BINARY query gov proposal $PROPOSAL_ID --node $NODE --output json 2>/dev/null || echo "")

if [ -n "$PROPOSAL_INFO" ]; then
    STATUS=$(echo "$PROPOSAL_INFO" | jq -r '.proposal.status // "UNKNOWN"')
    FINAL_TALLY=$(echo "$PROPOSAL_INFO" | jq -r '.proposal.final_tally_result // {}')
    VOTING_END_TIME=$(echo "$PROPOSAL_INFO" | jq -r '.proposal.voting_end_time // "N/A"')
    
    log "✅ Proposal Status:"
    info "   ID: $PROPOSAL_ID"
    info "   Title: $TITLE"
    info "   Status: $STATUS"
    info "   Voting End Time: $VOTING_END_TIME"
    
    if [ "$STATUS" == "PROPOSAL_STATUS_PASSED" ]; then
        log ""
        log "🎉 Proposal has PASSED!"
        info "The proposal will be automatically executed after the voting period ends."
    elif [ "$STATUS" == "PROPOSAL_STATUS_VOTING_PERIOD" ]; then
        log ""
        info "Proposal is in voting period. More votes can be cast."
        if [ -n "$FINAL_TALLY" ] && [ "$FINAL_TALLY" != "{}" ]; then
            info "Current tally:"
            echo "$FINAL_TALLY" | jq '.'
        fi
    fi
else
    warn "Could not query proposal status. You can manually check with:"
    warn "$BINARY query gov proposal $PROPOSAL_ID --node $NODE"
fi

# Final summary
log ""
log "📋 Summary"
log "=========="
log "   Proposal ID: $PROPOSAL_ID"
log "   Proposer: $PROPOSER_KEY ($PROPOSER_ADDR)"
log "   Title: $TITLE"
log "   Deposit: $DEPOSIT"
log ""
log "🔍 To check proposal status:"
log "   $BINARY query gov proposal $PROPOSAL_ID --node $NODE"
log ""
log "🗳️  To vote on this proposal (if you have voting power):"
log "   $BINARY tx gov vote $PROPOSAL_ID yes --from <your-key> --keyring-backend $KEYRING_BACKEND --chain-id $CHAIN_ID --fees $FEES -y"
log ""
log "⏰ The proposal will be automatically executed if it passes after the voting period ends."
log ""
log "✅ Done!"
