#!/bin/bash
set -euo pipefail

MODEL_DIR="xADAS-iOS/Models"
MODEL_PATH="$MODEL_DIR/VTSRInt8.onnx"
LABEL_PATH="$MODEL_DIR/VTSRLabelMapping.json"
MODEL_URL="https://huggingface.co/liamxdev/vtsr/resolve/main/vtsr_int8.onnx?download=true"
LABEL_URL="https://huggingface.co/liamxdev/vtsr/resolve/main/label-mapping.json?download=true"

mkdir -p "$MODEL_DIR"

if [ ! -s "$MODEL_PATH" ]; then
  echo "Downloading Vietnamese traffic-sign detector..."
  curl -L --fail --retry 4 --retry-delay 2 "$MODEL_URL" -o "$MODEL_PATH"
else
  echo "VTSR model already present."
fi

if [ ! -s "$LABEL_PATH" ]; then
  echo "Downloading VTSR label mapping..."
  curl -L --fail --retry 4 --retry-delay 2 "$LABEL_URL" -o "$LABEL_PATH"
else
  echo "VTSR label mapping already present."
fi

ls -lh "$MODEL_PATH" "$LABEL_PATH"
