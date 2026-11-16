import SwiftUI

struct ContentView: View {
    @StateObject private var manager = DualCamSessionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if manager.isMultiCamSupported && manager.errorMessage == nil {
                dualPreviewLayout
                ControlsOverlayView(manager: manager)
            } else {
                unsupportedOrErrorView
            }
        }
        .statusBarHidden(true)
        .onAppear {
            manager.start()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                manager.start()
            case .background:
                manager.stop()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var dualPreviewLayout: some View {
        let primaryLayer = manager.primaryCamera == .back
            ? manager.backPreviewLayer
            : manager.frontPreviewLayer
        let secondaryLayer = manager.primaryCamera == .back
            ? manager.frontPreviewLayer
            : manager.backPreviewLayer

        GeometryReader { geo in
            switch manager.layoutMode {
            case .pip:
                ZStack {
                    CameraPreviewView(previewLayer: primaryLayer)
                        .ignoresSafeArea()

                    CameraPreviewView(previewLayer: secondaryLayer)
                        .frame(width: geo.size.width * 0.30, height: geo.size.width * 0.30 * (16.0 / 9.0))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)
                        .position(pipCenter(in: geo.size))
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3)) {
                                manager.cyclePiPCorner()
                            }
                        }
                }

            case .split:
                VStack(spacing: 2) {
                    CameraPreviewView(previewLayer: primaryLayer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    CameraPreviewView(previewLayer: secondaryLayer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .ignoresSafeArea()
            }
        }
    }

    private func pipCenter(in size: CGSize) -> CGPoint {
        let pipWidth = size.width * 0.30
        let pipHeight = pipWidth * (16.0 / 9.0)
        let marginX: CGFloat = 16 + pipWidth / 2
        let marginTop: CGFloat = 76 + pipHeight / 2
        let marginBottom: CGFloat = size.height - 150 - pipHeight / 2

        switch manager.pipCorner {
        case .topTrailing:
            return CGPoint(x: size.width - marginX, y: marginTop)
        case .topLeading:
            return CGPoint(x: marginX, y: marginTop)
        case .bottomTrailing:
            return CGPoint(x: size.width - marginX, y: marginBottom)
        case .bottomLeading:
            return CGPoint(x: marginX, y: marginBottom)
        }
    }

    private var unsupportedOrErrorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 52))
                .foregroundColor(.yellow)

            Text("DualCam Unavailable")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text(manager.errorMessage ?? "AVCaptureMultiCamSession is not supported on this device.")
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
