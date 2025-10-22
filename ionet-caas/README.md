# IONet CaaS Training for nanochat

Train nanochat models on IONet CaaS GPU containers with automatic upload to Cloudflare R2.

## Quick Start

### 1. Setup Cloudflare R2 (5 minutes)

See [R2_SETUP_GUIDE.md](R2_SETUP_GUIDE.md) for detailed instructions.

You'll need:
- R2 bucket name (default: `llm-exploration`)
- R2 access key ID
- R2 secret access key
- R2 endpoint URL

### 2. Setup GitHub Secrets

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

- `DOCKERHUB_USERNAME` - Your Docker Hub username
- `DOCKERHUB_TOKEN` - Your Docker Hub access token

### 3. Push to Trigger Build

The GitHub Action will automatically build and push the Docker image when you:
- Push to `master` branch with changes in `ionet-caas/`
- Manually trigger via "Actions" tab → "Build and Push nanochat Training Image" → "Run workflow"

### 4. Deploy to IONet CaaS

Update [caas_deployment.json](caas_deployment.json) with your credentials:

```json
{
  "container_config": {
    "secret_env_variables": {
      "R2_ACCESS_KEY_ID": "your-r2-access-key",
      "R2_SECRET_ACCESS_KEY": "your-r2-secret-key",
      "R2_ENDPOINT_URL": "https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com",
      "R2_BUCKET_NAME": "llm-exploration"
    }
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

## What Happens

1. **Pre-flight checks** (~2 min): Verifies GPU, R2 connectivity, dependencies
2. **Training** (~4 hours): Runs official nanochat `speedrun.sh`
3. **Upload to R2** (~5 min): Uploads model, tokenizer, reports

**Total time**: ~4.5 hours on 8xH100

## Files

| File | Description |
|------|-------------|
| `README.md` | This file |
| `QUICKSTART.md` | Detailed step-by-step guide |
| `SUMMARY.md` | Complete overview and reference |
| `train_and_upload_simple.sh` | Training wrapper script |
| `Dockerfile.training` | Docker image definition |
| `caas_deployment.json` | CaaS deployment template |
| `R2_SETUP_GUIDE.md` | Cloudflare R2 setup instructions |
| `IONET_CAAS_DEPLOYMENT.md` | Detailed deployment guide |
| `build_and_push.sh` | Local build helper script |

## Cost Estimate

- Training: ~$108 (8xH100 × 4.5hr × $3/GPU/hr)
- R2 Storage: ~$0.015/month (1GB model)

## Key Features

✅ Uses official nanochat `speedrun.sh` (no code duplication)
✅ Automatic GitHub Actions Docker build
✅ Pre-flight verification (GPU, R2, wandb)
✅ Automatic R2 upload with metadata
✅ Optional wandb logging
✅ Optional model serving after training

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `R2_ACCESS_KEY_ID` | Yes | R2 access key |
| `R2_SECRET_ACCESS_KEY` | Yes | R2 secret key |
| `R2_ENDPOINT_URL` | Yes | R2 endpoint URL |
| `R2_BUCKET_NAME` | Yes | R2 bucket name |
| `WANDB_API_KEY` | No | Weights & Biases API key |
| `WANDB_RUN` | No | Custom run name |
| `KEEP_ALIVE` | No | Start web server after training |

## Architecture

```
┌─────────────────────┐
│   GitHub Repo       │
│   ionet-caas/       │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  GitHub Actions     │  Builds on push to master
│  Auto Build Docker  │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Docker Hub        │  Stores training image
│   username/         │
│   nanochat-training │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   IONet CaaS        │  Pulls and runs container
│   8xH100 GPU node   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Cloudflare R2       │  Stores trained model
│ llm-exploration/    │
│ nanochat-d20-*      │
└─────────────────────┘
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| GitHub Action fails | Check DOCKERHUB_USERNAME and DOCKERHUB_TOKEN secrets |
| R2 upload fails | Verify R2 credentials and bucket name |
| Training OOM | Reduce `--device_batch_size` in speedrun.sh |
| Container exits early | Check CaaS logs for errors |

## Support

- nanochat: https://github.com/karpathy/nanochat
- This deployment: See QUICKSTART.md and SUMMARY.md
- IONet CaaS: Contact IONet support

## License

MIT (follows nanochat license)
