import SwiftUI
import UniformTypeIdentifiers

struct MeetingTranscriptionView: View {
    @StateObject private var transcriptionService = MeetingTranscriptionService()
    @State private var selectedFileURL: URL?
    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var exportFormat: ExportFormat = .text
    @State private var showingCopyConfirmation = false
    
    enum ExportFormat: String, CaseIterable {
        case text = "Text (.txt)"
        case json = "JSON (.json)"
        
        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .json: return "json"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue.gradient)
                
                Text("Meeting Transcription")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Upload audio or video files to transcribe")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)
            
            // Main Content Area
            ScrollView {
                VStack(spacing: 24) {
                    // File Selection Card
                    fileSelectionCard
                    
                    // Progress Card (only show when transcribing)
                    if transcriptionService.isTranscribing {
                        progressCard
                    }
                    
                    // Results Card (only show when we have results)
                    if let result = transcriptionService.result {
                        resultsCard(result: result)
                    }
                    
                    // Error Card (only show when we have an error)
                    if let error = transcriptionService.error {
                        errorCard(error: error)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            if showingCopyConfirmation {
                Text("Copied!")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    // MARK: - File Selection Card
    
    private var fileSelectionCard: some View {
        VStack(spacing: 16) {
            if let fileURL = selectedFileURL {
                // Show selected file
                HStack {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(.headline)
                        
                        Text(formatFileSize(fileURL: fileURL))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        selectedFileURL = nil
                        transcriptionService.reset()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                
                // Transcribe Button
                Button(action: {
                    Task {
                        await transcribeFile()
                    }
                }) {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Transcribe")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcriptionService.isTranscribing)
                
            } else {
                // File picker button
                Button(action: {
                    showingFilePicker = true
                }) {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 32))
                        
                        Text("Choose Audio or Video File")
                            .font(.headline)
                        
                        Text("Supported: WAV, MP3, M4A, MP4, MOV, and more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                }
                .buttonStyle(.plain)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundColor(.blue.opacity(0.3))
                )
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [
                .audio,
                .movie,
                .mpeg4Movie,
                UTType(filenameExtension: "wav")!,
                UTType(filenameExtension: "mp3")!,
                UTType(filenameExtension: "m4a")!,
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    selectedFileURL = url
                    transcriptionService.reset()
                }
            case .failure(let error):
                print("File picker error: \(error)")
            }
        }
    }
    
    // MARK: - Progress Card
    
    private var progressCard: some View {
        VStack(spacing: 16) {
            ProgressView(value: transcriptionService.progress)
                .progressViewStyle(.linear)
            
            HStack {
                ProgressView()
                    .controlSize(.small)
                
                Text(transcriptionService.currentStatus)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
    
    // MARK: - Results Card
    
    private func resultsCard(result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with stats
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Complete")
                        .font(.headline)
                    
                    HStack(spacing: 16) {
                        Label("\(String(format: "%.1f", result.duration))s", systemImage: "clock")
                        Label("\(String(format: "%.0f%%", result.confidence * 100))", systemImage: "checkmark.circle")
                        Label("\(String(format: "%.1f", result.duration / result.processingTime))x", systemImage: "speedometer")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 8) {
                    Button(action: {
                        copyToClipboard(result.text)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy to clipboard")
                    
                    Button(action: {
                        showingExportDialog = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export transcription")
                }
                .buttonStyle(.borderless)
            }
            
            Divider()
            
            // Transcription text
            ScrollView {
                Text(result.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .fileExporter(
            isPresented: $showingExportDialog,
            document: TranscriptionDocument(
                result: result,
                format: exportFormat,
                service: transcriptionService
            ),
            contentType: exportFormat == .text ? .plainText : .json,
            defaultFilename: "\(result.fileName)_transcript.\(exportFormat.fileExtension)"
        ) { result in
            switch result {
            case .success:
                print("File exported successfully")
            case .failure(let error):
                print("Export failed: \(error)")
            }
        }
    }
    
    // MARK: - Error Card
    
    private func errorCard(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            
            Text(error)
                .font(.subheadline)
            
            Spacer()
            
            Button("Dismiss") {
                transcriptionService.reset()
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Helper Functions
    
    private func transcribeFile() async {
        guard let fileURL = selectedFileURL else { return }
        
        do {
            _ = try await transcriptionService.transcribeFile(fileURL)
        } catch {
            print("Transcription error: \(error)")
        }
    }
    
    private func formatFileSize(fileURL: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int64 else {
            return "Unknown size"
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        
        withAnimation {
            showingCopyConfirmation = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
    }
}

// MARK: - Document for Export

struct TranscriptionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    
    let result: TranscriptionResult
    let format: MeetingTranscriptionView.ExportFormat
    let service: MeetingTranscriptionService
    
    init(result: TranscriptionResult,
         format: MeetingTranscriptionView.ExportFormat,
         service: MeetingTranscriptionService) {
        self.result = result
        self.format = format
        self.service = service
    }
    
    init(configuration: ReadConfiguration) throws {
        fatalError("Reading not supported")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp.\(format.fileExtension)")
        
        switch format {
        case .text:
            try service.exportToText(result, to: tempURL)
        case .json:
            try service.exportToJSON(result, to: tempURL)
        }
        
        let data = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#Preview {
    MeetingTranscriptionView()
        .frame(width: 700, height: 800)
}

