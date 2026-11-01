//
//  DocumentOpenEventsTests.swift
//  MarkdownEngineTests
//
//  `onDocumentWillOpen` / `onDocumentDidOpen` bracket every rebuild so an embedder
//  knows when the whole document is styled and laid out. A short document reports
//  on the next main-queue turn; a staged open reports once, from its last
//  background turn, after the exact height is measured. An open that a later
//  rebuild or a dismantle abandons never reports.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Document open events", .serialized)
struct DocumentOpenEventsTests {

    private final class Recorder {
        var events: [String] = []
        /// State of the coordinator when `did` fired.
        var stagedAtDid: [Bool] = []
        var estimatedAtDid: [Bool] = []
        var tailFontSizeAtDid: [CGFloat] = []
        var tailLocation = 0
        /// Keeps the scroll view and container alive for the test, and no longer.
        var stack: HeightBehaviorStack?
    }

    private func makeEditor() -> (NativeTextViewCoordinator, NativeTextView, Recorder) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro Text", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let stack = HeightBehaviorStack(viewport: NSSize(width: 600, height: 400))
        stack.textView.isEditable = true
        stack.textView.delegate = coordinator
        coordinator.textView = stack.textView
        let recorder = Recorder()
        recorder.stack = stack
        let textView = stack.textView
        coordinator.onDocumentWillOpen = { view in
            #expect(view === textView)
            recorder.events.append("will")
        }
        coordinator.onDocumentDidOpen = { [weak coordinator] view in
            #expect(view === textView)
            recorder.events.append("did")
            recorder.stagedAtDid.append(coordinator?.stagedStylingActive ?? true)
            recorder.estimatedAtDid.append(textView.contentHeightIsEstimated)
            let storage = textView.textStorage!
            let location = min(recorder.tailLocation, max(0, storage.length - 1))
            recorder.tailFontSizeAtDid.append(
                storage.length == 0 ? 0 : (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            )
        }
        return (coordinator, textView, recorder)
    }

    /// Around 180 kB: a staged head plus several background chunks.
    private func largeDocument(sections: Int = 900) -> String {
        var text = ""
        for index in 0..<sections {
            text += "## Section \(index)\n\n"
            text += "Paragraph \(index) with **bold**, *emphasis*, [link](https://example.invalid/\(index)), and `code`.\n\n"
            text += "- [ ] task \(index)\n- item\n\n> quote \(index)\n\n"
        }
        return text
    }

    /// Start of the heading text of the last section.
    private func lastHeadingText(in text: String) -> Int {
        (text as NSString).range(of: "## Section", options: .backwards).location + 3
    }

    /// Main-queue turns run only while the test suspends.
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 60) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// A few more turns, long enough for a stray second report to show up.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test("a short document reports on the next turn, once")
    func shortDocumentReportsOnTheNextTurn() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: "# Title\n\nShort **text**.\n")
        #expect(recorder.events == ["will"], "nothing reports inside the rebuild")
        #expect(coordinator.stagedStylingActive == false)
        await waitFor { recorder.events.count >= 2 }
        await settle()
        #expect(recorder.events == ["will", "did"])
        #expect(recorder.estimatedAtDid == [false])
    }

    @Test("an empty document reports too")
    func emptyDocumentReports() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: "")
        await waitFor { recorder.events.count >= 2 }
        await settle()
        #expect(recorder.events == ["will", "did"])
    }

    @Test("a staged open reports once, after its last background turn")
    func stagedOpenReportsAtTheEnd() async {
        let (coordinator, textView, recorder) = makeEditor()
        let text = largeDocument()
        recorder.tailLocation = lastHeadingText(in: text)
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        #expect(coordinator.stagedStylingActive, "the fixture is large enough for a staged open")
        #expect(textView.contentHeightIsEstimated)
        let base = coordinator.fontSize
        #expect(
            (textView.textStorage!.attribute(.font, at: recorder.tailLocation, effectiveRange: nil) as? NSFont)?.pointSize == base,
            "the tail still carries base attributes"
        )
        // The first background turns style chunks without reporting.
        try? await Task.sleep(for: .milliseconds(5))
        if coordinator.stagedStylingActive { #expect(recorder.events == ["will"]) }

        await waitFor { !coordinator.stagedStylingActive }
        await settle()
        #expect(recorder.events == ["will", "did"])
        #expect(recorder.stagedAtDid == [false])
        #expect(recorder.estimatedAtDid == [false], "the exact height is measured before the report")
        #expect((recorder.tailFontSizeAtDid.first ?? 0) > base, "the tail is styled when the open reports")
    }

    @Test("a rebuild supersedes a staged open that has not finished")
    func laterRebuildSupersedesStagedOpen() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: largeDocument())
        #expect(coordinator.stagedStylingActive)
        coordinator.rebuildTextStorageAndStyle(textView, from: "# Reloaded\n")
        await waitFor { recorder.events.count >= 3 }
        await settle()
        #expect(recorder.events == ["will", "will", "did"], "only the open that ran to the end reports")
    }

    @Test("a short rebuild superseded on the same turn never reports")
    func supersededShortRebuildDoesNotReport() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: "first\n")
        coordinator.rebuildTextStorageAndStyle(textView, from: "second\n")
        await waitFor { recorder.events.count >= 3 }
        await settle()
        #expect(recorder.events == ["will", "will", "did"])
    }

    @Test("every rebuild of the same view reports again, as after a reload")
    func eachRebuildReportsAgain() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: "# One\n")
        await waitFor { recorder.events.count >= 2 }
        let text = largeDocument()
        recorder.tailLocation = lastHeadingText(in: text)
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        #expect(recorder.events == ["will", "did", "will"])
        await waitFor { recorder.events.count >= 4 }
        await settle()
        #expect(recorder.events == ["will", "did", "will", "did"])
        #expect(recorder.stagedAtDid == [false, false])
    }

    @Test("cancelling a staged open, as dismantling the view does, drops its report")
    func cancelledStagedOpenDoesNotReport() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: largeDocument())
        #expect(coordinator.stagedStylingActive)
        coordinator.cancelStagedStyling()
        await settle()
        #expect(recorder.events == ["will"])
    }

    @Test("cancelling right after a short rebuild drops its report")
    func cancelledShortOpenDoesNotReport() async {
        let (coordinator, textView, recorder) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: "short\n")
        coordinator.cancelStagedStyling()
        await settle()
        #expect(recorder.events == ["will"])
    }
}
