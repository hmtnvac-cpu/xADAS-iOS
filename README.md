# xADAS-iOS

Native iPhone ADAS vision prototype built with SwiftUI and AVFoundation.

## V0.2

- Rear camera live preview
- Landscape-only driving UI
- xADAS HUD overlay shell
- Real camera FPS measurement
- `AVCaptureVideoDataOutput` frame stream
- YUV `CVPixelBuffer` pipeline ready for AI inference
- Live frame resolution/status in HUD
- Road guide + horizon overlay
- CALIBRATE screen
- SETTING screen
- Camera permission configuration

## Build on macOS

This repository includes an XcodeGen `project.yml`.

```bash
brew install xcodegen
cd xADAS-iOS
xcodegen generate
open xADAS-iOS.xcodeproj
```

Then in Xcode:

1. Select the `xADAS-iOS` target.
2. Choose your Apple Developer Team under Signing & Capabilities.
3. Connect an iPhone running iOS 17 or later.
4. Select the iPhone as the run destination and press Run.
5. Allow Camera permission when prompted.

The iOS Simulator does not provide the rear-camera experience required for this prototype, so test on a physical iPhone.

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
Lead Vehicle Detector   ← next
    ↓
Distance / Lane / SuperCombo
```

## Roadmap

1. Camera + overlay ✅
2. Realtime frame pipeline + FPS ✅
3. Lead vehicle detection
4. Distance estimation
5. Lane detection
6. Persistent camera calibration
7. SuperCombo integration
8. FCW / lane departure warnings
9. Video and telemetry logging

## Safety

xADAS-iOS is an experimental computer-vision prototype. It is not a certified ADAS system and must not be relied on as a substitute for attentive driving or vehicle safety systems.
