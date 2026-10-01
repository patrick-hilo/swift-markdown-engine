//
//  EditorPublicationEventsTests.swift
//  MarkdownEngineTests
//
//  The display text reaches the `text` binding a main-queue turn after
//  `textDidChange`. `onTextWillPublish` / `onTextDidPublish` bracket that
//  turn so an embedder can count outstanding publications instead of
//  assuming how many turns the engine takes.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Editor publication events")
struct EditorPublicationEventsTests {

    private final class Sink {
        var text: String
        var events: [String] = []
        init(_ text: String) { self.text = text }
    }

    private func makeEditor(_ text: String, rawSourceMode: Bool = false) -> (NativeTextViewCoordinator, NativeTextView, Sink) {
        _ = NSApplication.shared
        let sink = Sink(text)
        let binding = Binding<String>(get: { sink.text }, set: { sink.text = $0; sink.events.append("binding") })
        let coordinator = NativeTextViewCoordinator(
            text: binding, fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        coordinator.configuration = configuration
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.configuration = configuration
        tv.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = tv
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        coordinator.onTextWillPublish = { sink.events.append("will") }
        coordinator.onTextDidPublish = { sink.events.append("did") }
        return (coordinator, tv, sink)
    }

    @Test("will fires inside textDidChange, did fires after the binding is written")
    func pairBracketsTheBindingWrite() async {
        let (_, tv, sink) = makeEditor("alpha")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText(" beta", replacementRange: NSRange(location: 5, length: 0))
        #expect(sink.events == ["will"])
        #expect(sink.text == "alpha")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sink.events == ["will", "binding", "did"])
        #expect(sink.text == "alpha beta")
    }

    @Test("raw source mode publishes through the same pair")
    func rawModeUsesTheSamePair() async {
        let (_, tv, sink) = makeEditor("alpha", rawSourceMode: true)
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(sink.events == ["will"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sink.events == ["will", "binding", "did"])
        #expect(sink.text == "alpha!")
    }

    @Test("a delegate notification without a storage change publishes nothing")
    func noPublicationWithoutChange() async {
        let (coordinator, tv, sink) = makeEditor("alpha")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sink.events.isEmpty)
    }
}
