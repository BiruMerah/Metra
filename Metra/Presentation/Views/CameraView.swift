import SwiftUI
import AVFoundation

struct CameraView: View {
    let viewModel: CameraViewModel
    let session: AVCaptureSession
    let onClose: () -> Void

    var body: some View {
        ZStack {
            CameraPreviewView(session: session)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack() {
                Spacer()
            
                
                Text(viewModel.statusText)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
              
                
            }
            .padding(.bottom,100)
        }
        .task {
            await viewModel.prepareCamera()
        }
        .onDisappear {
            viewModel.stopCamera()
        }
    }
}



#Preview {
    let cameraService = CameraService(cameraManager: CameraManager())
    CameraView(
        viewModel: CameraViewModel(cameraService: cameraService),
        session: cameraService.previewSession,
        onClose: {}
    )
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.previewLayer.session = session
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
