#!/bin/bash

# Avoid strict error handling
set -uo pipefail

# General arguments
ROOT=$PWD

# Create log file for debugging but don't show all commands
LOGFILE="$ROOT/rl_swarm_debug.log"
touch $LOGFILE
# Only log to file, don't show every command in terminal
exec 5>&1
exec 6>&2
exec > >(tee -a "$LOGFILE") 2>&1

echo "Log file enabled at: $LOGFILE (check this if you encounter issues)"

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes
export USE_NGROK=${USE_NGROK:-false}  # Default to not using ngrok

# Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

# Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

# Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-""}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Create necessary directories
mkdir -p "$ROOT_DIR/modal-login/temp-data"
mkdir -p "$ROOT_DIR/ngrok_tmp"

# Function to download and install ngrok
install_ngrok() {
    echo "Installing ngrok automatically..."
    local NGROK_DIR="$ROOT_DIR/ngrok_tmp"
    
    # Download ngrok if not already downloaded
    if [ ! -f "$NGROK_DIR/ngrok" ]; then
        cd "$NGROK_DIR"
        curl -s -o ngrok.zip https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.zip
        unzip -q ngrok.zip
        chmod +x ngrok
        cd "$ROOT_DIR"
    fi
    
    # Add to PATH
    export PATH="$NGROK_DIR:$PATH"
    
    # Verify installation
    if ! command -v ngrok > /dev/null 2>&1; then
        echo "Failed to install ngrok. Please install it manually and try again."
        return 1
    fi
    
    echo "Ngrok installed successfully at $NGROK_DIR/ngrok"
    return 0
}

# Function to wait for userData.json to be created and extract ORG_ID
wait_for_login_completion() {
    local max_wait=300  # 5 minutes
    local wait_count=0
    
    echo "Waiting for login completion..."
    
    # Delete any existing userData.json to avoid false detection
    rm -f "$ROOT_DIR/modal-login/temp-data/userData.json" 2>/dev/null || true
    
    while [ ! -f "$ROOT_DIR/modal-login/temp-data/userData.json" ]; do
        echo -n "."
        sleep 2
        wait_count=$((wait_count + 2))
        
        # Check every 30 seconds if API key is activated
        if [ $((wait_count % 30)) -eq 0 ]; then
            echo ""
            echo "Still waiting for login completion... ($wait_count seconds elapsed)"
            echo "Please login at the ngrok URL to continue."
        fi
        
        if [ $wait_count -ge $max_wait ]; then
            echo ""
            echo "Timed out waiting for login completion."
            echo "Do you want to continue waiting? (y/n)"
            read -p "> " continue_waiting
            
            if [[ "$continue_waiting" != "y" ]]; then
                echo "Login process aborted."
                return 1
            fi
            
            wait_count=0
        fi
    done
    
    echo ""
    echo "Login data file found!"
    
    # Try to extract ORG_ID using multiple methods to ensure compatibility
    ORG_ID=$(grep -o '"orgId":"[^"]*"' "$ROOT_DIR/modal-login/temp-data/userData.json" 2>/dev/null | cut -d'"' -f4 || echo "")
    
    if [ -z "$ORG_ID" ]; then
        ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' "$ROOT_DIR/modal-login/temp-data/userData.json" 2>/dev/null || echo "")
    fi
    
    if [ -z "$ORG_ID" ]; then
        echo "Failed to extract ORG_ID from userData.json."
        cat "$ROOT_DIR/modal-login/temp-data/userData.json"
        echo "Please enter your ORG_ID manually:"
        read -p "> " ORG_ID
        return 0
    fi
    
    echo "Successfully extracted ORG_ID: $ORG_ID"
    return 0
}

# Function to clean up the server process upon exit
cleanup() {
    echo_green ">> Shutting down trainer..."

    # Kill server processes
    if [ -n "${SERVER_PID:-}" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi

    # Kill ngrok processes
    if [ -n "${NGROK_PID:-}" ]; then
        kill $NGROK_PID 2>/dev/null || true
    fi
    
    # Kill any other ngrok processes
    pkill -f ngrok 2>/dev/null || true

    # Kill all processes belonging to this script's process group
    kill -- -$$ 2>/dev/null || true

    echo "Cleanup complete."
    exit 0
}

# Register cleanup to run on script exit
trap cleanup EXIT

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Would you like to connect to the Testnet? [Y/n] " yn
    echo -en $RESET_TEXT
    yn=${yn:-Y}  # Default to "Y" if the user presses Enter
    case $yn in
        [Yy]*)  CONNECT_TO_TESTNET=true && break ;;
        [Nn]*)  CONNECT_TO_TESTNET=false && break ;;
        *)  echo ">>> Please answer yes or no." ;;
    esac
done

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Would you like to use ngrok for remote access to the login page? [Y/n] " yn
    echo -en $RESET_TEXT
    yn=${yn:-Y}  # Default to "Y" if the user presses Enter
    case $yn in
        [Yy]*)  USE_NGROK=true && break ;;
        [Nn]*)  USE_NGROK=false && break ;;
        *)  echo ">>> Please answer yes or no." ;;
    esac
done

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Which swarm would you like to join (Math (A) or Math Hard (B))? [A/b] " ab
    echo -en $RESET_TEXT
    ab=${ab:-A}  # Default to "A" if the user presses Enter
    case $ab in
        [Aa]*)  USE_BIG_SWARM=false && break ;;
        [Bb]*)  USE_BIG_SWARM=true && break ;;
        *)  echo ">>> Please answer A or B." ;;
    esac
done
if [ "$USE_BIG_SWARM" = true ]; then
    SWARM_CONTRACT="$BIG_SWARM_CONTRACT"
else
    SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
fi
while true; do
    echo -en $GREEN_TEXT
    read -p ">> How many parameters (in billions)? [0.5, 1.5, 7, 32, 72] " pc
    echo -en $RESET_TEXT
    pc=${pc:-0.5}  # Default to "0.5" if the user presses Enter
    case $pc in
        0.5 | 1.5 | 7 | 32 | 72) PARAM_B=$pc && break ;;
        *)  echo ">>> Please answer in [0.5, 1.5, 7, 32, 72]." ;;
    esac
done

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server.
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login || { echo "Could not change to modal-login directory"; exit 1; }
    
    # Check if .env file exists, create it if not
    if [ ! -f ".env" ]; then
        echo "Creating .env file"
        echo "VITE_BASE_URL=http://localhost:3000" > .env
        echo "VITE_API_URL=http://localhost:3000/api" >> .env
        echo "SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT" >> .env
    fi
    
    # Make sure node_modules directory exists
    mkdir -p node_modules
    
    # Check for Node.js
    echo "Checking for Node.js..."
    if ! command -v node > /dev/null 2>&1; then
        echo "Node.js not found. Requesting manual ORG_ID..."
        read -p "Please provide your ORG_ID: " ORG_ID
        mkdir -p "$ROOT_DIR/modal-login/temp-data"
        echo "{\"orgId\":\"$ORG_ID\"}" > "$ROOT_DIR/modal-login/temp-data/userData.json"
        cd "$ROOT_DIR"
        goto_training=true
    else
        echo "Node.js found: $(node -v)"
    fi
    
    # If we should skip to training
    if [ "${goto_training:-false}" = true ]; then
        echo "Skipping normal login flow and proceeding to training..."
    else
        echo "-------------------------------------------------"
        echo "AUTOMATIC NGROK SETUP"
        echo "-------------------------------------------------"
        
        # Check if ngrok is installed, if not, install it
        if ! command -v ngrok > /dev/null 2>&1; then
            install_ngrok || { 
                echo "Failed to install ngrok automatically. Aborting."; 
                exit 1; 
            }
        fi
        
        # Ask for ngrok auth token
        echo "Do you have an ngrok auth token? (get one for free at https://dashboard.ngrok.com/get-started/your-authtoken)"
        read -p "Enter your ngrok auth token (or press Enter to skip): " NGROK_TOKEN
        
        if [ -n "$NGROK_TOKEN" ]; then
            ngrok config add-authtoken "$NGROK_TOKEN" || echo "Failed to add auth token, continuing anyway..."
        else
            echo "No auth token provided. Ngrok may have limited functionality."
        fi
        
        echo "-------------------------------------------------"
        echo "STARTING LOGIN SERVER"
        echo "-------------------------------------------------"
        
        # Start the server in the background
        if command -v npm > /dev/null 2>&1; then
            echo "Starting login server with npm..."
            npm run dev > "$ROOT_DIR/server.log" 2>&1 &
            SERVER_PID=$!
            echo "Server started with PID: $SERVER_PID"
        else
            echo "npm not found, cannot start server."
            exit 1
        fi
        
        # Wait for server to start
        sleep 5
        
        # Start ngrok in the background
        echo "Starting ngrok automatically..."
        ngrok http 3000 > "$ROOT_DIR/ngrok.log" 2>&1 &
        NGROK_PID=$!
        echo "Ngrok started with PID: $NGROK_PID"
        
        # Wait for ngrok to establish tunnel
        echo "Waiting for ngrok tunnel to be established..."
        sleep 5
        
        # Try to get the ngrok URL with multiple attempts
        NGROK_URL=""
        for i in {1..5}; do
            echo "Trying to get ngrok URL (attempt $i/5)..."
            NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*' | grep -o 'https://[^"]*' || echo "")
            
            if [ -n "$NGROK_URL" ]; then
                break
            fi
            
            sleep 2
        done
        
        if [ -z "$NGROK_URL" ]; then
            echo "Failed to get ngrok URL automatically."
            echo "Checking ngrok logs:"
            cat "$ROOT_DIR/ngrok.log"
            
            echo "Please enter the ngrok URL manually:"
            read -p "Enter the ngrok URL from another terminal running 'ngrok http 3000': " NGROK_URL
            
            if [ -z "$NGROK_URL" ]; then
                echo "No ngrok URL provided. Aborting."
                exit 1
            fi
        fi
        
        echo "-------------------------------------------------"
        echo "LOGIN INSTRUCTIONS"
        echo "-------------------------------------------------"
        echo_green ">> Your login page is available at: $NGROK_URL"
        echo "1. Open this URL in your browser: $NGROK_URL"
        echo "2. Complete the login process"
        echo "3. The script will automatically continue when login is completed"
        echo ""
        
        # Wait for the login to complete and extract ORG_ID automatically
        wait_for_login_completion || {
            echo "Login process failed. Aborting."
            exit 1
        }
        
        cd "$ROOT_DIR"
    fi
fi

echo_green ">> Getting requirements..."

pip install --upgrade pip
if [ -n "$CPU_ONLY" ] || ! command -v nvidia-smi &> /dev/null; then
    # CPU-only mode or no NVIDIA GPU found
    pip install -r "$ROOT"/requirements-cpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml" # TODO: Fix naming.
    GAME="gsm8k"
else
    # NVIDIA GPU found
    pip install -r "$ROOT"/requirements-gpu.txt
    pip install flash-attn --no-build-isolation

    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        0.5 | 1.5 | 7) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
        *)  echo ">>> Please answer in [0.5, 1.5, 7, 32, 72]." ;;
    esac
    if [ "$USE_BIG_SWARM" = true ]; then
        GAME="dapo"
    else
        GAME="gsm8k"
    fi
fi

echo_green ">> Done!"

HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then # Check if HF_TOKEN is already set and use if so. Else give user a prompt to choose.
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -en $GREEN_TEXT
    read -p ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
    echo -en $RESET_TEXT
    yn=${yn:-N} # Default to "N" if the user presses Enter
    case $yn in
        [Yy]*) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) echo ">>> No answer was given, so NO models will be pushed to Hugging Face Hub" && HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

echo_green ">> Good luck in the swarm!"
echo_blue ">> Post about rl-swarm on X/twitter! --> https://tinyurl.com/swarmtweet"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

if [ -n "$ORG_ID" ]; then
    echo "Starting training with ORG_ID: $ORG_ID"
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$SWARM_CONTRACT" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
else
    echo "Starting training without ORG_ID"
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
fi

wait  # Keep script running until Ctrl+C
