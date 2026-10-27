import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MaterialImportView: View {
    @State private var viewModel: MaterialImportViewModel
    @State private var selectedPhotos: [PhotosPickerItem] = []

    init(viewModel: MaterialImportViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        Form {
            Section("Materi baru") {
                TextField("Judul materi (opsional)", text: $viewModel.title)
                    .disabled(viewModel.isBusy || viewModel.hasResultToSave)
                Text("Pilih halaman dari galeri atau ambil foto. Bacaan diproses di iPhone.")
                    .foregroundStyle(.secondary)
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10,
                             selectionBehavior: .ordered, matching: .images,
                             preferredItemEncoding: .current) {
                    Label("Pilih dari galeri", systemImage: "photo.on.rectangle")
                }.disabled(viewModel.isBusy || viewModel.hasResultToSave)
                Button { Task { await viewModel.requestCamera() } } label: {
                    Label("Ambil foto", systemImage: "camera")
                }.disabled(viewModel.isBusy || viewModel.hasResultToSave)
                if viewModel.isLoadingPhotos { ProgressView("Menambahkan halaman…") }
            }
            if !viewModel.pages.isEmpty {
                Section("Halaman (\(viewModel.pages.count))") {
                    ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                        HStack(spacing: 14) {
                            if let image = viewModel.thumbnail(for: page) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: 64, height: 80).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Halaman \(index + 1)").font(.headline)
                                HStack {
                                    Button { viewModel.movePage(id: page.id, offset: -1) } label: {
                                        Image(systemName: "arrow.up")
                                    }.accessibilityLabel("Pindahkan halaman \(index + 1) ke atas").disabled(index == 0)
                                    Button { viewModel.movePage(id: page.id, offset: 1) } label: {
                                        Image(systemName: "arrow.down")
                                    }.accessibilityLabel("Pindahkan halaman \(index + 1) ke bawah").disabled(index == viewModel.pages.count - 1)
                                    Spacer()
                                    Button(role: .destructive) { viewModel.removePage(id: page.id) } label: {
                                        Image(systemName: "trash")
                                    }.accessibilityLabel("Hapus halaman \(index + 1)")
                                }.buttonStyle(.borderless)
                            }
                        }.disabled(viewModel.isBusy || viewModel.hasResultToSave)
                    }
                }
            }
            Section {
                if viewModel.isProcessing {
                    ProgressView(viewModel.progressText)
                        .accessibilityLabel(viewModel.progressText)
                    Button("Batalkan", role: .cancel) { viewModel.cancel() }
                } else {
                    Button(viewModel.hasResultToSave ? "Simpan ulang materi" : "Proses dan simpan materi") {
                        viewModel.processMaterial()
                    }.disabled(viewModel.pages.isEmpty || viewModel.isBusy)
                }
            }
            Section {
                DisclosureGroup("Pengaturan gambar dan diagram") {
                    Label(viewModel.diagramModelIsAvailable ? "Model diagram tersedia" : "Model diagram belum tersedia",
                          systemImage: viewModel.diagramModelIsAvailable ? "checkmark.circle" : "square.and.arrow.down")
                    Text(viewModel.diagramModelStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Tambah materi")
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await viewModel.addPhotos(items); selectedPhotos = [] }
        }
        .sheet(isPresented: $viewModel.showCamera) {
            CameraPicker(onImage: viewModel.addCameraImage, onCancel: {}).ignoresSafeArea()
        }
        .alert("Materi belum selesai", isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(viewModel.errorMessage ?? "") }
        .onDisappear { if viewModel.isProcessing { viewModel.cancel() } }
    }
}
