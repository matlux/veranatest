#!/bin/bash

# Council Governance Setup Script
# Creates a council-based governance system with 100-second voting period
# Based on COUNCIL_GOVERNANCE.md documentation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Configuration
CHAIN_ID="vna-testnet-1"
KEYRING_BACKEND="test"
FUNDING_AMOUNT="100000000uvna"
FEE_AMOUNT="500000uvna"
VOTING_PERIOD="100s"  # 100 seconds instead of 48 hours
THRESHOLD="2"  # 2/3 threshold

log "🏛️  Starting Council Governance Setup"
log "======================================"

# Check if chain is running
if ! veranatestd status > /dev/null 2>&1; then
    error "Chain is not running. Please start the chain first with: veranatestd start"
fi

log "✅ Chain is running"

# Step 1: Create Council Members
log ""
log "👥 Step 1: Creating Council Members"
log "----------------------------------"

# Check if keys already exist
if veranatestd keys list --keyring-backend test | grep -q "council-member-1"; then
    warn "Council member keys already exist. Skipping key creation."
else
    log "Creating council member accounts..."
    veranatestd keys add council-member-1 --keyring-backend test
    veranatestd keys add council-member-2 --keyring-backend test
    veranatestd keys add council-member-3 --keyring-backend test
fi

# Get member addresses
MEMBER_1=$(veranatestd keys show council-member-1 -a --keyring-backend test)
MEMBER_2=$(veranatestd keys show council-member-2 -a --keyring-backend test)
MEMBER_3=$(veranatestd keys show council-member-3 -a --keyring-backend test)

log "✅ Council members created:"
log "   Member 1: $MEMBER_1"
log "   Member 2: $MEMBER_2"
log "   Member 3: $MEMBER_3"

# Step 2: Fund Council Members
log ""
log "💰 Step 2: Funding Council Members"
log "----------------------------------"

# Check if cooluser exists
if ! veranatestd keys list --keyring-backend test | grep -q "cooluser"; then
    error "cooluser account not found. Please create and fund it first."
fi

log "Funding council members from cooluser account..."

# Fund member 1
log "Funding council-member-1..."
veranatestd tx bank send cooluser $MEMBER_1 $FUNDING_AMOUNT \
    --from cooluser \
    --chain-id $CHAIN_ID \
    --keyring-backend $KEYRING_BACKEND \
    --fees $FEE_AMOUNT \
    -y > /dev/null 2>&1

sleep 10  # Wait to avoid sequence mismatch

# Fund member 2
log "Funding council-member-2..."
veranatestd tx bank send cooluser $MEMBER_2 $FUNDING_AMOUNT \
    --from cooluser \
    --chain-id $CHAIN_ID \
    --keyring-backend $KEYRING_BACKEND \
    --fees $FEE_AMOUNT \
    -y > /dev/null 2>&1

sleep 10  # Wait to avoid sequence mismatch

# Fund member 3
log "Funding council-member-3..."
veranatestd tx bank send cooluser $MEMBER_3 $FUNDING_AMOUNT \
    --from cooluser \
    --chain-id $CHAIN_ID \
    --keyring-backend $KEYRING_BACKEND \
    --fees $FEE_AMOUNT \
    -y > /dev/null 2>&1

log "✅ All council members funded with $FUNDING_AMOUNT"

# Step 3: Create Group
log ""
log "🏛️  Step 3: Creating Council Group"
log "----------------------------------"

# Create members JSON file
log "Creating group members configuration..."
cat > members.json <<EOF
{
  "members": [
    {
      "address": "$MEMBER_1",
      "weight": "1",
      "metadata": "Council Member 1"
    },
    {
      "address": "$MEMBER_2",
      "weight": "1",
      "metadata": "Council Member 2"
    },
    {
      "address": "$MEMBER_3",
      "weight": "1",
      "metadata": "Council Member 3"
    }
  ]
}
EOF

# Check if group already exists
EXISTING_GROUPS=$(veranatestd query group groups --output json | jq '.groups | length')
if [ "$EXISTING_GROUPS" -gt 0 ]; then
    warn "Group already exists. Skipping group creation."
    GROUP_ID=1
else
    log "Creating council group..."
    veranatestd tx group create-group \
        $MEMBER_1 \
        "Verana Governing Council" \
        members.json \
        --from council-member-1 \
        --chain-id $CHAIN_ID \
        --keyring-backend $KEYRING_BACKEND \
        --fees $FEE_AMOUNT \
        -y > /dev/null 2>&1
    
    sleep 10  # Wait for group creation to be processed
    GROUP_ID=1
    log "✅ Council group created with ID: $GROUP_ID"
fi

# Step 4: Create Group Policy
log ""
log "⚖️  Step 4: Creating Group Policy (100s voting period)"
log "------------------------------------------------------"

# Create policy JSON file with 100-second voting period
log "Creating group policy with $VOTING_PERIOD voting period..."
cat > policy.json <<EOF
{
    "@type": "/cosmos.group.v1.ThresholdDecisionPolicy",
    "threshold": "$THRESHOLD",
    "windows": {
        "voting_period": "$VOTING_PERIOD",
        "min_execution_period": "0s"
    }
}
EOF

# Check if group policy already exists
EXISTING_POLICIES=$(veranatestd query group group-policies-by-group $GROUP_ID --output json | jq '.group_policies | length')
if [ "$EXISTING_POLICIES" -gt 0 ]; then
    warn "Group policy already exists. Skipping policy creation."
    GROUP_POLICY_ADDRESS=$(veranatestd query group group-policies-by-group $GROUP_ID --output json | jq -r '.group_policies[0].address')
else
    log "Creating group policy..."
    veranatestd tx group create-group-policy \
        $MEMBER_1 \
        $GROUP_ID \
        "Council Governor - 2/3 threshold for validator decisions" \
        policy.json \
        --from council-member-1 \
        --chain-id $CHAIN_ID \
        --keyring-backend $KEYRING_BACKEND \
        --fees $FEE_AMOUNT \
        -y > /dev/null 2>&1
    
    # Wait for transaction to be processed
    sleep 6
    
    # Get group policy address
    GROUP_POLICY_ADDRESS=$(veranatestd query group group-policies-by-group $GROUP_ID --output json | jq -r '.group_policies[0].address')
    log "✅ Group policy created with address: $GROUP_POLICY_ADDRESS"
fi

# Step 5: Verification
log ""
log "🔍 Step 5: Verification"
log "----------------------"

log "Checking group configuration..."
GROUP_INFO=$(veranatestd query group group-info $GROUP_ID --output json)
GROUP_MEMBERS=$(veranatestd query group group-members $GROUP_ID --output json)
POLICY_INFO=$(veranatestd query group group-policy-info $GROUP_POLICY_ADDRESS --output json)

log "✅ Group Details:"
log "   ID: $(echo $GROUP_INFO | jq -r '.info.id')"
log "   Admin: $(echo $GROUP_INFO | jq -r '.info.admin')"
log "   Metadata: $(echo $GROUP_INFO | jq -r '.info.metadata')"
log "   Total Weight: $(echo $GROUP_INFO | jq -r '.info.total_weight')"

log "✅ Group Members:"
echo $GROUP_MEMBERS | jq -r '.members[] | "   \(.member.address): Weight \(.member.weight)"'

log "✅ Group Policy:"
log "   Address: $(echo $POLICY_INFO | jq -r '.info.address')"
log "   Threshold: $(echo $POLICY_INFO | jq -r '.info.decision_policy.value.threshold')"
log "   Voting Period: $(echo $POLICY_INFO | jq -r '.info.decision_policy.value.windows.voting_period')"
log "   Min Execution Period: $(echo $POLICY_INFO | jq -r '.info.decision_policy.value.windows.min_execution_period')"

# Step 6: Display Configuration
log ""
log "📝 Step 6: Configuration Summary"
log "--------------------------------"

log "✅ Council Configuration:"
log "   Chain ID: $CHAIN_ID"
log "   Keyring Backend: $KEYRING_BACKEND"
log "   Group ID: $GROUP_ID"
log "   Group Policy: $GROUP_POLICY_ADDRESS"
log "   Voting Period: $VOTING_PERIOD"
log "   Threshold: $THRESHOLD"
log ""
log "✅ Council Members:"
log "   Member 1: $MEMBER_1 (council-member-1)"
log "   Member 2: $MEMBER_2 (council-member-2)"
log "   Member 3: $MEMBER_3 (council-member-3)"

# Step 7: Test Proposal Template
log ""
log "🧪 Step 7: Creating Test Proposal Template"
log "------------------------------------------"

cat > test_proposal_template.json <<EOF
{
  "group_policy_address": "$GROUP_POLICY_ADDRESS",
  "messages": [
    {
      "@type": "/veranatest.validatorregistry.v1.MsgOnboardValidator",
      "creator": "$GROUP_POLICY_ADDRESS",
      "member_id": "test-validator",
      "operator_address": "cosmosvaloper1test123",
      "consensus_pubkey": "",
      "status": "active",
      "term_end": 0
    }
  ],
  "metadata": "Test proposal for council governance",
  "title": "Test Validator Onboarding",
  "summary": "Testing council-based validator onboarding with 100s voting period",
  "proposers": ["$MEMBER_1"]
}
EOF

log "✅ Test proposal template created: test_proposal_template.json"

# Cleanup
log ""
log "🧹 Cleanup"
log "----------"
rm -f members.json policy.json
log "✅ Temporary files cleaned up"

# Final Summary
log ""
log "🎉 Council Governance Setup Complete!"
log "====================================="
log ""
log "📋 Summary:"
log "   ✅ Council members: 3 (equal voting power)"
log "   ✅ Group ID: $GROUP_ID"
log "   ✅ Group Policy: $GROUP_POLICY_ADDRESS"
log "   ✅ Voting Period: $VOTING_PERIOD"
log "   ✅ Threshold: $THRESHOLD votes required"
log "   ✅ Test template: test_proposal_template.json"
log ""
log "🚀 Next Steps:"
log "   1. Submit proposal: veranatestd tx group submit-proposal test_proposal_template.json --from council-member-1 --keyring-backend test --chain-id vna-testnet-1 --fees 500000uvna -y"
log "   2. Vote on proposal: veranatestd tx group vote <proposal-id> <voter-address> VOTE_OPTION_YES \"Approved\" --from <member> --keyring-backend test --chain-id vna-testnet-1 --fees 500000uvna -y"
log "   3. Wait $VOTING_PERIOD for voting period to end"
log "   4. Execute proposal: veranatestd tx group exec <proposal-id> --from council-member-1 --keyring-backend test --chain-id vna-testnet-1 --fees 500000uvna -y"
log ""
log "📚 Documentation: See COUNCIL_GOVERNANCE.md for detailed examples"
log ""
log "✨ Council governance is ready for validator management!"
