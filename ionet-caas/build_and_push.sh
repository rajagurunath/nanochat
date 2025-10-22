#!/bin/bash

# Helper script to build and push the training Docker image
# Usage: ./build_and_push.sh YOUR_DOCKERHUB_USERNAME YOUR_GIST_RAW_URL

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 DOCKER_USERNAME GIST_RAW_URL [TAG]"
    echo ""
    echo "Example:"
    echo "  ./build_and_push.sh myusername https://gist.githubusercontent.com/.../train_and_upload_simple.sh"
    echo ""
    echo "Arguments:"
    echo "  DOCKER_USERNAME - Your Docker Hub username"
    echo "  GIST_RAW_URL    - Raw URL of your gist containing train_and_upload_simple.sh"
    echo "  TAG             - Optional image tag (default: latest)"
    exit 1
fi

DOCKER_USERNAME=$1
GIST_URL=$2
TAG=${3:-latest}
IMAGE_NAME="$DOCKER_USERNAME/nanochat-training:$TAG"

echo "=================================="
echo "Building nanochat Training Image"
echo "=================================="
echo "Image: $IMAGE_NAME"
echo "Script: $GIST_URL"
echo "=================================="

# Verify gist URL is accessible
echo "Verifying gist URL..."
if curl -f -s -o /dev/null "$GIST_URL"; then
    echo "✓ Gist URL is accessible"
else
    echo "❌ Cannot access gist URL: $GIST_URL"
    echo "   Make sure the gist is public and the URL is correct"
    exit 1
fi

# Build the image
echo ""
echo "Building Docker image..."
docker build \
    --build-arg SCRIPT_URL="$GIST_URL" \
    -f Dockerfile.training \
    -t "$IMAGE_NAME" \
    .

echo ""
echo "✓ Image built successfully: $IMAGE_NAME"

# Ask to push
read -p "Push image to Docker Hub? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Logging in to Docker Hub..."
    docker login

    echo "Pushing image..."
    docker push "$IMAGE_NAME"

    echo ""
    echo "✓ Image pushed successfully!"
    echo ""
    echo "Use this in your CaaS deployment:"
    echo "  \"image_url\": \"$IMAGE_NAME\""
else
    echo ""
    echo "Skipped push. To push later, run:"
    echo "  docker push $IMAGE_NAME"
fi

echo ""
echo "Next steps:"
echo "1. Update your deploy.json with image_url: \"$IMAGE_NAME\""
echo "2. Add your R2 credentials to secret_env_variables"
echo "3. Deploy to IONet CaaS (see QUICKSTART.md)"
