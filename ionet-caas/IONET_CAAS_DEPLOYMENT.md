# IONet CaaS Deployment Guide for nanochat Training

This guide walks you through deploying nanochat training on IONet CaaS containers with automatic upload to Cloudflare R2.

## Prerequisites

1. IONet API key set as environment variable: `export IOCLOUD_API_KEY="your-api-key"`
2. Cloudflare R2 bucket configured (see `R2_SETUP_GUIDE.md`)
3. Docker installed for building the container image
4. Docker registry access (Docker Hub, GitHub Container Registry, etc.)

## Quick Start (5 Steps)

### Step 1: Setup Cloudflare R2

Follow the instructions in `R2_SETUP_GUIDE.md` to:
- Create the `llm-exploration` bucket
- Generate API tokens
- Save your credentials

### Step 2: Create GitHub Gist for Training Script

Since the Docker image needs to download the training script, create a GitHub Gist:

1. Go to https://gist.github.com
2. Create a new gist named `train_and_upload.sh`
3. Copy the contents from `train_and_upload.sh` in this repo
4. Create as a **public** gist
5. Click "Raw" and copy the URL (format: `https://gist.githubusercontent.com/...`)

### Step 3: Build and Push Docker Image

Update the Dockerfile to download from your gist:

```dockerfile
# In Dockerfile.training, replace the COPY line with:
RUN curl -L -o /workspace/train_and_upload.sh https://gist.githubusercontent.com/YOUR_USERNAME/YOUR_GIST_ID/raw/train_and_upload.sh
RUN chmod +x /workspace/train_and_upload.sh
```

Build and push the image:

```bash
# Build the image
docker build -f Dockerfile.training -t YOUR_USERNAME/nanochat-training:latest .

# Login to Docker Hub (or your registry)
docker login

# Push the image
docker push YOUR_USERNAME/nanochat-training:latest
```

Alternative: Use GitHub Container Registry (ghcr.io):

```bash
# Login to GitHub Container Registry
echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin

# Build with ghcr.io prefix
docker build -f Dockerfile.training -t ghcr.io/YOUR_USERNAME/nanochat-training:latest .

# Push to ghcr.io
docker push ghcr.io/YOUR_USERNAME/nanochat-training:latest
```

### Step 4: Configure CaaS Deployment

Edit `caas_deployment.json` and update:

1. **Registry Configuration**:
   ```json
   "registry_config": {
     "image_url": "YOUR_USERNAME/nanochat-training:latest",
     "registry_username": "YOUR_DOCKER_USERNAME",
     "registry_secret": "YOUR_DOCKER_PASSWORD"
   }
   ```

2. **R2 Credentials** (from Step 1):
   ```json
   "secret_env_variables": {
     "R2_ACCESS_KEY_ID": "your-r2-access-key",
     "R2_SECRET_ACCESS_KEY": "your-r2-secret-key",
     "R2_ENDPOINT_URL": "https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com",
     "R2_BUCKET_NAME": "llm-exploration"
   }
   ```

3. **Optional - wandb API Key**:
   ```json
   "WANDB_API_KEY": "your-wandb-key"
   ```

### Step 5: Deploy to IONet CaaS

Deploy using curl:

```bash
curl --location 'https://api.io.solutions/enterprise/v1/io-cloud/caas/deploy' \
  --header 'Content-Type: application/json' \
  --header "x-api-key: $IOCLOUD_API_KEY" \
  --data @caas_deployment.json
```

Or using the full expanded version:

```bash
curl --location 'https://api.io.solutions/enterprise/v1/io-cloud/caas/deploy' \
  --header 'Content-Type: application/json' \
  --header "x-api-key: $IOCLOUD_API_KEY" \
  --data '{
    "container_config": {
      "replica_count": 1,
      "env_variables": {
        "WANDB_RUN": "ionet-speedrun",
        "KEEP_ALIVE": "false"
      },
      "secret_env_variables": {
        "R2_ACCESS_KEY_ID": "YOUR_R2_ACCESS_KEY",
        "R2_SECRET_ACCESS_KEY": "YOUR_R2_SECRET_KEY",
        "R2_ENDPOINT_URL": "https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com",
        "R2_BUCKET_NAME": "llm-exploration",
        "WANDB_API_KEY": "YOUR_WANDB_KEY"
      },
      "entrypoint": ["/bin/bash"],
      "args": ["/workspace/train_and_upload.sh"],
      "command": "",
      "traffic_port": 8000
    },
    "registry_config": {
      "image_url": "YOUR_USERNAME/nanochat-training:latest",
      "registry_username": "YOUR_DOCKER_USERNAME",
      "registry_secret": "YOUR_DOCKER_PASSWORD"
    }
  }'
```

## What Happens During Training

The training script will:

1. **Verify Environment** (5 minutes)
   - Check GPU availability (expects 8xH100)
   - Test R2 connectivity with upload/download
   - Verify Python and dependencies

2. **Setup Dependencies** (10-15 minutes)
   - Clone nanochat repository
   - Install uv package manager
   - Install Python dependencies with GPU support
   - Install Rust toolchain for tokenizer

3. **Train Model** (~4 hours)
   - Download and tokenize training data (~24GB)
   - Pretrain d20 model (561M parameters on 11.2B tokens)
   - Midtraining with identity conversations
   - Supervised finetuning
   - Generate evaluation report

4. **Upload to R2** (5-10 minutes)
   - Upload model checkpoints (base.pt, mid.pt, sft.pt)
   - Upload tokenizer.model
   - Upload training report and metadata

5. **Total Time**: ~4.5 hours on 8xH100 node

## Monitoring Training Progress

### Option 1: Use wandb (Recommended)

If you set `WANDB_API_KEY`, you can monitor training in real-time:
- Visit https://wandb.ai
- Look for your project and run name (e.g., "ionet-speedrun")
- View loss curves, metrics, and system stats

### Option 2: Check CaaS Logs

Use IONet CaaS API to fetch logs:

```bash
# Get deployment ID from deploy response
DEPLOYMENT_ID="your-deployment-id"

# Fetch logs
curl --location "https://api.io.solutions/enterprise/v1/io-cloud/caas/deployments/$DEPLOYMENT_ID/logs" \
  --header "x-api-key: $IOCLOUD_API_KEY"
```

### Option 3: Check R2 Bucket

Monitor uploads to your R2 bucket during training:

```bash
aws s3 ls s3://llm-exploration/ --endpoint-url https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com
```

## After Training Completes

### Download the Model

```bash
# List available models
aws s3 ls s3://llm-exploration/ --endpoint-url https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com

# Download a specific model
aws s3 cp s3://llm-exploration/nanochat-d20-20250123-120000/ ./my-model/ \
  --recursive \
  --endpoint-url https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com
```

### Deploy for Inference

To serve the trained model, create a new deployment with `KEEP_ALIVE=true`:

```json
{
  "container_config": {
    "env_variables": {
      "KEEP_ALIVE": "true"
    },
    ...
  }
}
```

This will automatically start the web server on port 8000 after training.

## Troubleshooting

### Out of Memory (OOM) Errors

If you get OOM errors during training, you may not have 8xH100 GPUs. The script automatically detects GPU count, but you can modify training parameters:

1. Edit the gist script
2. Add `--device_batch_size=16` (or 8, 4, 2) to reduce memory usage:
   ```bash
   torchrun --standalone --nproc_per_node=$GPU_COUNT -m scripts.base_train -- --depth=20 --device_batch_size=16 --run=$WANDB_RUN
   ```

### R2 Upload Failures

Check:
1. R2 credentials are correct in `secret_env_variables`
2. Bucket name matches (default: `llm-exploration`)
3. R2 endpoint URL includes your account ID
4. API token has "Admin Read & Write" permissions

### Training Takes Longer Than Expected

Expected times on 8xH100:
- With high-speed interconnect: ~3.5-4 hours
- Without optimized interconnect: ~4.5-5 hours
- On 8xA100: ~5-6 hours
- On fewer GPUs: multiply by GPU reduction factor

### Container Exits Early

Check the logs for errors. Common issues:
1. GPU not available: Verify CaaS container has GPU allocation
2. Dependencies failed: Check internet connectivity for downloads
3. R2 test failed: Verify credentials and bucket configuration

## Cost Estimation

Based on IONet CaaS pricing (example: $3/GPU/hour for H100):

- 8xH100 node for 4.5 hours: 8 × $3 × 4.5 = **$108**
- Storage on R2: ~$0.015/GB/month (~1GB model) = **$0.015/month**
- R2 data transfer: First 10GB free, then $0.09/GB

Total cost per training run: **~$108**

## Environment Variables Reference

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `R2_ACCESS_KEY_ID` | Yes | R2 access key | `abc123...` |
| `R2_SECRET_ACCESS_KEY` | Yes | R2 secret key | `xyz789...` |
| `R2_ENDPOINT_URL` | Yes | R2 endpoint | `https://xyz.r2.cloudflarestorage.com` |
| `R2_BUCKET_NAME` | Yes | R2 bucket name | `llm-exploration` |
| `WANDB_API_KEY` | No | Weights & Biases key | `abc123...` |
| `WANDB_RUN` | No | wandb run name | `ionet-speedrun` |
| `KEEP_ALIVE` | No | Keep container alive to serve model | `true` or `false` |

## Tips for Success

1. **Test R2 first**: Use the test commands in `R2_SETUP_GUIDE.md` to verify connectivity before deploying
2. **Use wandb**: It provides valuable insights into training progress
3. **Start with speedrun**: Don't modify the training parameters for your first run
4. **Monitor costs**: 8xH100 nodes are expensive - set a budget alert
5. **Save everything**: The script uploads everything to R2, so you won't lose data if container stops

## Next Steps

After successful training:
1. Review the `report.md` in your R2 bucket
2. Download the model and test locally
3. Deploy for inference using the model server
4. Try larger models (d26, d32) if budget allows

## Support

For issues:
- nanochat: https://github.com/karpathy/nanochat/issues
- IONet CaaS: Contact IONet support
- This deployment: Check logs and troubleshooting section above
