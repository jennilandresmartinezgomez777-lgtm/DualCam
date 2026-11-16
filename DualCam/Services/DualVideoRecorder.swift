import AVFoundation
import CoreImage
import UIKit

final class DualVideoRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let outputSize = CGSize(width: 1080, height: 1920)

    private(set) var isRecording = false
    private var sessionStarted = false
    private var outputURL: URL?

    func startRecording() throws {
        guard !isRecording else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCam_\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(vInput) else {
            throw DualCamError.recordingFailed("Cannot add video writer input.")
        }
        writer.add(vInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]

        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) {
            writer.add(aInput)
            self.audioInput = aInput
        }

        guard writer.startWriting() else {
            throw DualCamError.recordingFailed(writer.error?.localizedDescription ?? "Unknown writer error.")
        }

        self.assetWriter = writer
        self.videoInput = vInput
        self.pixelBufferAdaptor = adaptor
        self.outputURL = tempURL
        self.sessionStarted = false
        self.isRecording = true
    }

    func appendVideoFrame(
        primaryBuffer: CVPixelBuffer,
        secondaryBuffer: CVPixelBuffer?,
        presentationTime: CMTime,
        layout: DualLayoutMode,
        pipCorner: PiPCorner
    ) {
        guard isRecording,
              let writer = assetWriter,
              let vInput = videoInput,
              let adaptor = pixelBufferAdaptor,
              writer.status == .writing else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }

        guard vInput.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }

        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        guard status == kCVReturnSuccess, let targetBuffer = outputBuffer else { return }

        let compositedImage = makeCompositedImage(
            primaryBuffer: primaryBuffer,
            secondaryBuffer: secondaryBuffer,
            layout: layout,
            pipCorner: pipCorner
        )

        ciContext.render(
            compositedImage,
            to: targetBuffer,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        adaptor.append(targetBuffer, withPresentationTime: presentationTime)
    }

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              sessionStarted,
              let writer = assetWriter,
              let aInput = audioInput,
              writer.status == .writing,
              aInput.isReadyForMoreMediaData else { return }

        aInput.append(sampleBuffer)
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording, let writer = assetWriter, let url = outputURL else {
            completion(.failure(DualCamError.recordingFailed("No active recording.")))
            return
        }

        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            self?.resetState()
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(writer.error ?? DualCamError.recordingFailed("Failed to finalize video.")))
            }
        }
    }

    func renderPhoto(
        primaryBuffer: CVPixelBuffer,
        secondaryBuffer: CVPixelBuffer?,
        layout: DualLayoutMode,
        pipCorner: PiPCorner
    ) -> UIImage? {
        let composited = makeCompositedImage(
            primaryBuffer: primaryBuffer,
            secondaryBuffer: secondaryBuffer,
            layout: layout,
            pipCorner: pipCorner
        )

        let rect = CGRect(origin: .zero, size: outputSize)
        guard let cgImage = ciContext.createCGImage(composited, from: rect) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func resetState() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil
        sessionStarted = false
    }

    // MARK: - CoreImage Compositing

    private func makeCompositedImage(
        primaryBuffer: CVPixelBuffer,
        secondaryBuffer: CVPixelBuffer?,
        layout: DualLayoutMode,
        pipCorner: PiPCorner
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: outputSize)
        let primaryImage = CIImage(cvPixelBuffer: primaryBuffer)

        guard let secondaryBuffer = secondaryBuffer else {
            return aspectFill(image: primaryImage, into: canvasRect)
        }

        let secondaryImage = CIImage(cvPixelBuffer: secondaryBuffer)

        switch layout {
        case .pip:
            let background = aspectFill(image: primaryImage, into: canvasRect)
            let pipRect = calculatePiPRect(corner: pipCorner)
            let overlay = aspectFill(image: secondaryImage, into: pipRect)
            let roundedOverlay = applyRoundedCorners(to: overlay, rect: pipRect, cornerRadius: 28)
            return roundedOverlay.composited(over: background)

        case .split:
            // CoreImage origin is bottom-left: top half is y = height/2 .. height
            let halfHeight = outputSize.height / 2.0
            let topRect = CGRect(x: 0, y: halfHeight, width: outputSize.width, height: halfHeight)
            let bottomRect = CGRect(x: 0, y: 0, width: outputSize.width, height: halfHeight)

            let topImg = aspectFill(image: primaryImage, into: topRect)
            let bottomImg = aspectFill(image: secondaryImage, into: bottomRect)
            let blackBg = CIImage(color: .black).cropped(to: canvasRect)
            return topImg.composited(over: bottomImg.composited(over: blackBg))
        }
    }

    private func calculatePiPRect(corner: PiPCorner) -> CGRect {
        let pipWidth = outputSize.width * 0.30
        let pipHeight = pipWidth * (16.0 / 9.0)
        let marginX: CGFloat = 36
        let marginTop: CGFloat = 140
        let marginBottom: CGFloat = 220

        // CoreImage Y=0 is bottom
        switch corner {
        case .topTrailing:
            return CGRect(
                x: outputSize.width - pipWidth - marginX,
                y: outputSize.height - pipHeight - marginTop,
                width: pipWidth,
                height: pipHeight
            )
        case .topLeading:
            return CGRect(
                x: marginX,
                y: outputSize.height - pipHeight - marginTop,
                width: pipWidth,
                height: pipHeight
            )
        case .bottomTrailing:
            return CGRect(
                x: outputSize.width - pipWidth - marginX,
                y: marginBottom,
                width: pipWidth,
                height: pipHeight
            )
        case .bottomLeading:
            return CGRect(
                x: marginX,
                y: marginBottom,
                width: pipWidth,
                height: pipHeight
            )
        }
    }

    private func aspectFill(image: CIImage, into targetRect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scaleX = targetRect.width / extent.width
        let scaleY = targetRect.height / extent.height
        let scale = max(scaleX, scaleY)

        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale

        let offsetX = targetRect.midX - (scaledWidth / 2.0) - (extent.origin.x * scale)
        let offsetY = targetRect.midY - (scaledHeight / 2.0) - (extent.origin.y * scale)

        let transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)

        return image.transformed(by: transform).cropped(to: targetRect)
    }

    private func applyRoundedCorners(to image: CIImage, rect: CGRect, cornerRadius: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return image
        }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(cornerRadius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")

        guard let mask = filter.outputImage else { return image }

        guard let blend = CIFilter(name: "CIBlendWithAlphaMask") else {
            return image
        }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)

        return blend.outputImage ?? image
    }
}
