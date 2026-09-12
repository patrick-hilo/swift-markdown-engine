import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Editor release")
@MainActor
struct EditorReleaseTests {
    @Test("Dismantle removes viewport observers even when scroll persistence returns early",
          arguments: [false, true])
    func dismantleRemovesObservers(pendingRestore: Bool) {
        let coordinator = makeCoordinator()
        if pendingRestore {
            coordinator.documentId = "note"
            coordinator.armScrollRestore(for: "note")
        }
        let scrollView = NSScrollView()
        var calls = 0
        coordinator.viewportObservers = [NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil
        ) { _ in calls += 1 }]
        coordinator.stagedStylingActive = true
        coordinator.stagedStylingPending = [NSRange(location: 0, length: 100)]
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        #expect(calls == 1)

        NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: coordinator)
        NativeTextViewWrapper.dismantleNSView(scrollView, coordinator: coordinator)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        #expect(calls == 1)
        #expect(!coordinator.stagedStylingActive)
        #expect(coordinator.stagedStylingPending.isEmpty)
    }

    @Test("Coordinator deinit removes remaining viewport observers")
    func deinitRemovesObservers() {
        let sender = NSView()
        var calls = 0
        weak var released: NativeTextViewCoordinator?
        autoreleasepool {
            let coordinator = makeCoordinator()
            released = coordinator
            coordinator.viewportObservers = [NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: sender, queue: nil
            ) { _ in calls += 1 }]
        }
        #expect(released == nil)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sender)
        #expect(calls == 0)
    }

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(text: .constant(""), fontName: "SF Pro", fontSize: 16,
                                  isWikiLinkActive: .constant(false), onLinkClick: nil,
                                  onInlineSelectionChange: nil)
    }
}
