import SwiftUI
import AVFoundation

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var isCameraFocused: Bool

    @State private var viewModel: CameraViewModel
    let session: AVCaptureSession

    init(viewModel: CameraViewModel, session: AVCaptureSession) {
        _viewModel = State(initialValue: viewModel)
        self.session = session
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: session)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if let url = viewModel.capturedPhotoURL,
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { await viewModel.capturePhoto() }
                }
                .accessibilityElement()
                .accessibilityLabel(viewModel.statusText)
                .accessibilityHint(
                    viewModel.capturedPhotoURL != nil
                    ? "Gunakan tombol Kembali untuk keluar"
                    : viewModel.isReady
                      ? "Ketuk dua kali untuk mengambil foto"
                      : "Ikuti petunjuk hingga lembar siap difoto"
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) {
                    Task { await viewModel.capturePhoto() }
                }
                .accessibilityFocused($isCameraFocused)

            VStack {
                Spacer()

                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.title3)
                        .foregroundStyle(statusColor)

                    Text(viewModel.statusText)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.76))
                        .overlay(Capsule().stroke(statusColor.opacity(0.6), lineWidth: 1.5))
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 44)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
        .task {
            isCameraFocused = true
            await viewModel.prepareCamera()
            isCameraFocused = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, viewModel.cameraPermissionDenied {
                Task { await viewModel.prepareCamera() }
            }
        }
        .onDisappear {
            viewModel.stopCamera()
        }
    }

    private var statusColor: Color {
        if viewModel.cameraPermissionDenied {
            return .red
        }
        
        if viewModel.capturedPhotoURL != nil {
            return .green
        }
        
        if viewModel.isCapturing {
            return .yellow
        }

        switch viewModel.guidanceState {
        case .ready:
            return .green
            
        case .holdStill:
            return .yellow
            
        case .searching:
            return .white.opacity(0.8)
            
        default:
            return .orange
        }
    }

    private var statusIcon: String {
        if viewModel.cameraPermissionDenied {
            return "exclamationmark.circle.fill"
        }
        
        if viewModel.capturedPhotoURL != nil {
            return "checkmark.circle.fill"
        }
        
        if viewModel.isCapturing {
            return "camera.fill"
        }

        switch viewModel.guidanceState {
        case .ready:
            return "checkmark.circle.fill"
            
        case .holdStill:
            return "camera.metering.center.weighted"
            
        case .searching:
            return "viewfinder"
            
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            return "arrow.up.and.down.and.arrow.left.and.right"
            
        case .moveCloser:
            return "arrow.down.right.and.arrow.up.left"
            
        case .moveFarther:
            return "arrow.up.left.and.arrow.down.right"
            
        case .straighten:
            return "rotate.3d"
        }
    }
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

#Preview {
    let cameraService = CameraService(cameraManager: CameraManager())
    CameraView(
        viewModel: CameraViewModel(cameraService: cameraService),
        session: cameraService.previewSession
    )
}
