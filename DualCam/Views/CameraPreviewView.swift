import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        view.attach(previewLayer: previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.attach(previewLayer: previewLayer)
    }
}

final class PreviewHostView: UIView {
    private weak var attachedLayer: AVCaptureVideoPreviewLayer?

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        if attachedLayer !== previewLayer {
            attachedLayer?.removeFromSuperlayer()
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
            attachedLayer = previewLayer
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer?.frame = bounds
        CATransaction.commit()
    }
}
