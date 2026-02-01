import Foundation
import AIProxy
import Observation

private let logger = AppLogger.logger("GeminiProvider")

struct GeminiConfig: Codable, Sendable {
    var apiKey: String
    var modelName: String
}

enum GeminiModel: String, CaseIterable {
    case gemmabig = "gemma-3-27b-it"
    case gemmasmall = "gemma-3-4b-it"
    case flashlite = "gemini-flash-lite-latest"
    case flash = "gemini-flash-latest"
    case pro = "gemini-3-pro-latest"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .gemmabig: return "Gemma 3 27b (Very Intelligent | unlimited)"
        case .gemmasmall: return "Gemma 3 4b (Intelligent | unlimited)"
        case .flashlite: return "Gemini Flash Lite Latest (Intelligent | ~20 uses/min)"
        case .flash: return "Gemini Flash Latest (Very Intelligent | ~20 uses/min)"
        case .pro: return "Gemini Pro latest (Peak Intelligence | ~5 uses/min)"
        case .custom: return "Custom"
        }
    }
}

@MainActor
@Observable
final class GeminiProvider: AIProvider {
    var isProcessing = false
    private var config: GeminiConfig
    private var aiProxyService: GeminiService?
    private var currentTask: Task<String, Error>?
    
    init(config: GeminiConfig) {
        self.config = config
        setupAIProxyService()
    }
    
    private func setupAIProxyService() {
        guard !config.apiKey.isEmpty else { return }
        aiProxyService = AIProxy.geminiDirectService(unprotectedAPIKey: config.apiKey)
    }
    
    func processText(systemPrompt: String? = "You are a helpful writing assistant.", userPrompt: String, images: [Data] = [], streaming: Bool = false) async throws -> String {
        isProcessing = true
        defer {
            isProcessing = false
            currentTask = nil
        }

        let config = self.config
        let systemPrompt = systemPrompt
        let userPrompt = userPrompt
        let images = images

        let task = Task.detached(priority: .userInitiated) {
            guard !config.apiKey.isEmpty else {
                throw NSError(domain: "GeminiAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "API key is missing."])
            }

            let geminiService = AIProxy.geminiDirectService(unprotectedAPIKey: config.apiKey)

            let finalPrompt = systemPrompt.map { "\($0)\n\n\(userPrompt)" } ?? userPrompt

            var parts: [GeminiGenerateContentRequestBody.Content.Part] = [.text(finalPrompt)]

            for imageData in images {
                parts.append(.inline(data: imageData, mimeType: "image/jpeg"))
            }

            let requestBody = GeminiGenerateContentRequestBody(
                contents: [.init(parts: parts)],
                safetySettings: [
                    .init(category: .dangerousContent, threshold: .none),
                    .init(category: .harassment, threshold: .none),
                    .init(category: .hateSpeech, threshold: .none),
                    .init(category: .sexuallyExplicit, threshold: .none),
                    .init(category: .civicIntegrity, threshold: .none)
                ]
            )

            do {
                let response = try await geminiService.generateContentRequest(body: requestBody, model: config.modelName, secondsToWait: 60)

                for part in response.candidates?.first?.content?.parts ?? [] {
                    switch part {
                    case .text(let text):
                        return text
                    case .functionCall(name: let functionName, args: let arguments):
                        logger.debug("Function call received: \(functionName) with args: \(arguments ?? [:])")
                    case .inlineData(mimeType: _, base64Data: _):
                        logger.debug("Image generation response part received")
                    }
                }

                throw NSError(domain: "GeminiAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "No text content in response."])

            } catch AIProxyError.unsuccessfulRequest(let statusCode, let responseBody) {
                logger.error("AIProxy error (\(statusCode)): \(responseBody)")
                throw NSError(domain: "GeminiAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "API error: \(responseBody)"])
            } catch {
                logger.error("Gemini request failed: \(error.localizedDescription)")
                throw error
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
}
