import Foundation

@MainActor
protocol AIProvider {

    // Indicates if provider is processing a request
    var isProcessing: Bool { get set }

    // Process text with optional system prompt and images
    func processText(systemPrompt: String?, userPrompt: String, images: [Data], streaming: Bool) async throws -> String

    // Cancel ongoing requests
    func cancel()
}

// MARK: - Retry Utility for API Calls

/// Errors that should be retried (transient network issues)
enum RetryableError {
    /// Check if an error is retryable (transient network or server issues)
    static func isRetryable(_ error: Error) -> Bool {
        // Check for URL errors that are transient
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        // Check for HTTP 5xx errors (server errors are often transient)
        if let nsError = error as NSError? {
            let statusCode = nsError.code
            return (500...599).contains(statusCode)
        }

        return false
    }
}

/// Configuration for retry behavior
struct RetryConfig {
    let maxRetries: Int
    let initialDelay: Duration
    let maxDelay: Duration
    let multiplier: Double

    static let `default` = RetryConfig(
        maxRetries: 3,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(10),
        multiplier: 2.0
    )

    /// No retries - use for providers that handle their own retry logic
    static let none = RetryConfig(
        maxRetries: 0,
        initialDelay: .zero,
        maxDelay: .zero,
        multiplier: 1.0
    )
}

/// Execute an operation with exponential backoff retry
/// - Parameters:
///   - config: Retry configuration
///   - operation: The async operation to retry
/// - Returns: The result of the operation
/// - Throws: The last error if all retries fail
nonisolated func withRetry<T: Sendable>(
    config: RetryConfig = .default,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?
    var currentDelay = config.initialDelay

    for attempt in 0...config.maxRetries {
        do {
            return try await operation()
        } catch {
            lastError = error

            // Don't retry if it's not a retryable error or we've exhausted retries
            if !RetryableError.isRetryable(error) || attempt == config.maxRetries {
                throw error
            }

            // Check for cancellation before waiting
            if Task.isCancelled {
                throw error
            }

            // Wait with exponential backoff
            try? await Task.sleep(for: currentDelay)

            // Increase delay for next attempt, capped at maxDelay
            let nextDelayNanos = Double(currentDelay.components.attoseconds) / 1_000_000_000 * config.multiplier
            let maxDelayNanos = Double(config.maxDelay.components.attoseconds) / 1_000_000_000
            currentDelay = .nanoseconds(Int64(min(nextDelayNanos, maxDelayNanos) * 1_000_000_000))
        }
    }

    throw lastError ?? NSError(domain: "AIProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Retry failed"])
}
