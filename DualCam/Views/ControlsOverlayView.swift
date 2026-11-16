import SwiftUI

struct ControlsOverlayView: View {
    @ObservedObject var manager: DualCamSessionManager

    var body: some View {
        VStack {
            topBar
            Spacer()
            if let status = manager.statusMessage {
                Text(status)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale))
            }
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: manager.toggleTorch) {
                Image(systemName: manager.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(manager.isTorchOn ? .yellow : .white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Toggle Flash")

            Spacer()

            if manager.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(formattedDuration(manager.recordingDuration))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.65), in: Capsule())
            }

            Spacer()

            Button(action: manager.toggleLayout) {
                Image(systemName: manager.layoutMode.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Toggle Layout")

            Button(action: manager.swapCameras) {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Swap Cameras")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            // Mode selector
            HStack(spacing: 24) {
                ForEach(CaptureMode.allCases) { mode in
                    Button {
                        guard !manager.isRecording else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            manager.captureMode = mode
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundColor(manager.captureMode == mode ? .yellow : .white.opacity(0.65))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.45), in: Capsule())

            HStack {
                // Last captured preview thumbnail
                Group {
                    if let thumbnail = manager.lastCapturedImage {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                            )
                    } else {
                        Color.clear
                            .frame(width: 48, height: 48)
                    }
                }

                Spacer()

                // Shutter / Record button
                Button(action: manager.handleShutterTap) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 76, height: 76)

                        if manager.captureMode == .video {
                            RoundedRectangle(cornerRadius: manager.isRecording ? 8 : 32)
                                .fill(Color.red)
                                .frame(
                                    width: manager.isRecording ? 32 : 62,
                                    height: manager.isRecording ? 32 : 62
                                )
                                .animation(.spring(response: 0.25), value: manager.isRecording)
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 62, height: 62)
                        }
                    }
                }
                .accessibilityLabel(manager.captureMode == .video ? "Record Video" : "Take Photo")

                Spacer()

                // PiP corner cycle button (only visible in PiP mode)
                if manager.layoutMode == .pip {
                    Button(action: manager.cyclePiPCorner) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Move PiP Window")
                } else {
                    Color.clear
                        .frame(width: 48, height: 48)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
