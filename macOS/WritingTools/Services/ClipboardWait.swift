//
//  ClipboardWait.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 08.08.25.
//

import AppKit

private let logger = AppLogger.logger("ClipboardWait")

@discardableResult
func waitForPasteboardUpdate(
  _ pb: NSPasteboard,
  initialChangeCount: Int,
  timeout: TimeInterval = 0.6,
  pollInterval: Duration = .milliseconds(20)
) async -> Bool {
  let start = Date()
  while pb.changeCount == initialChangeCount && Date().timeIntervalSince(start) < timeout {
    do {
      try await Task.sleep(for: pollInterval)
    } catch {
      logger.debug("Task sleep interrupted: \(error.localizedDescription)")
      return false
    }
  }

  if pb.changeCount == initialChangeCount {
    logger.warning("Clipboard update timeout after \(timeout)s - no change detected")
    return false
  }

  let elapsed = Date().timeIntervalSince(start)
  let formattedElapsed = elapsed.formatted(.number.precision(.fractionLength(3)))
  logger.debug("Clipboard changed after \(formattedElapsed)s")
  return true
}
