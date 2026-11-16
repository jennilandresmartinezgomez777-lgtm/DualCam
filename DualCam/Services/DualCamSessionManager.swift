import AVFoundation
import Combine
import Photos
import UIKit

final class DualCamSessionManager: NSObject, ObservableObject {
    // MARK: - Published UI State
    @Published var isSessionRunning = false
    @Published var isMultiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var captureMode: CaptureMode = .video
    @Published var layoutMode: DualLayoutMode = .pip
    @Published var primaryCamera: CameraRole = .back
    @Published var pipCorner: PiPCorner = .topTrailing
    @Published var isTorchOn = false
    @Published var lastCapturedImage: UIImage?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    // MARK: - AVFoundation
    private var multiCamSession: AVCaptureMultiCamSession?
    let backPreviewLayer = AVCaptureVideoPreviewLayer()
    let frontPreviewLayer = AVCaptureVideoPreviewLayer()

    private var backCameraDevice: AVCaptureDevice?
    private var frontCameraDevice: AVCaptureDevice?

    private let backVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // MARK: - Queues & Recording
    private let sessionQueue = DispatchQueue(label: "com.dualcam.sessionQueue")
    private let dataOutputQueue = DispatchQueue(label: "com.dualcam.dataOutputQueue", qos: .userInteractive)
    private let recorder = DualVideoRecorder()

    private var latestBackBuffer: CVPixelBuffer?
    private var latestFrontBuffer: CVPixelBuffer?
    private var recordingTimer: Timer?
    private var isConfigured = false

    // MARK: - Lifecycle
    func start() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async {
                self.isMultiCamSupported = false
                self.errorMessage = DualCamError.multiCamNotSupported.localizedDescription
            }
            return
        }

        requestPermissionsIfNeeded { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.errorMessage = DualCamError.cameraPermissionDenied.localizedDescription
                }
                return
            }

            self.sessionQueue.async {
                if !self.isConfigured {
                    self.configureSession()
                }
                self.startSessionRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.multiCamSession, session.isRunning else { return }
            session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }

    // MARK: - User Actions
    func swapCameras() {
        primaryCamera = primaryCamera.toggled
    }

    func toggleLayout() {
        layoutMode = (layoutMode == .pip) ? .split : .pip
    }

    func cyclePiPCorner() {
        pipCorner = pipCorner.next
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.backCameraDevice,
                  device.hasTorch else { return }

            do {
                try device.lockForConfiguration()
                let newState = !self.isTorchOn
                if newState {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.isTorchOn = newState
                }
            } catch {
                self.showStatus("Torch unavailable")
            }
        }
    }

    func handleShutterTap() {
        switch captureMode {
        case .video:
            toggleRecording()
        case .photo:
            captureDualPhoto()
        }
    }

    // MARK: - Recording
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        dataOutputQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.recorder.startRecording()
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingDuration = 0
                    self.startTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopRecording() {
        DispatchQueue.main.async {
            self.stopTimer()
        }

        dataOutputQueue.async { [weak self] in
            guard let self = self else { return }
            self.recorder.stopRecording { result in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingDuration = 0
                }

                switch result {
                case .success(let fileURL):
                    self.saveVideoToPhotos(url: fileURL)
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func captureDualPhoto() {
        let currentLayout = layoutMode
        let currentCorner = pipCorner
        let currentPrimary = primaryCamera

        dataOutputQueue.async { [weak self] in
            guard let self = self else { return }

            let primaryBuffer = (currentPrimary == .back) ? self.latestBackBuffer : self.latestFrontBuffer
            let secondaryBuffer = (currentPrimary == .back) ? self.latestFrontBuffer : self.latestBackBuffer

            guard let primary = primaryBuffer else {
                self.showStatus("Waiting for camera frames…")
                return
            }

            guard let image = self.recorder.renderPhoto(
                primaryBuffer: primary,
                secondaryBuffer: secondaryBuffer,
                layout: currentLayout,
                pipCorner: currentCorner
            ) else {
                self.showStatus("Failed to capture photo")
                return
            }

            DispatchQueue.main.async {
                self.lastCapturedImage = image
            }

            self.saveImageToPhotos(image)
        }
    }

    // MARK: - Session Configuration
    private func requestPermissionsIfNeeded(completion: @escaping (Bool) -> Void) {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch videoStatus {
        case .authorized:
            requestAudioPermissionIfNeeded {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.requestAudioPermissionIfNeeded {
                        completion(true)
                    }
                } else {
                    completion(false)
                }
            }
        default:
            completion(false)
        }
    }

    private func requestAudioPermissionIfNeeded(completion: @escaping () -> Void) {
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                completion()
            }
        } else {
            completion()
        }
    }

    private func configureSession() {
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        // 1. Back Camera
        guard let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            DispatchQueue.main.async {
                self.errorMessage = DualCamError.deviceUnavailable("Back wide camera").localizedDescription
            }
            return
        }
        self.backCameraDevice = backDevice
        configureBestMultiCamFormat(for: backDevice, maxWidth: 1920)

        guard let backInput = try? AVCaptureDeviceInput(device: backDevice),
              session.canAddInput(backInput) else {
            DispatchQueue.main.async {
                self.errorMessage = DualCamError.sessionConfigurationFailed("Could not add back camera input.").localizedDescription
            }
            return
        }
        session.addInputWithNoConnections(backInput)

        guard let backVideoPort = backInput.ports(
            for: .video,
            sourceDeviceType: backDevice.deviceType,
            sourceDevicePosition: .back
        ).first else {
            DispatchQueue.main.async {
                self.errorMessage = DualCamError.sessionConfigurationFailed("Missing back camera video port.").localizedDescription
            }
            return
        }

        // 2. Front Camera
        guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            DispatchQueue.main.async {
                self.errorMessage = DualCamError.deviceUnavailable("Front camera").localizedDescription
            }
            return
        }
        self.frontCameraDevice = frontDevice
        configureBestMultiCamFormat(for: frontDevice, maxWidth: 1280)

        guard let frontInput = try? AVCaptureDeviceInput(device: frontDevice),
              session.canAddInput(frontInput) else {
            DispatchQueue.main.async {
                self.errorMessage = DualCamError.sessionConfigurationFailed("Could not add front camera input.").localizedDescription
            }
            return
        }
        session.addInputWithNoConnections(frontInput)

        guard let frontVideoPort = frontInput.ports(
            for: .video,
            sourceDeviceType: frontDevice.deviceType,
            sourceDevicePosition: .front
        ).first else {
            DispatchQueue.main.async {
                self.errorMessage = DualCamError.sessionConfigurationFailed("Missing front camera video port.").localizedDescription
            }
            return
        }

        // 3. Preview Layers
        backPreviewLayer.videoGravity = .resizeAspectFill
        backPreviewLayer.setSessionWithNoConnection(session)
        let backPreviewConnection = AVCaptureConnection(inputPort: backVideoPort, videoPreviewLayer: backPreviewLayer)
        if session.canAddConnection(backPreviewConnection) {
            session.addConnection(backPreviewConnection)
        }

        frontPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.setSessionWithNoConnection(session)
        let frontPreviewConnection = AVCaptureConnection(inputPort: frontVideoPort, videoPreviewLayer: frontPreviewLayer)
        if session.canAddConnection(frontPreviewConnection) {
            session.addConnection(frontPreviewConnection)
        }

        // 4. Video Data Outputs
        let pixelFormatSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        backVideoOutput.videoSettings = pixelFormatSettings
        backVideoOutput.alwaysDiscardsLateVideoFrames = true
        backVideoOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        if session.canAddOutput(backVideoOutput) {
            session.addOutputWithNoConnections(backVideoOutput)
            let backOutputConnection = AVCaptureConnection(inputPort: backVideoPort, videoDataOutput: backVideoOutput)
            if backOutputConnection.isVideoOrientationSupported {
                backOutputConnection.videoOrientation = .portrait
            }
            if session.canAddConnection(backOutputConnection) {
                session.addConnection(backOutputConnection)
            }
        }

        frontVideoOutput.videoSettings = pixelFormatSettings
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true
        frontVideoOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        if session.canAddOutput(frontVideoOutput) {
            session.addOutputWithNoConnections(frontVideoOutput)
            let frontOutputConnection = AVCaptureConnection(inputPort: frontVideoPort, videoDataOutput: frontVideoOutput)
            if frontOutputConnection.isVideoOrientationSupported {
                frontOutputConnection.videoOrientation = .portrait
            }
            if frontOutputConnection.isVideoMirroringSupported {
                frontOutputConnection.isVideoMirrored = true
            }
            if session.canAddConnection(frontOutputConnection) {
                session.addConnection(frontOutputConnection)
            }
        }

        // 5. Audio Input & Output (optional if mic permitted)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput),
           let audioPort = audioInput.ports(for: .audio, sourceDeviceType: audioDevice.deviceType, sourceDevicePosition: .unspecified).first {
            session.addInputWithNoConnections(audioInput)
            audioOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutputWithNoConnections(audioOutput)
                let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                if session.canAddConnection(audioConnection) {
                    session.addConnection(audioConnection)
                }
            }
        }

        self.multiCamSession = session
        self.isConfigured = true
    }

    private func configureBestMultiCamFormat(for device: AVCaptureDevice, maxWidth: Int32) {
        let candidates = device.formats.filter { format in
            guard format.isMultiCamSupported else { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports30FPS = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
            return dims.width <= maxWidth && dims.width >= 1280 && supports30FPS
        }

        guard let best = candidates.max(by: { a, b in
            let dimsA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let dimsB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return dimsA.width < dimsB.width
        }) else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            // Fall back to default format
        }
    }

    private func startSessionRunning() {
        guard let session = multiCamSession, !session.isRunning else { return }
        session.startRunning()
        DispatchQueue.main.async {
            self.isSessionRunning = session.isRunning
        }
    }

    // MARK: - Photos Saving
    private func saveImageToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.showStatus("Photos permission denied")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in
                self?.showStatus(success ? "Photo saved to Photos" : "Failed to save photo")
            }
        }
    }

    private func saveVideoToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.showStatus("Photos permission denied")
                try? FileManager.default.removeItem(at: url)
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                try? FileManager.default.removeItem(at: url)
                self?.showStatus(success ? "Video saved to Photos" : "Failed to save video")
            }
        }
    }

    private func showStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.statusMessage == message {
                    self?.statusMessage = nil
                }
            }
        }
    }

    // MARK: - Timer
    private func startTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordingDuration += 0.5
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate
extension DualCamSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            recorder.appendAudioSample(sampleBuffer)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if output === backVideoOutput {
            latestBackBuffer = pixelBuffer
        } else if output === frontVideoOutput {
            latestFrontBuffer = pixelBuffer
        }

        let isPrimaryOutput = (primaryCamera == .back && output === backVideoOutput)
            || (primaryCamera == .front && output === frontVideoOutput)

        guard isPrimaryOutput, recorder.isRecording else { return }

        let secondaryBuffer = (primaryCamera == .back) ? latestFrontBuffer : latestBackBuffer
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        recorder.appendVideoFrame(
            primaryBuffer: pixelBuffer,
            secondaryBuffer: secondaryBuffer,
            presentationTime: timestamp,
            layout: layoutMode,
            pipCorner: pipCorner
        )
    }
}
