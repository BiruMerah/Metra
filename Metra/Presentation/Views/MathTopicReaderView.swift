import SwiftUI
import UIKit

struct MathTopicReaderView: View {
    @State private var viewModel: MathTopicReaderViewModel
    @AccessibilityFocusState private var headingFocused: Bool

    init(viewModel: MathTopicReaderViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.topic != nil {
                ViewThatFits(in: .horizontal) {
                    HStack { previousButton; Spacer(); nextButton }
                    VStack(alignment: .leading, spacing: 12) { previousButton; nextButton }
                }
                .padding().background(.bar)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = viewModel.errorMessage {
                            ContentUnavailableView("Bacaan belum tersedia", systemImage: "doc.text", description: Text(error))
                        } else if let topic = viewModel.topic {
                            Text(topic.title).font(.title.bold())
                                .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                                .id("topic-heading")
                            ForEach(viewModel.chunks) { chunk in
                                // Matching source heading is already the page heading.
                                let reading = ReadingPresentation.text(for: chunk)
                                let repeatedHeading = topic.headingChunkIDs.contains(chunk.id) &&
                                    reading.trimmingCharacters(in: .whitespacesAndNewlines) == topic.title
                                if !repeatedHeading {
                                    if let url = viewModel.imageURL(for: chunk), let image = UIImage(contentsOfFile: url.path) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 250)
                                            .accessibilityHidden(true)
                                    }
                                    if !reading.isEmpty {
                                        Text(reading).font(MaterialTopicIndex.headingKinds.contains(chunk.kind) ? .title3.bold() : .body)
                                            .accessibilityElement(children: .ignore).accessibilityLabel(reading)
                                            .accessibilityAddTraits(MaterialTopicIndex.headingKinds.contains(chunk.kind) ? .isHeader : [])
                                    }
                                }
                            }
                        }
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: viewModel.topic?.id) { _, _ in
                    headingFocused = false
                    proxy.scrollTo("topic-heading", anchor: .top)
                }
            }
        }
        .navigationTitle("Bacaan").navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load() }
        .task(id: viewModel.topic?.id) {
            // Wait for replacement heading to enter the accessibility tree.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            headingFocused = true
        }
    }

    private var previousButton: some View {
        Button("Topik sebelumnya", systemImage: "chevron.left") { viewModel.previous() }
            .disabled(!viewModel.hasPrevious).frame(minHeight: 44)
    }

    private var nextButton: some View {
        Button("Topik berikutnya", systemImage: "chevron.right") { viewModel.next() }
            .disabled(!viewModel.hasNext).frame(minHeight: 44)
    }
}
