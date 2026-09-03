#!/bin/bash
set -euo pipefail

MODEL_DIR="xADAS-iOS/Models"
MODEL_PATH="$MODEL_DIR/VNTrafficSign82.onnx"
MODEL_URL="https://huggingface.co/star092304/traffic-sign-detection-vietnam-yolo/resolve/main/best.onnx?download=true"

mkdir -p "$MODEL_DIR"

if [ ! -s "$MODEL_PATH" ]; then
  echo "Downloading 82-class Vietnamese traffic-sign YOLO11 model..."
  curl -L --fail --retry 5 --retry-delay 3 "$MODEL_URL" -o "$MODEL_PATH"
else
  echo "VN82 traffic-sign model already present."
fi

test -s "$MODEL_PATH"
ls -lh "$MODEL_PATH"
