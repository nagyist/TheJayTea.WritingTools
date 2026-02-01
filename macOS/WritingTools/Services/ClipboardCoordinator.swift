import AppKit
import ImageIO
import UniformTypeIdentifiers

private let logger = AppLogger.logger("ClipboardCoordinator")

actor ClipboardCoordinator {
    static let shared = ClipboardCoordinator()

    struct CaptureResult {
        let text: String
        let attributedText: NSAttributedString?
        let images: [Data]
        let didChange: Bool
    }

    private var isBusy = false
    private let minCopyDelay: Duration = .milliseconds(50)
    private let pollInterval: Duration = .milliseconds(5)
    private let copyTimeout: TimeInterval = 2.0

    func captureSelection() async -> CaptureResult? {
        guard !isBusy else {
            logger.warning("Capture ignored because clipboard operation is already in progress")
            return nil
        }

        isBusy = true
        defer { isBusy = false }

        let pb = NSPasteboard.general
        let oldChangeCount = pb.changeCount
        let snapshot = pb.createSnapshot()
        defer {
            let restored = pb.restore(snapshot: snapshot)
            if !restored {
                logger.error("Failed to restore clipboard after capture")
            }
        }

        triggerCopy()
        try? await Task.sleep(for: minCopyDelay)

        let didChange = await waitForPasteboardUpdate(
            pb,
            initialChangeCount: oldChangeCount,
            timeout: copyTimeout,
            pollInterval: pollInterval
        )

        guard didChange, pb.changeCount > oldChangeCount else {
            logger.warning("Clipboard did not change after copy trigger")
            return CaptureResult(text: "", attributedText: nil, images: [], didChange: false)
        }

        let images = await readImages(from: pb)
        let attributed = pb.readAttributedSelection()
        let text = attributed?.string ?? pb.string(forType: .string) ?? ""

        return CaptureResult(text: text, attributedText: attributed, images: images, didChange: true)
    }

    private func triggerCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func readImages(from pb: NSPasteboard) async -> [Data] {
        var foundImages: [Data] = []

        let classes = [NSURL.self]
        let imageTypeIdentifiers = [
            UTType.image,
            UTType.png,
            UTType.jpeg,
            UTType.tiff,
            UTType.gif,
        ].map(\.identifier)

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: imageTypeIdentifiers,
        ]

        if let urls = pb.readObjects(forClasses: classes, options: options) as? [URL] {
            let loadedImages = await Self.loadImageData(from: urls)
            if !loadedImages.isEmpty {
                foundImages.append(contentsOf: loadedImages)
            }
        }

        if foundImages.isEmpty {
            let supportedImageTypes: [NSPasteboard.PasteboardType] = [
                NSPasteboard.PasteboardType(UTType.png.identifier),
                NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                NSPasteboard.PasteboardType(UTType.tiff.identifier),
                NSPasteboard.PasteboardType(UTType.gif.identifier),
                NSPasteboard.PasteboardType(UTType.image.identifier),
            ]

            for type in supportedImageTypes {
                if let data = pb.data(forType: type) {
                    foundImages.append(data)
                    logger.debug("Found direct image data of type: \(type.rawValue)")
                    break
                }
            }
        }

        return foundImages
    }

    private static func loadImageData(from urls: [URL]) async -> [Data] {
        await Task.detached(priority: .userInitiated) {
            var images: [Data] = []
            images.reserveCapacity(urls.count)

            for url in urls {
                if let imageData = try? Data(contentsOf: url),
                   isValidImageData(imageData) {
                    images.append(imageData)
                    logger.debug("Loaded image data from file: \(url.lastPathComponent)")
                }
            }
            return images
        }.value
    }

    private static func isValidImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }
}
