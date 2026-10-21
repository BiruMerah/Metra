//
//  ImportDocumentView.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 20/10/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportDocumentView: View {
    // Callback when a file is picked and when the user finishes/cancels
    var onDocumentPicked: ((URL) -> Void)?
    var onClose: (() -> Void)?
    
    @State private var isShowingPicker = false
    @State private var selectedFileURL: URL?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 24) {
            // Header / Description
            VStack(spacing: 8) {
                Text("Pilih Dokumen atau Foto")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Pilih file materi matematika (PDF, gambar, atau teks) dari perangkat Anda.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            
            Spacer()
            
            // Display selected file if user has picked one
            if let selectedFileURL {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    
                    Text(selectedFileURL.lastPathComponent)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Button to open the picker manually
            ActionButton(
                title: selectedFileURL == nil ? "Pilih File" : "Ganti File",
                accessibilityLabel: "Buka pengelola file untuk memilih dokumen atau foto",
                height: 45
            ) {
                isShowingPicker = true
            }
            .padding(.horizontal, 24)
            
            // Button to confirm and proceed once a file is selected
            if let selectedFileURL {
                ActionButton(
                    title: "Gunakan File Ini",
                    accessibilityLabel: "Lanjutkan dengan file yang dipilih",
                    height: 45
                ) {
                    onDocumentPicked?(selectedFileURL)
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 24)
        // 1. File Importer modifier attached to this second screen
        .fileImporter(
            isPresented: $isShowingPicker,
            // Allows both documents (PDF, text) and photos (images) from phone/iCloud
            allowedContentTypes: [.pdf, .image, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        // 2. OPTIONAL: Automatically launch picker when this screen opens
        .onAppear {
            if selectedFileURL == nil {
                isShowingPicker = true
            }
        }
    }
    
    // Handle security-scoped URLs
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Request security-scoped access
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Gagal mengakses file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            self.selectedFileURL = url
            print("Dokumen dipilih: \(url)")
            
        case .failure(let error):
            self.errorMessage = error.localizedDescription
            print("Error memilih dokumen: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ImportDocumentView()
}
