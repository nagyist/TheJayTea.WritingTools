import Foundation
import Observation

struct OllamaConfig: Codable, Sendable {
    var baseURL: String         // Accepts either "http://host:11434" or ".../api"
    var model: String
    var keepAlive: String?      // e.g. "5m", "0", "-1"

    // Keep your existing defaults; we normalize below
    static let defaultBaseURL = "http://localhost:11434/api"
    static let defaultModel = "llama3.2"
    static let defaultKeepAlive = "5m"
}

enum OllamaImageMode: String, CaseIterable, Identifiable {
    case ocr
    case ollama

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ocr: return "OCR (Apple Vision)"
        case .ollama: return "Ollama Image Recognition"
        }
    }
}

private struct GenerateChunk: Decodable {
    let response: String?
    let done: Bool?
    let error: String?
}

@MainActor
@Observable
final class OllamaProvider: AIProvider {
    var isProcessing = false
    private var config: OllamaConfig
    private var currentTask: Task<String, Error>?

    init(config: OllamaConfig) {
        self.config = config
    }

    // MARK: - Public

    func processText(
        systemPrompt: String? = "You are a helpful writing assistant.",
        userPrompt: String,
        images: [Data] = [],
        streaming: Bool = false
    ) async throws -> String {
        isProcessing = true
        defer {
            isProcessing = false
            currentTask = nil
        }

        let config = self.config
        let systemPrompt = systemPrompt
        let userPrompt = userPrompt
        let images = images
        let streaming = streaming
        let imageMode = AppSettings.shared.ollamaImageMode

        let task = Task.detached(priority: .userInitiated) {
            // 1) Build combined prompt: system message + user input
            var combinedPrompt = ""

            // Include system prompt if provided
            if let system = systemPrompt, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedPrompt = system + "\n\n"
            }

            // Add user's actual text
            combinedPrompt += userPrompt

            var imagesForOllama: [String] = []

            if !images.isEmpty {
                switch imageMode {
                case .ocr:
                    let ocrText = await OCRManager.shared.extractText(from: images)
                    if !ocrText.isEmpty {
                        combinedPrompt += "\n\nExtracted Text: \(ocrText)"
                    }
                case .ollama:
                    imagesForOllama = images.map { $0.base64EncodedString() }
                }
            }

            // 2) Construct URL
            guard let url = Self.makeEndpointURL(config.baseURL, path: "/generate") else {
                throw Self.makeClientError("Invalid base URL '\(config.baseURL)'. Expected like http://localhost:11434 or http://localhost:11434/api")
            }

            // 3) Build request body - everything in one "prompt" field
            var body: [String: Any] = [
                "model": config.model,
                "prompt": combinedPrompt,
                "stream": streaming
            ]
            if let keepAlive = config.keepAlive, !keepAlive.isEmpty {
                body["keep_alive"] = keepAlive
            }
            if !imagesForOllama.isEmpty {
                body["images"] = imagesForOllama
            }

            let jsonData = try JSONSerialization.data(withJSONObject: body)

            var requestBuilder = URLRequest(url: url)
            requestBuilder.httpMethod = "POST"
            requestBuilder.httpBody = jsonData
            requestBuilder.setValue("application/json", forHTTPHeaderField: "Content-Type")
            requestBuilder.setValue("application/json", forHTTPHeaderField: "Accept")
            requestBuilder.timeoutInterval = 60
            
            // Capture as immutable value for Swift 6 concurrency
            let request = requestBuilder

            // 4) Execute request with retry for transient failures
            return try await withRetry(config: .default) {
                if streaming {
                    return try await Self.performStreaming(request)
                } else {
                    return try await Self.performOneShot(request)
                }
            }
        }
        currentTask = task
        return try await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
    }

    // MARK: - Networking

    nonisolated private static func performOneShot(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeClientError("Invalid response from server.")
        }

        guard http.statusCode == 200 else {
            let message = decodeServerError(from: data)
            throw makeServerError(http.statusCode, message)
        }

        let obj = try JSONDecoder().decode(GenerateChunk.self, from: data)
        if let err = obj.error, !err.isEmpty {
            throw makeServerError(http.statusCode, err)
        }
        guard let text = obj.response else {
            throw makeClientError("Failed to parse response.")
        }
        return text
    }

    nonisolated private static func performStreaming(_ request: URLRequest) async throws -> String {
        var aggregate = ""
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeClientError("Invalid response from server.")
        }

        if http.statusCode != 200 {
            var data = Data()
            for try await byte in stream {
                data.append(byte)
            }
            let message = decodeServerError(from: data)
            throw makeServerError(http.statusCode, message)
        }

        for try await line in stream.lines {
            if Task.isCancelled {
                break
            }
            guard let data = line.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(GenerateChunk.self, from: data) {
                if let t = chunk.response { aggregate += t }
                if chunk.done == true { break }
                if let err = chunk.error, !err.isEmpty {
                    throw makeServerError(500, err)
                }
            }
        }
        return aggregate
    }

    // MARK: - Utilities

    nonisolated private static func makeEndpointURL(_ baseURL: String, path: String) -> URL? {
        // Normalize the base URL properly to avoid double-slashes
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slashes
        while trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }

        // Remove "/api" suffix if present (we'll add it back consistently)
        if trimmed.lowercased().hasSuffix("/api") {
            trimmed = String(trimmed.dropLast(4))
        } else if trimmed.lowercased().hasSuffix("api") && !trimmed.contains("://api") {
            // Handle case where it's just "api" at end without slash (but not part of protocol)
            trimmed = String(trimmed.dropLast(3))
        }

        // Remove any trailing slashes that might have been exposed
        while trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }

        // Build the final URL
        let full = trimmed + "/api" + path
        return URL(string: full)
    }

    nonisolated private static func decodeServerError(from data: Data) -> String {
        if let obj = try? JSONDecoder().decode(GenerateChunk.self, from: data),
           let err = obj.error, !err.isEmpty {
            return err
        }
        return String(data: data, encoding: .utf8) ?? "Unknown server error."
    }

    nonisolated private static func makeClientError(_ message: String) -> NSError {
        NSError(domain: "OllamaClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated private static func makeServerError(_ code: Int, _ message: String) -> NSError {
        let hint: String
        if message.localizedCaseInsensitiveContains("image") && !message.localizedCaseInsensitiveContains("tool") {
            hint = "\nHint: The selected model may not support images. Try OCR mode or a vision model like 'llava'."
        } else {
            hint = ""
        }
        return NSError(domain: "OllamaAPI", code: code, userInfo: [NSLocalizedDescriptionKey: "\(message)\(hint)"])
    }
}
