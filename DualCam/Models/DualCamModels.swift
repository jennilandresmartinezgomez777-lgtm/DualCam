import Foundation
import UIKit

enum DualLayoutMode: String, CaseIterable, Identifiable {
    case pip = "PiP"
    case split = "Split"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pip: return "pip.fill"
        case .split: return "rectangle.split.1x2.fill"
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case video = "VIDEO"
    case photo = "PHOTO"

    var id: String { rawValue }
}

enum CameraRole {
    case back
    case front

    var toggled: CameraRole {
        self == .back ? .front : .back
    }
}

enum PiPCorner: CaseIterable {
    case topTrailing
    case topLeading
    case bottomTrailing
    case bottomLeading

    var next: PiPCorner {
        switch self {
        case .topTrailing: return .bottomTrailing
        case .bottomTrailing: return .bottomLeading
        case .bottomLeading: return .topLeading
        case .topLeading: return .topTrailing
        }
    }
}

enum DualCamError: LocalizedError {
    case multiCamNotSupported
    case cameraPermissionDenied
    case deviceUnavailable(String)
    case sessionConfigurationFailed(String)
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .multiCamNotSupported:
            return "Simultaneous dual-camera capture requires an iPhone XS/XR or newer running on a physical device."
        case .cameraPermissionDenied:
            return "Camera access was denied. Enable Camera access in Settings to use DualCam."
        case .deviceUnavailable(let detail):
            return "Camera unavailable: \(detail)"
        case .sessionConfigurationFailed(let detail):
            return "Failed to configure multi-camera session: \(detail)"
        case .recordingFailed(let detail):
            return "Recording error: \(detail)"
        }
    }
}
