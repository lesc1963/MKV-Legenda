import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct SubtitleTrack: Identifiable, Hashable {
    let id: Int
    let codec: String
    let language: String
    let title: String

    var displayName: String {
        var parts = ["Faixa \(id)", language.uppercased(), codec]
        if !title.isEmpty { parts.append(title) }
        return parts.joined(separator: "  •  ")
    }
}

private struct ProbeResult: Decodable {
    let streams: [ProbeStream]
}

private struct ProbeStream: Decodable {
    let index: Int
    let codec_name: String?
    let tags: [String: String]?
}

@MainActor
final class ExtractorModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var destinationURL: URL?
    @Published var tracks: [SubtitleTrack] = []
    @Published var selectedTrack: SubtitleTrack?
    @Published var status = "Arraste um arquivo MKV para começar"
    @Published var isWorking = false
    @Published var lastOutputURL: URL?
    @Published var translateToPortuguese = true
    @Published var translationConfiguration: TranslationSession.Configuration?

    private var pendingTranslationURL: URL?

    private var ffmpegURL: URL? { Self.findExecutable(named: "ffmpeg") }
    private var ffprobeURL: URL? { Self.findExecutable(named: "ffprobe") }

    var dependencyAvailable: Bool { ffmpegURL != nil && ffprobeURL != nil }
    var canExtract: Bool {
        inputURL != nil && destinationURL != nil && selectedTrack != nil && !isWorking && dependencyAvailable
    }
    var canTranslateSelectedTrack: Bool {
        guard let selectedTrack else { return false }
        return Self.isConvertibleTextCodec(selectedTrack.codec)
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.title = "Escolher vídeo MKV"
        panel.allowedContentTypes = [UTType(filenameExtension: "mkv") ?? .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, url.pathExtension.lowercased() == "mkv" else { return }
            Task { @MainActor in self?.load(url) }
        }
        return true
    }

    func load(_ url: URL) {
        inputURL = url
        destinationURL = url.deletingLastPathComponent()
        lastOutputURL = nil
        tracks = []
        selectedTrack = nil

        guard dependencyAvailable else {
            status = "O ffmpeg é necessário. Instale-o com: brew install ffmpeg"
            return
        }

        isWorking = true
        status = "Procurando legendas…"
        Task {
            do {
                let found = try await probe(url)
                tracks = found
                selectedTrack = found.first
                status = found.isEmpty ? "Nenhuma faixa de legenda encontrada" : "\(found.count) faixa(s) de legenda encontrada(s)"
            } catch {
                status = "Não foi possível ler o MKV: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Escolher pasta de destino"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }
        destinationURL = panel.url
    }

    func extract() {
        guard let inputURL, let destinationURL, let track = selectedTrack, let ffmpegURL else { return }
        isWorking = true
        lastOutputURL = nil
        status = "Extraindo legenda…"

        Task {
            var translationWasRequested = false
            do {
                let output = uniqueOutputURL(input: inputURL, destination: destinationURL, track: track)
                var arguments = ["-hide_banner", "-loglevel", "error", "-i", inputURL.path, "-map", "0:\(track.id)"]
                if Self.isConvertibleTextCodec(track.codec) {
                    arguments += ["-c:s", "srt"]
                } else {
                    arguments += ["-c", "copy"]
                }
                arguments += [output.path]
                let result = try await Self.run(ffmpegURL, arguments: arguments)
                guard result.status == 0 else {
                    throw NSError(domain: "MKVLegenda", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.errorText])
                }
                if translateToPortuguese && Self.isConvertibleTextCodec(track.codec) {
                    translationWasRequested = true
                    requestTranslation(for: output, sourceCode: track.language)
                } else {
                    lastOutputURL = output
                    status = "Legenda extraída com sucesso"
                }
            } catch {
                status = "Falha na extração: \(error.localizedDescription)"
            }
            if !translationWasRequested { isWorking = false }
        }
    }

    func translatePendingSubtitle(using session: TranslationSession) async {
        guard let sourceURL = pendingTranslationURL else { return }
        do {
            status = "Preparando tradução para português…"
            if session.sourceLanguage != nil {
                try await session.prepareTranslation()
            }

            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let blocks = Self.parseSRT(source)
            guard !blocks.isEmpty else {
                throw NSError(domain: "MKVLegenda", code: 2, userInfo: [NSLocalizedDescriptionKey: "O arquivo SRT está vazio ou não pôde ser interpretado."])
            }

            var translations: [Int: String] = [:]
            let translatable = blocks.enumerated().filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let batchSize = 100

            for start in stride(from: 0, to: translatable.count, by: batchSize) {
                let end = min(start + batchSize, translatable.count)
                let slice = translatable[start..<end]
                let requests = slice.map {
                    TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset))
                }
                let responses = try await session.translations(from: requests)
                for response in responses {
                    if let identifier = response.clientIdentifier, let index = Int(identifier) {
                        translations[index] = response.targetText
                    }
                }
                let percentage = Int((Double(end) / Double(max(translatable.count, 1))) * 100)
                status = "Traduzindo para português… \(percentage)%"
            }

            let translatedSRT = blocks.enumerated().map { index, block in
                block.rendered(with: translations[index] ?? block.text)
            }.joined(separator: "\n\n") + "\n"

            let translatedURL = Self.portugueseOutputURL(for: sourceURL)
            try translatedSRT.write(to: translatedURL, atomically: true, encoding: .utf8)
            lastOutputURL = translatedURL
            status = "Legenda traduzida para português com sucesso"
        } catch {
            lastOutputURL = sourceURL
            let details = error as NSError
            status = "A legenda original foi extraída, mas a tradução falhou: \(error.localizedDescription) [\(details.domain) \(details.code)]"
        }
        pendingTranslationURL = nil
        isWorking = false
    }

    func revealOutput() {
        guard let lastOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
    }

    private func probe(_ url: URL) async throws -> [SubtitleTrack] {
        guard let ffprobeURL else { return [] }
        let result = try await Self.run(ffprobeURL, arguments: [
            "-v", "error", "-select_streams", "s",
            "-show_entries", "stream=index,codec_name:stream_tags=language,title",
            "-of", "json", url.path
        ])
        guard result.status == 0 else {
            throw NSError(domain: "MKVLegenda", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.errorText])
        }
        let decoded = try JSONDecoder().decode(ProbeResult.self, from: result.output)
        return decoded.streams.map {
            SubtitleTrack(
                id: $0.index,
                codec: $0.codec_name ?? "desconhecido",
                language: $0.tags?["language"] ?? "und",
                title: $0.tags?["title"] ?? ""
            )
        }
    }

    private func uniqueOutputURL(input: URL, destination: URL, track: SubtitleTrack) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let language = track.language.replacingOccurrences(of: "/", with: "-")
        let ext = Self.isConvertibleTextCodec(track.codec) ? "srt" : "mks"
        let stem = "\(base).\(language).faixa-\(track.id)"
        var candidate = destination.appendingPathComponent(stem).appendingPathExtension(ext)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private func requestTranslation(for url: URL, sourceCode: String) {
        pendingTranslationURL = url
        status = "Iniciando tradução para português…"
        let sourceLanguage = Self.sourceLanguage(from: sourceCode, subtitleURL: url)
        if var configuration = translationConfiguration {
            if configuration.source == sourceLanguage {
                configuration.invalidate()
                translationConfiguration = configuration
            } else {
                translationConfiguration = TranslationSession.Configuration(
                    source: sourceLanguage,
                    target: Locale.Language(identifier: "pt_BR")
                )
            }
        } else {
            translationConfiguration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: Locale.Language(identifier: "pt_BR")
            )
        }
    }

    nonisolated private static func sourceLanguage(from code: String, subtitleURL: URL) -> Locale.Language? {
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        let languageMap: [String: String] = [
            "eng": "en", "spa": "es", "fra": "fr", "fre": "fr",
            "deu": "de", "ger": "de", "ita": "it", "por": "pt",
            "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh",
            "rus": "ru", "ara": "ar", "hin": "hi", "nld": "nl",
            "dut": "nl", "pol": "pl", "tur": "tr", "ukr": "uk",
            "swe": "sv", "dan": "da", "nor": "no", "fin": "fi"
        ]

        if let mapped = languageMap[normalized] {
            return Locale.Language(identifier: mapped)
        }
        if normalized.count == 2 {
            return Locale.Language(identifier: normalized)
        }

        if let text = try? String(contentsOf: subtitleURL, encoding: .utf8) {
            let sample = parseSRT(text).prefix(30).map(\.text).joined(separator: " ")
            if let detected = NLLanguageRecognizer.dominantLanguage(for: sample), detected != .undetermined {
                return Locale.Language(identifier: detected.rawValue)
            }
        }
        return nil
    }

    private struct SRTBlock {
        let headerLines: [String]
        let text: String

        func rendered(with translatedText: String) -> String {
            (headerLines + [translatedText]).joined(separator: "\n")
        }
    }

    nonisolated private static func parseSRT(_ source: String) -> [SRTBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { rawBlock in
            let lines = rawBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let textStart = timingIndex + 1
            guard textStart < lines.count else { return nil }
            return SRTBlock(
                headerLines: Array(lines[...timingIndex]),
                text: lines[textStart...].joined(separator: "\n")
            )
        }
    }

    nonisolated private static func portugueseOutputURL(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).pt-BR.srt")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base).pt-BR-\(suffix).srt")
            suffix += 1
        }
        return candidate
    }

    nonisolated private static func isConvertibleTextCodec(_ codec: String) -> Bool {
        ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec.lowercased())
    }

    nonisolated private static func findExecutable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func run(_ executable: URL, arguments: [String]) async throws -> (status: Int32, output: Data, errorText: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Erro desconhecido"
                continuation.resume(returning: (process.terminationStatus, output, errorText))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ExtractorModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            header
            dropZone
            if model.inputURL != nil { controls }
            statusBar
        }
        .padding(28)
        .frame(minWidth: 600, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .translationTask(model.translationConfiguration) { session in
            await model.translatePendingSubtitle(using: session)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MKV Legenda").font(.title2.bold())
                Text("Extraia legendas de vídeos MKV").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: model.inputURL == nil ? "arrow.down.doc" : "film.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text(model.inputURL?.lastPathComponent ?? "Arraste o arquivo MKV aqui")
                .font(.headline)
                .lineLimit(1)
            Text("ou").font(.caption).foregroundStyle(.secondary)
            Button("Escolher arquivo…") { model.chooseInput() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7]))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: model.acceptDrop)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Legenda:").frame(width: 70, alignment: .trailing)
                Picker("", selection: $model.selectedTrack) {
                    Text("Selecione uma faixa").tag(SubtitleTrack?.none)
                    ForEach(model.tracks) { track in
                        Text(track.displayName).tag(Optional(track))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text("Destino:").frame(width: 70, alignment: .trailing)
                Text(model.destinationURL?.path ?? "Nenhum")
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Alterar…") { model.chooseDestination() }
            }

            HStack {
                Text("").frame(width: 70)
                Toggle("Traduzir a legenda para português (Brasil)", isOn: $model.translateToPortuguese)
                    .disabled(!model.canTranslateSelectedTrack)
                Spacer()
            }

            if model.selectedTrack != nil && !model.canTranslateSelectedTrack {
                HStack {
                    Text("").frame(width: 70)
                    Text("Legendas baseadas em imagem podem ser extraídas, mas não traduzidas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Extrair legenda") { model.extract() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canExtract)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isWorking { ProgressView().controlSize(.small) }
            Image(systemName: statusIcon).foregroundStyle(statusColor)
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if model.lastOutputURL != nil {
                Button("Mostrar no Finder") { model.revealOutput() }
            }
        }
        .frame(minHeight: 24)
    }

    private var statusIcon: String {
        if model.lastOutputURL != nil { return "checkmark.circle.fill" }
        if !model.dependencyAvailable { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }

    private var statusColor: Color {
        if model.lastOutputURL != nil { return .green }
        if !model.dependencyAvailable { return .orange }
        return .secondary
    }
}

@main
struct MKVLegendaApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
        Settings { EmptyView() }
    }
}
