import Foundation
import AIProxy
import Observation

private let logger = AppLogger.logger("AnthropicProvider")

struct AnthropicConfig: Codable, Sendable {
    var apiKey: String
    var model: String
    
    static let defaultModel = "claude-sonnet-4-5"
}

enum AnthropicModel: String, CaseIterable {
    case claude45Haiku = "claude-haiku-4-5"
    case claude45Sonnet = "claude-sonnet-4-5"
    case claude41Opus = "claude-opus-4-5"
    case custom
    
    var displayName: String {
        switch self {
        case .claude45Haiku: return "Claude 4.5 Haiku (Fastest, Most Affordable)"
        case .claude45Sonnet: return "Claude 4.5 Sonnet (Best Coding Model)"
        case .claude41Opus: return "Claude 4.5 Opus (Most Capable, Expensive)"
        case .custom: return "Custom"
        }
    }
}

@MainActor
@Observable
final class AnthropicProvider: AIProvider {
    var isProcessing = false
    
    private var config: AnthropicConfig
    private var aiProxyService: AnthropicService?
    private var currentTask: Task<String, Error>?
    
    init(config: AnthropicConfig) {
        self.config = config
        setupAIProxyService()
    }
    
    private func setupAIProxyService() {
        guard !config.apiKey.isEmpty else { return }
        aiProxyService = AIProxy.anthropicDirectService(unprotectedAPIKey: config.apiKey)
    }
    
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

        let task = Task.detached(priority: .userInitiated) {
            guard !config.apiKey.isEmpty else {
                throw NSError(
                    domain: "AnthropicAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "API key is missing."]
                )
            }

            let anthropicService = AIProxy.anthropicDirectService(unprotectedAPIKey: config.apiKey)

            let selectedModel = config.model.isEmpty ? AnthropicConfig.defaultModel : config.model

            var contentBlocks: [AnthropicContentBlockParam] = [
                .textBlock(.init(text: userPrompt))
            ]

            for imageData in images {
                let source = AnthropicImageBlockParamSource.base64(
                    data: imageData.base64EncodedString(),
                    mediaType: .jpeg
                )
                contentBlocks.append(.imageBlock(.init(source: source)))
            }

            let messages: [AnthropicMessageParam] = [
                AnthropicMessageParam(
                    content: .blocks(contentBlocks),
                    role: .user
                )
            ]

            let requestBody = AnthropicMessageRequestBody(
                maxTokens: 10000,
                messages: messages,
                model: selectedModel,
                system: systemPrompt.map(AnthropicSystemPrompt.text)
            )

            do {
                if streaming {
                    var compiledResponse = ""
                    let stream = try await anthropicService.streamingMessageRequest(
                        body: requestBody,
                        secondsToWait: 60
                    )

                    for try await event in stream {
                        if Task.isCancelled { break }
                        guard case let .contentBlockDelta(contentBlockDelta) = event else {
                            continue
                        }

                        switch contentBlockDelta.delta {
                        case .textDelta(let textDelta):
                            compiledResponse += textDelta.text
                        case .inputJSONDelta, .citationsDelta, .thinkingDelta, .signatureDelta, .futureProof:
                            continue
                        }
                    }

                    if !compiledResponse.isEmpty {
                        return compiledResponse
                    }
                } else {
                    let response = try await anthropicService.messageRequest(
                        body: requestBody,
                        secondsToWait: 60
                    )
                    var compiledResponse = ""

                    for content in response.content {
                        switch content {
                        case .textBlock(let textBlock):
                            compiledResponse += textBlock.text
                        case .toolUseBlock(let toolUseBlock):
                            logger.debug("Anthropic tool use: \(toolUseBlock.name) input: \(toolUseBlock.input)")
                        case .serverToolUseBlock(let serverToolUseBlock):
                            logger.debug("Anthropic server tool use: \(serverToolUseBlock.name) input: \(serverToolUseBlock.input)")
                        case .thinkingBlock, .redactedThinkingBlock, .webSearchToolResultBlock, .futureProof:
                            continue
                        }
                    }

                    if !compiledResponse.isEmpty {
                        return compiledResponse
                    }
                }

                throw NSError(
                    domain: "AnthropicAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No text content in response."]
                )
            } catch AIProxyError.unsuccessfulRequest(let statusCode, let responseBody) {
                logger.error("Anthropic error (\(statusCode)): \(responseBody)")
                throw NSError(
                    domain: "AnthropicAPI",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "API error: \(responseBody)"]
                )
            } catch {
                logger.error("Anthropic request failed: \(error.localizedDescription)")
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
