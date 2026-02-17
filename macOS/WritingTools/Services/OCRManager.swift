import Foundation
import Vision
import AppKit

final class OCRManager: Sendable {
    static let shared = OCRManager()
    
    private init() {}
    
    // Extracts text from a single image Data object.
    // Non-cancellation OCR failures return an empty string to preserve prior behavior.
    func extractText(from imageData: Data) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()

            guard let nsImage = NSImage(data: imageData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return "" }

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

    // Extracts text from an array of images.
    func extractText(from images: [Data]) async throws -> String {
        var extractedSegments: [String] = []
        extractedSegments.reserveCapacity(images.count)

        for imageData in images {
            try Task.checkCancellation()
            let text = try await extractText(from: imageData)
            if !text.isEmpty {
                extractedSegments.append(text)
            }
        }

        return extractedSegments
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
