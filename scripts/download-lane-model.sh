#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/xADAS-iOS/Models"
MODEL_PATH="$MODEL_DIR/UFLDv2TuSimpleRes18Int8.onnx"

if [[ -s "$MODEL_PATH" ]]; then
  echo "UFLD V2 lane model already present: $MODEL_PATH"
  exit 0
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
SOURCE_MODEL="$TEMP_DIR/ufldv2_tusimple_res18_320x800.onnx"

python3 "$ROOT_DIR/scripts/extract-ufldv2-model.py" "$SOURCE_MODEL"
python3 "$ROOT_DIR/scripts/quantize-ufldv2-model.py" "$SOURCE_MODEL" "$MODEL_PATH"

EXPECTED_SHA256="2bac8d0339a49fc1866acbbc95655f8087cdbafa53b79e793a32a4e7ec374e3f"
ACTUAL_SHA256="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Unexpected UFLD V2 model checksum: $ACTUAL_SHA256" >&2
  exit 1
fi
