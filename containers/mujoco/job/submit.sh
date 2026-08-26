#!/bin/bash
# Submit the MuJoCo Shadow Hand sweep to Deadline Cloud.
#
# Unlike the local run in ../templates/, this runs on a fleet: the worker pulls
# the image from ECR and docker-runs one sweep point per task, and job
# attachments carry the frames, MP4 and GIF back.
#
# Required env vars:
#   FARM_ID   — Deadline Cloud farm ID (farm-xxx)
#   QUEUE_ID  — Deadline Cloud queue ID (queue-xxx)
#
# Usage:
#   FARM_ID=farm-xxx QUEUE_ID=queue-xxx ./submit.sh
#
# Optional env vars:
#   AWS_DEFAULT_REGION — region (default: us-west-2)
#   ECR_REGISTRY       — ECR registry URL (auto-detected from the account)
#   DOCKER_REPO        — ECR repository name (default: mujoco-rocky9)
#   DOCKER_TAG         — image tag (default: latest)
#   DURATION           — simulated seconds per combination (default: 2.0)
#   FPS                — rendered frames per simulated second (default: 20.0)
#   MAX_FAILED         — max failed tasks before the job stops (default: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FARM_ID="${FARM_ID:-}"
QUEUE_ID="${QUEUE_ID:-}"
REGION="${AWS_DEFAULT_REGION:-us-west-2}"
ECR_REGISTRY="${ECR_REGISTRY:-}"
DOCKER_REPO="${DOCKER_REPO:-mujoco-rocky9}"
DOCKER_TAG="${DOCKER_TAG:-latest}"
DURATION="${DURATION:-2.0}"
FPS="${FPS:-20.0}"
MAX_FAILED="${MAX_FAILED:-1}"

if [ -z "$FARM_ID" ] || [ -z "$QUEUE_ID" ]; then
  echo "Error: FARM_ID and QUEUE_ID must be set" >&2
  echo "" >&2
  echo "Usage: FARM_ID=farm-xxx QUEUE_ID=queue-xxx ./submit.sh" >&2
  exit 1
fi

# Auto-detect the ECR registry from the caller's account if not given.
if [ -z "$ECR_REGISTRY" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null || true)
  if [ -z "$ACCOUNT_ID" ]; then
    echo "ERROR: could not detect the AWS account. Set ECR_REGISTRY explicitly." >&2
    exit 1
  fi
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

# Fail before submitting if the image is not in ECR — otherwise every task
# fails on `docker pull` after the fleet has already scaled up.
echo "Checking $DOCKER_REPO:$DOCKER_TAG exists in ECR..."
if ! aws ecr describe-images --region "$REGION" \
       --repository-name "$DOCKER_REPO" \
       --image-ids "imageTag=$DOCKER_TAG" >/dev/null 2>&1; then
  echo "ERROR: $ECR_REGISTRY/$DOCKER_REPO:$DOCKER_TAG not found in ECR." >&2
  echo "Build and push it first:" >&2
  echo "    cd ../rocky9-cpu && docker build --platform linux/amd64 -t $DOCKER_REPO ." >&2
  echo "    aws ecr create-repository --repository-name $DOCKER_REPO --region $REGION" >&2
  echo "    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY" >&2
  echo "    docker tag $DOCKER_REPO:latest $ECR_REGISTRY/$DOCKER_REPO:$DOCKER_TAG" >&2
  echo "    docker push $ECR_REGISTRY/$DOCKER_REPO:$DOCKER_TAG" >&2
  exit 1
fi

echo "=============================================="
echo "MuJoCo Shadow Hand Sweep — Job Submission"
echo "=============================================="
echo "Farm:     $FARM_ID"
echo "Queue:    $QUEUE_ID"
echo "Image:    $ECR_REGISTRY/$DOCKER_REPO:$DOCKER_TAG"
echo "Region:   $REGION"
echo "Sweep:    2x2 = 4 tasks, ${DURATION}s per combination at ${FPS} fps"
echo ""

deadline bundle submit "$SCRIPT_DIR" \
    --farm-id "$FARM_ID" \
    --queue-id "$QUEUE_ID" \
    --name "MuJoCo-HandSweep-$(date +%Y%m%d-%H%M%S)" \
    --max-failed-tasks-count "$MAX_FAILED" \
    --max-retries-per-task 1 \
    --yes \
    --parameter "ECR_REGISTRY=$ECR_REGISTRY" \
    --parameter "MUJOCO_REPOSITORY=$DOCKER_REPO" \
    --parameter "MUJOCO_TAG=$DOCKER_TAG" \
    --parameter "AWS_REGION=$REGION" \
    --parameter "Duration=$DURATION" \
    --parameter "Fps=$FPS"

echo ""
echo "Submitted. Watch it with:"
echo "  aws deadline get-job --farm-id $FARM_ID --queue-id $QUEUE_ID --job-id <job-id> --region $REGION"
echo "and pull the output down with:"
echo "  deadline job download-output --farm-id $FARM_ID --queue-id $QUEUE_ID --job-id <job-id>"
