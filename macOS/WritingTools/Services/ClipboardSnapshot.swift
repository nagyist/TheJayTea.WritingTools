//
//  ClipboardSnapshot.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 17.11.25.
//

import AppKit

private let logger = AppLogger.logger("ClipboardSnapshot")

enum ClipboardRestoreOutcome: Equatable {
    case restored
    case skippedExternalChange(expected: Int, actual: Int)
    case failedWrite
}

/// A comprehensive snapshot of the clipboard state that captures all items and all types
@MainActor
struct ClipboardSnapshot {
    /// All pasteboard items with their data
    private let items: [[NSPasteboard.PasteboardType: Data]]
    
    /// The change count at the time of snapshot
    let changeCount: Int
    
    /// Creates a snapshot of the current clipboard state
    init() {
        let pb = NSPasteboard.general
        self.changeCount = pb.changeCount
        
        var capturedItems: [[NSPasteboard.PasteboardType: Data]] = []
        
        // Capture all items on the pasteboard
        if let pasteboardItems = pb.pasteboardItems {
            for item in pasteboardItems {
                var itemData: [NSPasteboard.PasteboardType: Data] = [:]
                
                // Get all types available for this item
                for type in item.types {
                    // Try to get data for each type
                    if let data = item.data(forType: type) {
                        itemData[type] = data
                    }
                }
                
                if !itemData.isEmpty {
                    capturedItems.append(itemData)
                }
            }
        }
        
        self.items = capturedItems
        
        logger.debug("ClipboardSnapshot: Captured \(capturedItems.count) items with total types: \(capturedItems.flatMap { $0.keys }.count)")
    }
    
    /// Restores this snapshot to the clipboard
    @discardableResult
    func restore() -> Bool {
        let pb = NSPasteboard.general
        let pasteboardItems = makePasteboardItems()

        guard !pasteboardItems.isEmpty else {
            logger.info("ClipboardSnapshot: No items to restore")
            return true
        }

        // Clear only after confirming we have items to write back
        pb.prepareForNewContents(with: [])

        // Write all items to the pasteboard
        let success = pb.writeObjects(pasteboardItems)
        
        if success {
            logger.debug("ClipboardSnapshot: Successfully restored \(pasteboardItems.count) items")
        } else {
            logger.error("ClipboardSnapshot: Failed to restore \(pasteboardItems.count) items")
        }
        return success
    }
    
    /// Restores this snapshot only if the clipboard hasn't been modified by an external source.
    ///
    /// `expectedChangeCount` is the changeCount the pasteboard should have if only our
    /// app has touched it since the snapshot was taken. If the pasteboard's current
    /// changeCount differs, another app (or the user) has written to the clipboard
    /// and we should not overwrite their content.
    ///
    /// Public pasteboard APIs don't provide a cross-process atomic compare-and-swap.
    /// We therefore do all non-essential work before checking `changeCount`, then
    /// perform the check and write back-to-back on the same thread.
    @discardableResult
    func restoreIfUnchanged(expectedChangeCount: Int) -> ClipboardRestoreOutcome {
        let pb = NSPasteboard.general
        let pasteboardItems = makePasteboardItems()

        // Read changeCount immediately before we clear/write to minimise TOCTOU.
        let currentChangeCount = pb.changeCount
        if currentChangeCount != expectedChangeCount {
            logger.info("ClipboardSnapshot: Skipping restore — clipboard was modified externally (expected \(expectedChangeCount), actual \(currentChangeCount))")
            return .skippedExternalChange(expected: expectedChangeCount, actual: currentChangeCount)
        }

        pb.prepareForNewContents(with: [])

        guard !pasteboardItems.isEmpty else {
            logger.info("ClipboardSnapshot: No items to restore")
            return .restored
        }

        let success = pb.writeObjects(pasteboardItems)
        if success {
            logger.debug("ClipboardSnapshot: Successfully restored \(pasteboardItems.count) items")
            return .restored
        } else {
            logger.error("ClipboardSnapshot: Failed to restore \(pasteboardItems.count) items")
            return .failedWrite
        }
    }
    
    /// Returns true if this snapshot contains any data
    var isEmpty: Bool {
        return items.isEmpty
    }
    
    /// Returns the number of items in this snapshot
    var itemCount: Int {
        return items.count
    }
    
    /// Returns a debug description of the snapshot
    var debugDescription: String {
        var description = "ClipboardSnapshot: \(items.count) items\n"
        for (index, item) in items.enumerated() {
            description += "  Item \(index): \(item.keys.map { $0.rawValue }.joined(separator: ", "))\n"
        }
        return description
    }

    private func makePasteboardItems() -> [NSPasteboardItem] {
        items.enumerated().map { (index, itemData) in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in itemData {
                if !pasteboardItem.setData(data, forType: type) {
                    logger.warning("ClipboardSnapshot: setData failed for item \(index), type \(type.rawValue) (\(data.count) bytes)")
                }
            }
            return pasteboardItem
        }
    }
}

@MainActor
extension NSPasteboard {
    /// Convenience method to create and return a snapshot
    func createSnapshot() -> ClipboardSnapshot {
        return ClipboardSnapshot()
    }
    
    /// Convenience method to restore a snapshot
    @discardableResult
    func restore(snapshot: ClipboardSnapshot) -> Bool {
        snapshot.restore()
    }
    
    /// Convenience method to restore a snapshot only if the clipboard hasn't been
    /// modified externally since `expectedChangeCount`.
    @discardableResult
    func restoreIfUnchanged(snapshot: ClipboardSnapshot, expectedChangeCount: Int) -> ClipboardRestoreOutcome {
        snapshot.restoreIfUnchanged(expectedChangeCount: expectedChangeCount)
    }
}
