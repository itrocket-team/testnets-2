#!/bin/bash
export CHAIN_ID=cosmoshub-4
export GENESIS_URL=https://snapshots.polkachu.com/genesis/cosmos/genesis.json
export SNAPSHOT_URL=https://snapshots.lavenderfive.com/snapshots/cosmoshub/latest.tar.lz4
export START_VERSION="v16.0.0"
export FORK_BRANCH="release/v16.x"
export UPGRADE_NAME=v17

export NODE_HOME="$(pwd)/.gaia"
export NODE_MONIKER=upgrade-test
export BINARY=gaiad
export UPGRADE_VERSION="$UPGRADE_NAME.0.0"
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"

echo "*** 1. SET UP NODE ***"
echo ">>> Installing Go and Gaia <<<"
sudo apt update
sudo apt upgrade -y
sudo apt install git build-essential lz4 -y
curl -OL https://golang.org/dl/go1.21.9.linux-amd64.tar.gz
sudo tar -C /usr/local -xvf go1.21.9.linux-amd64.tar.gz
rm go1.21.9.linux-amd64.tar.gz

git clone https://github.com/cosmos/gaia.git
cd gaia
git checkout $START_VERSION
make install
cd ..

echo ">>> Initializing node <<<"
rm -rf $NODE_HOME
$BINARY config chain-id $CHAIN_ID --home $NODE_HOME
$BINARY config keyring-backend test --home $NODE_HOME
$BINARY init $NODE_MONIKER --home $NODE_HOME --chain-id=$CHAIN_ID

echo ">>> Configuring node settings <<<"
sed -i -e 's/minimum-gas-prices = ""/minimum-gas-prices = "0.005uatom"/g' $NODE_HOME/config/app.toml
sed -i -e '/block_sync =/ s/= .*/= false/' $NODE_HOME/config/config.toml

echo ">>> Downloading genesis file <<<"
wget $GENESIS_URL -O $NODE_HOME/config/genesis.json

echo ">>> Downloading snapshot <<<"
wget $SNAPSHOT_URL -O latest.tar.lz4
lz4 -c -d latest.tar.lz4  | tar -x -C $NODE_HOME
rm latest.tar.lz4

echo ">>> Adding validator account <<<"
wallet=$($BINARY --home $NODE_HOME keys add validator --keyring-backend test --output json | jq -r '.address')
bytes_address=$($BINARY keys parse $wallet --output json | jq -r '.bytes')
valoper=$($BINARY keys parse $bytes_address --output json | jq -r '.formats[2]')

echo "*** 2. FORK CHAIN ***"
echo ">>> Building fork binary <<<"
cd gaia
git checkout $FORK_BRANCH
make build BUILD_TAGS="-tag unsafe_start_local_validator"
cp build/gaiad $HOME/go/bin/gaiad-v16-fork
cd ..
rm -rf gaia
echo ">>> Forking the chain with a single validator <<<"
tmux new-session -d -s fork "$HOME/go/bin/gaiad-v16-fork testnet unsafe-start-local-validator --validator-operator $valoper --validator-pubkey $(jq -r '.pub_key.value' $NODE_HOME/config/priv_validator_key.json) --validator-privkey $(jq -r '.priv_key.value' $NODE_HOME/config/priv_validator_key.json) --accounts-to-fund $wallet --home $NODE_HOME"
sleep 1m
tmux send-keys -t fork C-c

echo "*** 3. START CHAIN ***"
echo ">>> Installing Cosmovisor <<<"
export GO111MODULE=on
go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.4.0
export DAEMON_NAME=gaiad
export DAEMON_HOME=$NODE_HOME
cosmovisor init $HOME/go/bin/$BINARY
echo ">>> Starting Cosmovisor <<<"
export DAEMON_NAME=gaiad
export DAEMON_HOME=$NODE_HOME
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_ALLOW_DOWNLOAD_BINARIES=true
export DAEMON_LOG_BUFFER_SIZE=512
export UNSAFE_SKIP_BACKUP=true
tmux new-session -d -s cosmovisor "$HOME/go/bin/cosmovisor run start --x-crisis-skip-assert-invariants --home $NODE_HOME"
sleep 30s

echo "*** 4. UPGRADE CHAIN ***"
echo ">>> Delegating from funded account <<<"
$BINARY tx staking delegate $valoper 10000000uatom --from $wallet --gas auto --gas-adjustment 2 --gas-prices 0.005uatom -y --home $NODE_HOME
sleep 8s
echo ">>> Calculating upgrade height <<<"
current_block=$($BINARY q block --home $NODE_HOME | jq -r '.block.header.height')
upgrade_height=$(($current_block+20))
echo "Current block: $current_block, upgrade height: $upgrade_height"
echo ">>> Submitting upgrade proposal <<<"
proposal_json="{\"messages\":[{\"@type\": \"/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade\",\"authority\": \"cosmos10d07y265gmmuvt4z0w9aw880jnsr700j6zn9kn\",\"plan\":{\"name\":\"$UPGRADE_NAME\",\"time\":\"0001-01-01T00:00:00Z\",\"height\": \"0\",\"info\": \"\",\"upgraded_client_state\": null}}],\"metadata\": \"ipfs://\",\"deposit\": \"250000000uatom\",\"title\": \"Upgrade to Gaia v17\",\"summary\": \"# Gaia v17 Upgrade\r\n\r\n\"}"
echo $proposal_json > proposal.json
jq -r --arg HEIGHT "$upgrade_height" '.messages[0].plan.height |= $HEIGHT' proposal.json > proposal-height.json
info="{\"binaries\": {\"darwin/amd64\": \"https://github.com/cosmos/gaia/releases/download/$UPGRADE_VERSION/gaiad-$UPGRADE_VERSION-darwin-amd64\", \"darwin/arm64\": \"https://github.com/cosmos/gaia/releases/download/$UPGRADE_VERSION/gaiad-$UPGRADE_VERSION-darwin-arm64\", \"linux/amd64\": \"https://github.com/cosmos/gaia/releases/download/$UPGRADE_VERSION/gaiad-$UPGRADE_VERSION-linux-amd64\", \"linux/arm64\": \"https://github.com/cosmos/gaia/releases/download/$UPGRADE_VERSION/gaiad-$UPGRADE_VERSION-linux-arm64\", \"windows/amd64\": \"https://github.com/cosmos/gaia/releases/download/$UPGRADE_VERSION/gaiad-$UPGRADE_VERSION-windows-amd64.exe\", \"windows/arm64\": \"https://github.com/cosmos/gaia/releases/download/$UPGRADE_VERSION/gaiad-$UPGRADE_VERSION-windows-arm64.exe\"}}"
jq -r --arg INFO "$info" '.messages[0].plan.info |= $INFO' proposal-height.json > proposal.json
txhash=$($BINARY tx gov submit-proposal proposal.json --from $wallet --gas auto --gas-adjustment 2 --gas-prices 0.005uatom -y -o json --home $NODE_HOME | jq -r '.txhash')
echo "Hash: $txhash"
sleep 8s
proposal_id=$($BINARY q tx $txhash --home $NODE_HOME -o json | jq -r '.events[] | select(.type=="submit_proposal") | .attributes[] | select(.key=="proposal_id").value')
echo ">>> Voting yes on proposal $proposal_id <<<"
$BINARY tx gov vote $proposal_id yes --from $wallet --gas auto --gas-adjustment 2 --gas-prices 0.005uatom -y --home $NODE_HOME
sleep 20s
status=$($BINARY q gov proposal $proposal_id --home $NODE_HOME -o json | jq -r '.status')
echo ">>> Upgrade proposal status: $status <<<"
rm proposal.json proposal-height.json

echo ""
echo ">>> The upgrade will occur at height $upgrade_height <<<"
echo "- To access the node log, attach the tmux session:"
echo "tmux attach-session -t cosmovisor"
echo ""
echo "- To detach from the tmux session, press Ctrl+B followed by D"
echo ""
echo "- To verify the new version, check the abci_info endpoint after the upgrade:"
echo "curl -s http://localhost:26657/abci_info | jq '.result.response.version'"
echo ""
echo "- To stop the tmux session, stop the program while attached or send Ctrl+C to it:"
echo "tmux send-keys -t cosmovisor C-c"
