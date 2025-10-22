# IONet CaaS nanochat Training - Summary

## What We've Created

A complete solution to train nanochat on IONet CaaS and automatically upload the model to Cloudflare R2. The solution **reuses the official `speedrun.sh`** script and only adds:

1. Pre-flight verification checks (GPU, R2 connectivity, dependencies)
2. Automatic upload to Cloudflare R2 after training
3. Docker containerization for CaaS deployment

## File Overview

### Core Files (Use These)

| File | Purpose | Where to Use |
|------|---------|--------------|
| `train_and_upload_simple.sh` | Training wrapper script | Publish as GitHub Gist |
| `Dockerfile.training` | Docker image definition | Build Docker image |
| `QUICKSTART.md` | Step-by-step deployment guide | Follow for deployment |
| `R2_SETUP_GUIDE.md` | R2 bucket setup instructions | Setup R2 storage |
| `caas_deployment.json` | CaaS deployment config | Template for deployment |
| `build_and_push.sh` | Helper to build Docker image | Run locally to build |

### Reference Files (Optional)

| File | Purpose |
|------|---------|
| `IONET_CAAS_DEPLOYMENT.md` | Detailed deployment guide with troubleshooting |
| `train_and_upload.sh` | Full standalone script (superseded by simple version) |

## Simple Workflow

```
┌─────────────────┐
│  1. Setup R2    │  Create bucket, get credentials (5 min)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 2. Create Gist  │  Publish train_and_upload_simple.sh (2 min)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 3. Build Image  │  Docker build + push (10 min)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 4. Deploy CaaS  │  Single curl command (1 min)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 5. Wait ~4hrs   │  Training runs automatically
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 6. Download     │  Model in R2 bucket
└─────────────────┘
```

## What the Training Script Does

### Phase 1: Verification (2-5 minutes)
- ✓ Check GPU availability
- ✓ Test R2 upload/download
- ✓ Test wandb (if configured)
- ✓ Install AWS CLI and boto3

### Phase 2: Training (~4 hours)
- Clones nanochat from GitHub
- **Runs official `speedrun.sh`** (no modifications!)
- Trains d20 model (561M parameters)
- Generates evaluation report

### Phase 3: Upload (5-10 minutes)
- Uploads model checkpoints to R2
- Uploads tokenizer and training logs
- Creates metadata file

## Key Design Decisions

### ✅ Why We Use speedrun.sh

Instead of reimplementing the training logic, we simply wrap the official `speedrun.sh`:
- **No drift** from upstream nanochat
- **Easy to update** when nanochat improves
- **Reliable** - uses battle-tested code
- **Simple** - just adds R2 upload

### ✅ Why GitHub Gist

The training script is published as a gist because:
- Easy to update without rebuilding Docker image
- Version control built-in
- Simple URL for downloading
- Can iterate quickly on upload logic

### ✅ Why Cloudflare R2

- S3-compatible API (easy to use)
- Cheaper than S3 ($0.015/GB/month vs $0.023/GB/month)
- Free egress bandwidth (vs S3's $0.09/GB)
- Good for storing multiple training runs

## Cost Breakdown

| Item | Cost | Notes |
|------|------|-------|
| Training (8xH100, 4.5hr) | ~$108 | @$3/GPU/hour |
| R2 Storage (1GB) | $0.015/mo | Model checkpoints |
| R2 Bandwidth | Free | First 10GB, then $0.09/GB |
| Docker Registry | Free | Docker Hub free tier |
| **Total per run** | **~$108** | Just training cost |

## Environment Variables

Required for CaaS deployment:

```bash
# R2 Configuration (Required for upload)
R2_ACCESS_KEY_ID="..."
R2_SECRET_ACCESS_KEY="..."
R2_ENDPOINT_URL="https://ACCOUNT_ID.r2.cloudflarestorage.com"
R2_BUCKET_NAME="llm-exploration"

# Optional
WANDB_API_KEY="..."              # For training monitoring
WANDB_RUN="ionet-run-name"       # Custom run name
KEEP_ALIVE="true"                # Start model server after training
```

## Quick Commands Reference

### Setup R2
```bash
# See R2_SETUP_GUIDE.md for detailed instructions
# Test R2 access:
aws s3 ls s3://llm-exploration/ --endpoint-url YOUR_R2_ENDPOINT
```

### Build Docker Image
```bash
# Using helper script:
./build_and_push.sh YOUR_DOCKERHUB_USERNAME YOUR_GIST_RAW_URL

# Or manually:
docker build --build-arg SCRIPT_URL="YOUR_GIST_URL" \
  -f Dockerfile.training -t USERNAME/nanochat-training:latest .
docker push USERNAME/nanochat-training:latest
```

### Deploy to CaaS
```bash
export IOCLOUD_API_KEY="your-api-key"

curl --location 'https://api.io.solutions/enterprise/v1/io-cloud/caas/deploy' \
  --header 'Content-Type: application/json' \
  --header "x-api-key: $IOCLOUD_API_KEY" \
  --data @caas_deployment.json
```

### Check Logs
```bash
curl --location "https://api.io.solutions/enterprise/v1/io-cloud/caas/deployments/DEPLOYMENT_ID/logs" \
  --header "x-api-key: $IOCLOUD_API_KEY"
```

### Download Trained Model
```bash
aws s3 cp s3://llm-exploration/nanochat-d20-TIMESTAMP/ ./my-model/ \
  --recursive --endpoint-url YOUR_R2_ENDPOINT
```

## Testing Before CaaS Deployment

### Test Locally (if you have a GPU)
```bash
cd /path/to/nanochat

# Set R2 credentials
export R2_ACCESS_KEY_ID="..."
export R2_SECRET_ACCESS_KEY="..."
export R2_ENDPOINT_URL="..."
export R2_BUCKET_NAME="llm-exploration"

# Run the wrapper script
bash train_and_upload_simple.sh
```

### Test R2 Connectivity
```bash
# Test upload
echo "test" > test.txt
aws s3 cp test.txt s3://llm-exploration/ --endpoint-url YOUR_R2_ENDPOINT

# Test download
aws s3 ls s3://llm-exploration/ --endpoint-url YOUR_R2_ENDPOINT

# Clean up
aws s3 rm s3://llm-exploration/test.txt --endpoint-url YOUR_R2_ENDPOINT
```

## Customization Options

### Use Different Model Size
Edit the gist to modify `speedrun.sh` parameters:
```bash
# For d26 model (GPT-2 grade, ~$300, ~12 hours)
# Change in train_and_upload_simple.sh:
# - Download 450 data shards instead of 240
# - Add --depth=26 --device_batch_size=16 to training commands
```

### Skip R2 Upload
Don't set R2 environment variables - script will skip upload and warn

### Enable Model Serving
Set `KEEP_ALIVE=true` in deployment - starts web server on port 8000 after training

### Custom wandb Project
Set `WANDB_RUN` to your preferred run name

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Could not download training script" | Verify gist is public and URL is correct |
| "R2 upload test failed" | Check R2 credentials and bucket name |
| "nvidia-smi not found" | Container needs GPU access from CaaS |
| Training OOM | Reduce `--device_batch_size` in speedrun.sh |
| Container exits early | Check CaaS logs for error messages |

## Next Steps After Training

1. **Download model** from R2 bucket
2. **Review report.md** for training metrics
3. **Test locally** using nanochat's chat_web
4. **Deploy for inference** on CaaS with KEEP_ALIVE=true
5. **Try larger models** (d26, d32) if budget allows

## Support & Resources

- **nanochat GitHub**: https://github.com/karpathy/nanochat
- **nanochat Discussions**: https://github.com/karpathy/nanochat/discussions
- **Cloudflare R2 Docs**: https://developers.cloudflare.com/r2/
- **IONet CaaS Docs**: Contact IONet support

## Files You Need to Modify

Before deploying, update these with your values:

1. **Gist**: Create with `train_and_upload_simple.sh` content
2. **Dockerfile.training**: Set `SCRIPT_URL` build arg to your gist URL
3. **caas_deployment.json**:
   - Set R2 credentials in `secret_env_variables`
   - Set `image_url` to your Docker image
   - Set `registry_username` and `registry_secret`

That's it! You're ready to train nanochat on IONet CaaS. See `QUICKSTART.md` for step-by-step instructions.
