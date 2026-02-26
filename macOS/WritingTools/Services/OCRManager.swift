import Foundation
import Vision
import ImageIO

final class OCRManager: Sendable {
    static let shared = OCRManager()
    
    private init() {}
    
    // Extracts text from a single image Data object.
    // Non-cancellation OCR failures return an empty string to preserve prior behavior.
    func extractText(from imageData: Data) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()

            guard let cgImage = Self.decodeCGImage(from: imageData) else { return "" }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // Perform synchronous Vision work off the caller's actor.
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try requestHandler.perform([request])
            } catch {
                return ""
            }

            try Task.checkCancellation()

            guard let observations = request.results else {
                return ""
            }

            let texts = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            return texts.joined(separator: "\n")
        }

        return try await withTaskCancellationHandler(
            operation: {
                try await task.value
            },
            onCancel: {
                task.cancel()
            }
        )
    }

    private static func decodeCGImage(from imageData: Data) -> CGImage? {
        let sourceOptions: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, sourceOptions) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, sourceOptions)
    }

    // Extracts text from an array of images concurrently while preserving order.
    func extractText(from images: [Data]) async throws -> String {
        guard !images.isEmpty else { return "" }

        let results: [(Int, String)] = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, imageData) in images.enumerated() {
                group.addTask {
                    let text = try await self.extractText(from: imageData)
                    return (index, text)
                }
            }

            var collected: [(Int, String)] = []
            collected.reserveCapacity(images.count)
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        return results
            .sorted { $0.0 < $1.0 }
            .map(\.1)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
