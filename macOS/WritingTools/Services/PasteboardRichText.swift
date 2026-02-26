//
//  PasteboardRichText.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 08.08.25.
//

import AppKit
import UniformTypeIdentifiers

extension NSPasteboard {
  @MainActor
  func readAttributedSelection() -> NSAttributedString? {
    // Prefer RTFD (common in Apple apps), then RTF, then HTML
    let flatRtfdType = NSPasteboard.PasteboardType(UTType.flatRTFD.identifier)
    if let flatRtfd = data(forType: flatRtfdType) {
      if let att = try? NSAttributedString(
        data: flatRtfd,
        options: [.documentType: NSAttributedString.DocumentType.rtfd],
        documentAttributes: nil
      ) {
        return att
      }
    }

    if let rtfd = data(forType: .rtfd) {
      if let att = try? NSAttributedString(
        data: rtfd,
        options: [.documentType: NSAttributedString.DocumentType.rtfd],
        documentAttributes: nil
      ) {
        return att
      }
    }

    if let rtf = data(forType: .rtf) {
      if let att = try? NSAttributedString(
        data: rtf,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      ) {
        return att
      }
    }

    if let html = data(forType: .html) {
      // HTML parsing via NSAttributedString uses WebKit internally and can be
      // very slow for large payloads. Cap at 256 KB to prevent UI freezes.
      guard html.count <= 256 * 1024 else { return nil }
      if let att = try? NSAttributedString(
        data: html,
        options: [.documentType: NSAttributedString.DocumentType.html],
        documentAttributes: nil
      ) {
        return att
      }
    }

    return nil
  }
}
