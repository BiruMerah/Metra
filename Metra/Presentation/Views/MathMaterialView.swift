import SwiftUI

/// Material opens on its topic titles, before any reading content.
struct MathMaterialView: View {
    @State private var viewModel: MathMaterialViewModel

    init(viewModel: MathMaterialViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                ContentUnavailableView("Materi belum tersedia", systemImage: "doc", description: Text(error))
            } else if viewModel.isOrganizingTopics {
                ProgressView("Menyusun topik…")
                Button("Baca dengan judul yang tersedia") { viewModel.cancelGrouping() }
            } else if viewModel.material != nil {
                if viewModel.topics.isEmpty {
                    ContentUnavailableView("Belum ada bacaan", systemImage: "doc.text",
                                           description: Text("Materi ini belum memiliki halaman hasil pemrosesan."))
                }
                ForEach(viewModel.topics) { topic in
                    Button { viewModel.openTopic(topic) } label: {
                        Text(topic.title).font(.headline).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                    .accessibilityHint("Membuka bacaan topik")
                }
            } else { ProgressView("Membuka materi…") }
        }
        .navigationTitle(viewModel.material?.title ?? "Materi")
        .task { await viewModel.loadAndOrganize() }
        .alert("Topik belum tersimpan", isPresented: Binding(
            get: { viewModel.topicError != nil }, set: { if !$0 { viewModel.topicError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(viewModel.topicError ?? "") }
    }
}
