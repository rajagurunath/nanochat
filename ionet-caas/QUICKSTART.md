# Quick Start: Train nanochat on IONet CaaS

Train and deploy nanochat in 3 simple steps. The training uses the official `speedrun.sh` script with automatic upload to Cloudflare R2.

## Prerequisites

- IONet API key
- Cloudflare R2 bucket (see `R2_SETUP_GUIDE.md`)
- GitHub account (for Actions)
- Docker Hub account

## Step 1: Setup R2 Storage (5 minutes)

Follow `R2_SETUP_GUIDE.md` to create your R2 bucket and get credentials. You'll need:
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_ENDPOINT_URL`

## Step 2: Setup GitHub Secrets (2 minutes)

Add these secrets to your GitHub repository:

1. Go to your repo: Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Add:
   - `DOCKERHUB_USERNAME` - Your Docker Hub username
   - `DOCKERHUB_TOKEN` - Your Docker Hub access token

## Step 3: Trigger Docker Build (Automatic)

### Option A: Push to Master (Automatic)

```bash
# Commit and push changes to master branch
git add ionet-caas/
git commit -m "Setup IONet CaaS training"
git push origin master
```

GitHub Actions will automatically build and push the Docker image!

### Option B: Manual Trigger

1. Go to your repo → Actions tab
2. Select "Build and Push nanochat Training Image"
3. Click "Run workflow" → "Run workflow"

### Option C: Local Build

```bash
cd nanochat/ionet-caas

# Build the image
docker build -f Dockerfile.training -t YOUR_USERNAME/nanochat-training:latest .

# Login and push
docker login
docker push YOUR_USERNAME/nanochat-training:latest
```

## Step 4: Deploy to IONet CaaS (1 minute)

Update `caas_deployment.json` with your credentials:

```json
{
  "container_config": {
    "replica_count": 1,
    "env_variables": {
      "WANDB_RUN": "ionet-run-1",
      "KEEP_ALIVE": "false"
    },
    "secret_env_variables": {
      "R2_ACCESS_KEY_ID": "your_r2_access_key",
      "R2_SECRET_ACCESS_KEY": "your_r2_secret_key",
      "R2_ENDPOINT_URL": "https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com",
      "R2_BUCKET_NAME": "llm-exploration",
      "WANDB_API_KEY": "your_wandb_key_optional"
    },
    "entrypoint": ["/bin/bash"],
    "args": ["/workspace/train_and_upload.sh"],
    "command": "",
    "traffic_port": 8000
  },
  "registry_config": {
    "image_url": "YOUR_DOCKERHUB_USERNAME/nanochat-training:latest",
    "registry_username": "YOUR_DOCKERHUB_USERNAME",
    "registry_secret": "YOUR_DOCKERHUB_TOKEN"
  }
}
```

Deploy:

```bash
export IOCLOUD_API_KEY="your-ionet-api-key"

curl --location 'https://api.io.solutions/enterprise/v1/io-cloud/caas/deploy' \
  --header 'Content-Type: application/json' \
  --header "x-api-key: $IOCLOUD_API_KEY" \
  --data @caas_deployment.json
```

## What Happens Next?

1. **Container starts** and runs pre-flight checks (~2 min)
   - Verifies GPU availability
   - Tests R2 upload/download
   - Tests wandb connection (if configured)

2. **Training runs** via official `speedrun.sh` (~4 hours)
   - Clones nanochat repo
   - Installs dependencies
   - Trains d20 model (561M params)
   - Generates evaluation report

3. **Model uploads to R2** (~5 min)
   - Uploads checkpoints (base.pt, mid.pt, sft.pt)
   - Uploads tokenizer
   - Uploads training report and logs

4. **Total time**: ~4.5 hours

## Monitoring Progress

### View Logs via IONet API

```bash
# Get deployment info (save the deployment_id from deploy response)
DEPLOYMENT_ID="your-deployment-id"

curl --location "https://api.io.solutions/enterprise/v1/io-cloud/caas/deployments/$DEPLOYMENT_ID/logs" \
  --header "x-api-key: $IOCLOUD_API_KEY"
```

### View Training on wandb (Optional)

If you set `WANDB_API_KEY`, monitor training at https://wandb.ai

### Check R2 Bucket

```bash
# List models in your bucket
aws s3 ls s3://llm-exploration/ \
  --endpoint-url https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com
```

## After Training

### Download Your Model

```bash
# Find your model (sorted by date)
aws s3 ls s3://llm-exploration/ --endpoint-url YOUR_R2_ENDPOINT

# Download everything
aws s3 cp s3://llm-exploration/nanochat-d20-TIMESTAMP/ ./my-model/ \
  --recursive \
  --endpoint-url YOUR_R2_ENDPOINT
```

### Test Locally

```bash
cd my-model
# You'll need the nanochat repo to run inference
git clone https://github.com/karpathy/nanochat.git
cd nanochat
bash speedrun.sh  # Or set up environment and run chat_web
```

## Costs

Based on IONet pricing (~$3/GPU/hour for H100):

- **Training**: 8 × $3/hr × 4.5hr = **$108**
- **R2 Storage**: ~$0.015/GB/month (model ~1GB)
- **R2 Bandwidth**: First 10GB free

**Total per run: ~$108**

## Troubleshooting

### GitHub Action fails
- Check that `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set
- Verify Docker Hub credentials are correct

### "R2 upload test failed"
- Verify R2 credentials in `secret_env_variables`
- Check bucket name matches (case-sensitive)
- Ensure endpoint URL includes account ID

### "nvidia-smi not found"
- Container doesn't have GPU access
- Verify CaaS deployment requests GPU nodes
- Check IONet GPU availability

### Training OOM errors
- Default is for 8xH100 GPUs
- For fewer/smaller GPUs, modify speedrun.sh to use `--device_batch_size=16` or smaller

## Tips

1. **Test R2 first**: Use AWS CLI to verify R2 access before deploying
2. **Use wandb**: Adds minimal overhead and provides great insights
3. **Start small**: Run the default speedrun first before modifying
4. **Monitor costs**: Set IONet budget alerts for GPU usage
5. **Use GitHub Actions**: Automated builds are easier than local builds

## Files Overview

- `README.md` - Overview and quick reference
- `QUICKSTART.md` - This file
- `SUMMARY.md` - Complete reference
- `train_and_upload_simple.sh` - Training wrapper script
- `Dockerfile.training` - Docker image definition
- `caas_deployment.json` - CaaS deployment template
- `R2_SETUP_GUIDE.md` - R2 setup instructions
- `build_and_push.sh` - Local build helper (optional)

## Support

- nanochat issues: https://github.com/karpathy/nanochat/issues
- IONet CaaS: Contact IONet support
- This guide: Check `IONET_CAAS_DEPLOYMENT.md` for details
