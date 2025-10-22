#!/bin/bash

# nanochat Training and Upload Script for IONet CaaS
# This script trains a nanochat model and uploads it to Cloudflare R2
# Expected runtime: ~4 hours for training on 8XH100 GPU node

set -e  # Exit on error

echo "=================================="
echo "nanochat Training Pipeline"
echo "=================================="
echo "Start time: $(date)"

# Configuration
export OMP_NUM_THREADS=1
export NANOCHAT_BASE_DIR="$HOME/.cache/nanochat"
mkdir -p $NANOCHAT_BASE_DIR

# WANDB configuration (optional but recommended)
if [ -z "$WANDB_API_KEY" ]; then
    echo "⚠️  WANDB_API_KEY not set - training will proceed without wandb logging"
    export WANDB_RUN=dummy
else
    echo "✓ WANDB_API_KEY found - will log to wandb"
    export WANDB_RUN=${WANDB_RUN:-"ionet-speedrun-$(date +%Y%m%d-%H%M%S)"}
fi

# R2 configuration
R2_ENDPOINT_URL=${R2_ENDPOINT_URL:-""}
R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID:-""}
R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY:-""}
R2_BUCKET_NAME=${R2_BUCKET_NAME:-"llm-exploration"}

echo ""
echo "=================================="
echo "Step 1: Environment Verification"
echo "=================================="

# Check GPU availability
echo "Checking GPU availability..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    echo "✓ Found $GPU_COUNT GPU(s)"
else
    echo "❌ nvidia-smi not found! GPU may not be available"
    exit 1
fi

# Check Python
echo "Checking Python..."
python3 --version
echo "✓ Python is available"

# Check pip
echo "Checking pip..."
pip3 --version || python3 -m pip --version
echo "✓ pip is available"

echo ""
echo "=================================="
echo "Step 2: R2 Configuration Test"
echo "=================================="

# Install AWS CLI for R2 uploads (S3-compatible)
echo "Installing AWS CLI..."
pip3 install --quiet awscli boto3

# Configure AWS CLI for R2
if [ -n "$R2_ENDPOINT_URL" ] && [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ]; then
    echo "Configuring R2 credentials..."

    # Create AWS config directory
    mkdir -p ~/.aws

    # Configure credentials
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
    echo "IONet nanochat training - R2 test at $(date)" > $TEST_FILE

    if aws s3 cp $TEST_FILE s3://$R2_BUCKET_NAME/ --endpoint-url $R2_ENDPOINT_URL; then
        echo "✓ R2 upload test successful"
        # Clean up test file
        aws s3 rm s3://$R2_BUCKET_NAME/$(basename $TEST_FILE) --endpoint-url $R2_ENDPOINT_URL
        rm $TEST_FILE
    else
        echo "❌ R2 upload test failed! Check your credentials and bucket configuration"
        exit 1
    fi
else
    echo "⚠️  R2 credentials not fully configured - uploads will be skipped"
    echo "Required env vars: R2_ENDPOINT_URL, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY"
fi

echo ""
echo "=================================="
echo "Step 3: Clone nanochat Repository"
echo "=================================="

cd /workspace
if [ -d "nanochat" ]; then
    echo "nanochat directory exists, removing..."
    rm -rf nanochat
fi

echo "Cloning nanochat repository..."
git clone https://github.com/karpathy/nanochat.git
cd nanochat
echo "✓ Repository cloned successfully"

echo ""
echo "=================================="
echo "Step 4: Dependency Installation"
echo "=================================="

# Install uv (fast Python package installer)
echo "Installing uv package manager..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.cargo/bin:$PATH"

# Create virtual environment and install dependencies
echo "Creating virtual environment..."
uv venv
source .venv/bin/activate

echo "Installing Python dependencies (this may take a few minutes)..."
uv sync --extra gpu

echo "✓ Dependencies installed successfully"

# Install Rust for tokenizer
echo "Installing Rust toolchain..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

echo "✓ Rust installed successfully"

# Test wandb if configured
if [ -n "$WANDB_API_KEY" ]; then
    echo "Testing wandb configuration..."
    python3 -c "import wandb; wandb.login(key='$WANDB_API_KEY')" && echo "✓ wandb configured successfully" || echo "⚠️  wandb test failed"
fi

echo ""
echo "=================================="
echo "Step 5: Start Training Pipeline"
echo "=================================="
echo "This will take approximately 4 hours..."
echo "Training log will be saved to: /workspace/nanochat/speedrun.log"

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
echo "Step 6: Upload Model to R2"
echo "=================================="

if [ -n "$R2_ENDPOINT_URL" ] && [ -n "$R2_ACCESS_KEY_ID" ]; then
    echo "Preparing model artifacts for upload..."

    # Create a timestamp for this training run
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    MODEL_PREFIX="nanochat-d20-$TIMESTAMP"

    # Upload model checkpoints
    echo "Uploading model files to R2..."

    # Upload the final SFT model (main checkpoint)
    if [ -f "$NANOCHAT_BASE_DIR/checkpoints/sft.pt" ]; then
        echo "Uploading sft.pt..."
        aws s3 cp $NANOCHAT_BASE_DIR/checkpoints/sft.pt \
            s3://$R2_BUCKET_NAME/$MODEL_PREFIX/checkpoints/sft.pt \
            --endpoint-url $R2_ENDPOINT_URL
    fi

    # Upload base model
    if [ -f "$NANOCHAT_BASE_DIR/checkpoints/base.pt" ]; then
        echo "Uploading base.pt..."
        aws s3 cp $NANOCHAT_BASE_DIR/checkpoints/base.pt \
            s3://$R2_BUCKET_NAME/$MODEL_PREFIX/checkpoints/base.pt \
            --endpoint-url $R2_ENDPOINT_URL
    fi

    # Upload mid model
    if [ -f "$NANOCHAT_BASE_DIR/checkpoints/mid.pt" ]; then
        echo "Uploading mid.pt..."
        aws s3 cp $NANOCHAT_BASE_DIR/checkpoints/mid.pt \
            s3://$R2_BUCKET_NAME/$MODEL_PREFIX/checkpoints/mid.pt \
            --endpoint-url $R2_ENDPOINT_URL
    fi

    # Upload tokenizer
    if [ -f "$NANOCHAT_BASE_DIR/tokenizer.model" ]; then
        echo "Uploading tokenizer.model..."
        aws s3 cp $NANOCHAT_BASE_DIR/tokenizer.model \
            s3://$R2_BUCKET_NAME/$MODEL_PREFIX/tokenizer.model \
            --endpoint-url $R2_ENDPOINT_URL
    fi

    # Upload training report
    if [ -f "report.md" ]; then
        echo "Uploading report.md..."
        aws s3 cp report.md \
            s3://$R2_BUCKET_NAME/$MODEL_PREFIX/report.md \
            --endpoint-url $R2_ENDPOINT_URL
    fi

    # Create and upload metadata
    cat > /tmp/training_metadata.json <<EOF
{
  "model_name": "nanochat-d20",
  "timestamp": "$TIMESTAMP",
  "training_duration": "~4 hours",
  "gpu_count": $GPU_COUNT,
  "wandb_run": "$WANDB_RUN",
  "model_params": "561M",
  "training_tokens": "11.2B",
  "model_depth": 20,
  "upload_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    echo "Uploading training metadata..."
    aws s3 cp /tmp/training_metadata.json \
        s3://$R2_BUCKET_NAME/$MODEL_PREFIX/metadata.json \
        --endpoint-url $R2_ENDPOINT_URL

    # List uploaded files
    echo ""
    echo "Uploaded files:"
    aws s3 ls s3://$R2_BUCKET_NAME/$MODEL_PREFIX/ --recursive --endpoint-url $R2_ENDPOINT_URL

    echo ""
    echo "✓ Model successfully uploaded to R2!"
    echo "Model location: s3://$R2_BUCKET_NAME/$MODEL_PREFIX/"

else
    echo "⚠️  R2 upload skipped - credentials not configured"
fi

echo ""
echo "=================================="
echo "Training Complete!"
echo "=================================="
echo "End time: $(date)"
echo ""

# Print summary
if [ -f "report.md" ]; then
    echo "Training Report Summary:"
    echo "------------------------"
    tail -n 30 report.md
fi

echo ""
echo "To serve the model locally, run:"
echo "  cd /workspace/nanochat"
echo "  source .venv/bin/activate"
echo "  python -m scripts.chat_web"
echo ""

# Keep container alive for serving (if needed)
if [ "$KEEP_ALIVE" = "true" ]; then
    echo "KEEP_ALIVE=true - Starting model server..."
    cd /workspace/nanochat
    source .venv/bin/activate
    python -m scripts.chat_web --host 0.0.0.0 --port 8000
else
    echo "Training complete. Container will exit."
    echo "Set KEEP_ALIVE=true to automatically start the model server."
fi
