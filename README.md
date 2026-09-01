# xADAS-iOS

Native iPhone ADAS vision prototype built with SwiftUI, AVFoundation, Vision and Core ML.

## V0.3

- Rear camera live preview
- Landscape-only driving UI
- Real camera FPS measurement
- YUV `CVPixelBuffer` frame pipeline
- Apple YOLOv3Tiny Int8 object detector
- Vehicle filtering: car, truck, bus, motorcycle/motorbike
- Lead-vehicle candidate selection around the driving corridor
- Realtime bounding boxes and confidence labels
- Lead vehicle highlighted separately
- AI inference latency shown in HUD
- Road guide + horizon overlay
- CALIBRATE and SETTING screens

## Model setup

The detector code expects Apple's `YOLOv3TinyInt8LUT.mlmodel`. The model is about 8.9 MB and is downloaded directly from Apple's Core ML model hosting.

Run this **before** generating the Xcode project:

```bash
bash scripts/download-model.sh
```

Expected path:

```text
xADAS-iOS/Models/YOLOv3TinyInt8LUT.mlmodel
```

## Build on macOS

```bash
brew install xcodegen
cd xADAS-iOS
bash scripts/download-model.sh
xcodegen generate
open xADAS-iOS.xcodeproj
```

Then in Xcode:

1. Select the `xADAS-iOS` target.
2. Choose your Apple Developer Team under Signing & Capabilities.
3. Connect an iPhone running iOS 17 or later.
4. Select the iPhone as the run destination and press Run.
5. Allow Camera permission when prompted.

Test V0.3 on a physical iPhone. The rear-camera pipeline is the target environment.

## Processing pipeline

```text
Rear Camera
    ↓
AVCaptureSession
    ↓
AVCaptureVideoDataOutput
    ↓
CMSampleBuffer / CVPixelBuffer (YUV)
    ↓
FrameProcessor
    ↓
Vision + Core ML
    ↓
YOLOv3Tiny Int8
    ↓
Vehicle detections
    ↓
Lead vehicle selector
    ↓
ADAS HUD bounding boxes
```

Inference currently runs every second captured frame. This is intentionally conservative for the first on-device test; it can be tuned after measuring sustained FPS and device temperature.

## Roadmap

1. Camera + overlay ✅
2. Realtime frame pipeline + FPS ✅
3. Lead vehicle detection ✅
4. Distance estimation
5. Lane detection
6. Persistent camera calibration
7. SuperCombo integration
8. FCW / lane departure warnings
9. Video and telemetry logging

## Important V0.3 test checks

When testing on the phone, verify:

- `VEHICLE MODEL READY` / `VEHICLE MODEL ACTIVE` appears in the HUD.
- `AI xx.x ms` changes while the camera is running.
- Cars receive bounding boxes.
- The forward candidate is labeled `LEAD`.
- Boxes align correctly with vehicles while the phone is mounted landscape.

If boxes are rotated or mirrored, the next fix is camera/Vision orientation mapping; do not tune distance estimation until detection coordinates are correct.

## Safety

xADAS-iOS is an experimental computer-vision prototype. It is not a certified ADAS system and must not be relied on as a substitute for attentive driving or vehicle safety systems.
