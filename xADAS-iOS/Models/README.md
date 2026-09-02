# Models

V0.3 uses Apple's `YOLOv3TinyInt8LUT.mlmodel` for realtime object detection.

Download it before generating the Xcode project:

```bash
bash scripts/download-model.sh
```

Expected local path:

```text
xADAS-iOS/Models/YOLOv3TinyInt8LUT.mlmodel
```

Xcode compiles `.mlmodel` into `.mlmodelc` and bundles it with the app.

V0.9.3 also bundles `UFLDv2TuSimpleRes18Int8.onnx` for real lane recognition.
It is the TuSimple ResNet-18 Ultra-Fast-Lane-Detection V2 model, dynamically
weight-quantized to UInt8 for on-device ONNX Runtime inference. The original
project and weights are MIT licensed by Zequn Qin; see `LICENSE-UFLD-V2.txt`.
