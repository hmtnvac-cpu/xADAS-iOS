#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/xADAS-iOS/Models"
MODEL_PATH="$MODEL_DIR/YOLOv3TinyInt8LUT.mlmodel"
MODEL_URL="https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel"

mkdir -p "$MODEL_DIR"

if [ -f "$MODEL_PATH" ]; then
  echo "Model already exists: $MODEL_PATH"
  exit 0
fi

echo "Downloading Apple Core ML YOLOv3Tiny Int8 model..."
curl --fail --location --progress-bar "$MODEL_URL" --output "$MODEL_PATH"
echo "Saved: $MODEL_PATH"
