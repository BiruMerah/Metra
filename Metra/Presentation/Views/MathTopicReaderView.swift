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
                            ForEach(viewModel.readingRows) { row in
                                // Matching source heading is already the page heading.
                                let reading = row.text
                                let repeatedHeading = row.chunks.contains { topic.headingChunkIDs.contains($0.id) } &&
                                    (reading.trimmingCharacters(in: .whitespacesAndNewlines) == topic.title || topic.titleSource == "source_heading_path")
                                if !repeatedHeading {
                                    if let url = viewModel.imageURL(for: row.contentChunk), let image = UIImage(contentsOfFile: url.path) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 250)
                                            .accessibilityHidden(true)
                                    }
                                    if !reading.isEmpty {
                                        readingText(for: row)
                                            .font(MaterialTopicIndex.headingKinds.contains(row.contentChunk.kind) ? .title3.bold() : .body)
                                            .accessibilityAddTraits(MaterialTopicIndex.headingKinds.contains(row.contentChunk.kind) ? .isHeader : [])
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

    @ViewBuilder
    private func readingText(for row: ReadingPresentation.Row) -> some View {
        if row.contentChunk.kind == "diagram" {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(row.bodyText.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(String(line)).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(String(line).replacingOccurrences(of: "• ", with: ""))
                }
            }
            .accessibilityElement(children: .contain)
        } else if let marker = row.listMarker {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                Text(row.bodyText).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
        } else {
            Text(row.bodyText).accessibilityLabel(row.accessibilityLabel)
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
