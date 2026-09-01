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
