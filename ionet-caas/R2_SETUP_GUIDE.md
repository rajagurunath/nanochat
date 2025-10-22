# Cloudflare R2 Setup Guide for nanochat Training

## Step 1: Create R2 Bucket

1. Log in to your Cloudflare dashboard
2. Navigate to **R2 Object Storage** from the left sidebar
3. Click **Create bucket**
4. Enter bucket name: `llm-exploration`
5. Choose your preferred location (automatic is fine)
6. Click **Create bucket**

## Step 2: Generate API Tokens

1. In the R2 dashboard, click on **Manage R2 API Tokens**
2. Click **Create API token**
3. Configure the token:
   - **Token name**: `nanochat-training-token`
   - **Permissions**: Select "Admin Read & Write"
   - **Specify bucket(s)**: Select `llm-exploration`
   - **TTL**: Set to your preference (or leave as default)
4. Click **Create API token**

## Step 3: Save Credentials

After creating the token, you'll see three important values:

```bash
# Save these values - you'll need them for the CaaS deployment
Access Key ID: <YOUR_ACCESS_KEY_ID>
Secret Access Key: <YOUR_SECRET_ACCESS_KEY>
Endpoint URL: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

**IMPORTANT**: The Secret Access Key is shown only once. Save it securely!

## Step 4: Get Your Account ID

Your Account ID is visible in the R2 endpoint URL, or you can find it:
1. Go to R2 dashboard
2. Look at the URL or the endpoint information
3. Format: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`

## Step 5: Test Bucket Access (Optional but Recommended)

You can test access using AWS CLI (R2 is S3-compatible):

```bash
# Install AWS CLI
pip install awscli

# Configure credentials
aws configure set aws_access_key_id <YOUR_ACCESS_KEY_ID>
aws configure set aws_secret_access_key <YOUR_SECRET_ACCESS_KEY>

# Test upload
echo "test" > test.txt
aws s3 cp test.txt s3://llm-exploration/ --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com

# Test download
aws s3 ls s3://llm-exploration/ --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

## Environment Variables for CaaS Deployment

You'll need to set these in your CaaS deployment:

```json
"secret_env_variables": {
  "R2_ACCESS_KEY_ID": "<YOUR_ACCESS_KEY_ID>",
  "R2_SECRET_ACCESS_KEY": "<YOUR_SECRET_ACCESS_KEY>",
  "R2_ENDPOINT_URL": "https://<ACCOUNT_ID>.r2.cloudflarestorage.com",
  "R2_BUCKET_NAME": "llm-exploration",
  "WANDB_API_KEY": "<YOUR_WANDB_KEY_IF_USING>"
}
```

## Public Access Configuration (Optional)

If you want to serve the model publicly after training:

1. Go to your bucket settings in R2 dashboard
2. Navigate to **Settings** → **Public access**
3. Click **Allow Access** (if you want public read access)
4. You'll get a public bucket URL like: `https://pub-<hash>.r2.dev`

## Security Best Practices

1. **Limit token scope**: Only grant access to the specific bucket
2. **Use TTL**: Set token expiration if possible
3. **Rotate tokens**: Periodically rotate API tokens
4. **Don't commit credentials**: Never commit tokens to git
5. **Use secret management**: Store tokens in CaaS secret_env_variables
