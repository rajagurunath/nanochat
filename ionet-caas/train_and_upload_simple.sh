#!/bin/bash

# Simple wrapper script for nanochat training on IONet CaaS
# This script handles container environment setup and adds R2 upload

set -e  # Exit on error

echo "=================================="
echo "nanochat IONet Training Wrapper"
echo "=================================="
echo "Start time: $(date)"

# R2 configuration
R2_ENDPOINT_URL=${R2_ENDPOINT_URL:-""}
R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID:-""}
R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY:-""}
R2_BUCKET_NAME=${R2_BUCKET_NAME:-"llm-exploration"}

echo ""
echo "=================================="
echo "Step 1: Pre-flight Checks"
echo "=================================="

# Check GPU availability
echo "Checking GPU availability..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    echo "✓ Found $GPU_COUNT GPU(s)"
else
    echo "❌ nvidia-smi not found!"
    exit 1
fi

# Install/verify AWS CLI for R2 (if R2 is configured)
if [ -n "$R2_ENDPOINT_URL" ] && [ -n "$R2_ACCESS_KEY_ID" ]; then
    echo "Configuring R2 access..."

    # Check if awscli is already installed
    if ! command -v aws &> /dev/null; then
        echo "Installing AWS CLI..."
        pip3 install --quiet awscli boto3
    fi

    # Configure AWS CLI
    mkdir -p ~/.aws
    cat > ~/.aws/credentials <<EOF
[default]
aws_access_key_id = $R2_ACCESS_KEY_ID
aws_secret_access_key = $R2_SECRET_ACCESS_KEY
EOF

    cat > ~/.aws/config <<EOF
[default]
region = auto
output = json
EOF

    # Test R2 connectivity
    echo "Testing R2 connectivity..."
    TEST_FILE="/tmp/r2_test_$(date +%s).txt"
    echo "IONet nanochat - R2 test at $(date)" > $TEST_FILE

    if aws s3 cp $TEST_FILE s3://$R2_BUCKET_NAME/ --endpoint-url $R2_ENDPOINT_URL 2>/dev/null; then
        echo "✓ R2 upload test successful"
        aws s3 rm s3://$R2_BUCKET_NAME/$(basename $TEST_FILE) --endpoint-url $R2_ENDPOINT_URL 2>/dev/null
        rm $TEST_FILE
    else
        echo "❌ R2 upload test failed!"
        exit 1
    fi
else
    echo "⚠️  R2 not configured - uploads will be skipped"
fi

echo ""
echo "=================================="
echo "Step 2: Setup nanochat Environment"
echo "=================================="

cd /workspace

# Clone nanochat if not already present
if [ ! -d "nanochat" ]; then
    echo "Cloning nanochat repository..."
    git clone https://github.com/karpathy/nanochat.git
fi

cd nanochat

# Setup Python environment (container-friendly version)
export OMP_NUM_THREADS=1
export NANOCHAT_BASE_DIR="${NANOCHAT_BASE_DIR:-$HOME/.cache/nanochat}"
mkdir -p $NANOCHAT_BASE_DIR

# Install uv if not present (with proper error handling)
if ! command -v uv &> /dev/null; then
    echo "Installing uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Create venv and install dependencies
echo "Setting up Python virtual environment..."
if [ ! -d ".venv" ]; then
    uv venv
fi

echo "Installing Python dependencies..."
uv sync --extra gpu

# Activate venv
source .venv/bin/activate

# Install Rust for tokenizer (if not already installed)
if ! command -v rustc &> /dev/null; then
    echo "Installing Rust toolchain..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Test wandb if configured
if [ -n "$WANDB_API_KEY" ]; then
    echo "Testing wandb configuration..."
    python3 -c "import wandb; wandb.login(key='$WANDB_API_KEY')" 2>/dev/null && echo "✓ wandb configured" || echo "⚠️  wandb test failed"
fi

# Set wandb run name
if [ -n "$WANDB_RUN" ] && [ "$WANDB_RUN" != "dummy" ]; then
    export WANDB_RUN=$WANDB_RUN
else
    export WANDB_RUN=dummy
fi

echo ""
echo "=================================="
echo "Step 3: Training Pipeline"
echo "=================================="
echo "This will take approximately 4 hours..."
echo "Training log: /workspace/nanochat/speedrun.log"

# Reset report
python -m nanochat.report reset

# Build tokenizer
echo "Building Rust tokenizer..."
uv run maturin develop --release --manifest-path rustbpe/Cargo.toml

# Download initial dataset
echo "Downloading initial dataset (~800MB)..."
python -m nanochat.dataset -n 8

# Download remaining data in background
echo "Starting background dataset download (~24GB)..."
python -m nanochat.dataset -n 240 &
DATASET_DOWNLOAD_PID=$!

# Train tokenizer
echo "Training tokenizer..."
python -m scripts.tok_train --max_chars=2000000000
python -m scripts.tok_eval

# Download eval bundle
echo "Downloading evaluation bundle..."
EVAL_BUNDLE_URL=https://karpathy-public.s3.us-west-2.amazonaws.com/eval_bundle.zip
if [ ! -d "$NANOCHAT_BASE_DIR/eval_bundle" ]; then
    curl -L -o eval_bundle.zip $EVAL_BUNDLE_URL
    unzip -q eval_bundle.zip
    rm eval_bundle.zip
    mv eval_bundle $NANOCHAT_BASE_DIR
fi

# Wait for dataset download
echo "Waiting for dataset download to complete..."
wait $DATASET_DOWNLOAD_PID

# Pretraining
echo "Starting pretraining (d20 model, 561M parameters)..."
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.base_train -- --depth=20 --run=$WANDB_RUN
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.base_loss
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.base_eval

# Download identity conversations
echo "Downloading identity conversations..."
curl -L -o $NANOCHAT_BASE_DIR/identity_conversations.jsonl https://karpathy-public.s3.us-west-2.amazonaws.com/identity_conversations.jsonl

# Midtraining
echo "Starting midtraining..."
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.mid_train -- --run=$WANDB_RUN
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.chat_eval -- -i mid

# Supervised finetuning
echo "Starting supervised finetuning..."
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.chat_sft -- --run=$WANDB_RUN
torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.chat_eval -- -i sft

# Generate final report
echo "Generating training report..."
python -m nanochat.report generate

echo ""
echo "=================================="
echo "Step 4: Upload to R2"
echo "=================================="

if [ -n "$R2_ENDPOINT_URL" ] && [ -n "$R2_ACCESS_KEY_ID" ]; then
    echo "Uploading model artifacts to R2..."

    # Create timestamp for this run
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    MODEL_PREFIX="nanochat-d20-$TIMESTAMP"
    NANOCHAT_BASE_DIR="${NANOCHAT_BASE_DIR:-$HOME/.cache/nanochat}"

    # Upload checkpoints
    for checkpoint in base.pt mid.pt sft.pt; do
        if [ -f "$NANOCHAT_BASE_DIR/checkpoints/$checkpoint" ]; then
            echo "Uploading $checkpoint..."
            aws s3 cp "$NANOCHAT_BASE_DIR/checkpoints/$checkpoint" \
                "s3://$R2_BUCKET_NAME/$MODEL_PREFIX/checkpoints/$checkpoint" \
                --endpoint-url "$R2_ENDPOINT_URL"
        fi
    done

    # Upload tokenizer
    if [ -f "$NANOCHAT_BASE_DIR/tokenizer.model" ]; then
        echo "Uploading tokenizer.model..."
        aws s3 cp "$NANOCHAT_BASE_DIR/tokenizer.model" \
            "s3://$R2_BUCKET_NAME/$MODEL_PREFIX/tokenizer.model" \
            --endpoint-url "$R2_ENDPOINT_URL"
    fi

    # Upload report
    if [ -f "report.md" ]; then
        echo "Uploading report.md..."
        aws s3 cp report.md \
            "s3://$R2_BUCKET_NAME/$MODEL_PREFIX/report.md" \
            --endpoint-url "$R2_ENDPOINT_URL"
    fi

    # Upload training log if it exists
    if [ -f "speedrun.log" ]; then
        echo "Uploading speedrun.log..."
        aws s3 cp speedrun.log \
            "s3://$R2_BUCKET_NAME/$MODEL_PREFIX/speedrun.log" \
            --endpoint-url "$R2_ENDPOINT_URL"
    fi

    # Create metadata
    cat > /tmp/metadata.json <<EOF
{
  "model_name": "nanochat-d20",
  "timestamp": "$TIMESTAMP",
  "training_duration": "~4 hours",
  "gpu_count": $GPU_COUNT,
  "wandb_run": "${WANDB_RUN:-dummy}",
  "model_params": "561M",
  "training_tokens": "11.2B",
  "model_depth": 20,
  "upload_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    aws s3 cp /tmp/metadata.json \
        "s3://$R2_BUCKET_NAME/$MODEL_PREFIX/metadata.json" \
        --endpoint-url "$R2_ENDPOINT_URL"

    echo ""
    echo "✓ Model uploaded to: s3://$R2_BUCKET_NAME/$MODEL_PREFIX/"
    echo ""
    echo "Uploaded files:"
    aws s3 ls "s3://$R2_BUCKET_NAME/$MODEL_PREFIX/" --recursive --endpoint-url "$R2_ENDPOINT_URL"

else
    echo "⚠️  R2 upload skipped - credentials not configured"
fi

echo ""
echo "=================================="
echo "Training Complete!"
echo "=================================="
echo "End time: $(date)"

# Print report summary
if [ -f "report.md" ]; then
    echo ""
    echo "Training Report Summary:"
    tail -n 30 report.md
fi

# Optionally serve the model
if [ "$KEEP_ALIVE" = "true" ]; then
    echo ""
    echo "KEEP_ALIVE=true - Starting model server on port 8000..."
    source .venv/bin/activate
    python -m scripts.chat_web --host 0.0.0.0 --port 8000
else
    echo ""
    echo "To serve the model, set KEEP_ALIVE=true in your deployment"
fi
