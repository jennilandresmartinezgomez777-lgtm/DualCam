# DualCam

Native iOS dual-camera app built in Swift & SwiftUI using `AVCaptureMultiCamSession` to capture simultaneous front and back camera feeds.

## Features

- **Simultaneous Front & Back Capture** via `AVCaptureMultiCamSession`
- **Live Layouts**:
  - **PiP (Picture-in-Picture)**: Full-screen primary camera with a floating rounded secondary camera window (tap to move between corners)
  - **Split Screen**: 50/50 vertical split view
- **Camera Swap**: Instantly swap which camera is primary/top vs secondary/bottom
- **Dual Video Recording**: Real-time CoreImage compositing via `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` with AAC audio
- **Dual Photo Capture**: Instant composited dual-camera snapshots saved directly to Photos
- **Back Camera Torch**: Toggle flash/torch while previewing or recording

## Requirements

- iOS 16.0+
- Physical iPhone supporting `AVCaptureMultiCamSession` (iPhone XS / XR or newer)
- Xcode 16+

## CI / `.ipa` Build (GitHub Actions)

Every push to `main` (or manual `workflow_dispatch`) runs `.github/workflows/build-ipa.yml` on `macos-15` to:
1. Archive `DualCam.xcodeproj` in `Release` configuration (`generic/platform=iOS`, unsigned)
2. Package `Payload/DualCam.app` into `DualCam.ipa`
3. Upload `DualCam-ipa` as a downloadable workflow artifact

> **Note:** The generated `.ipa` is unsigned (`CODE_SIGNING_ALLOWED=NO`) so it builds without Apple Developer certificates. You can sign & sideload it with AltStore, SideStore, Sideloadly, or `ios-app-signer`, or open `DualCam.xcodeproj` in Xcode to run directly on your iPhone with your Apple ID.
