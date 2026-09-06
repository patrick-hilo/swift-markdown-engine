//
//  StagedStylingTests.swift
//  MarkdownEngineTests
//
//  A large document opens with only its head styled; the rest is styled and laid
//  out in background turns, pulled forward under the viewport, and moved along by
//  edits. Whatever the order, the attributes must end up exactly as one full
//  restyle would leave them — the oracle every test here compares against.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
private func makeEditor() -> (NativeTextViewCoordinator, NativeTextView, ClampedScrollView) {
    _ = NSApplication.shared   // selection path reads NSApp.currentEvent
    let coordinator = NativeTextViewCoordinator(
        text: .constant(""), fontName: "SF Pro Text", fontSize: 14,
        isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
    )
    let stack = HeightBehaviorStack(viewport: NSSize(width: 600, height: 400))
    stack.textView.isEditable = true
    stack.textView.delegate = coordinator
    coordinator.textView = stack.textView
    return (coordinator, stack.textView, stack.scrollView)
}

/// Around 180 kB: the default head plus four background chunks.
private func largeDocument(sections: Int = 900) -> String {
    var text = ""
    for index in 0..<sections {
        text += "## Section \(index)\n\n"
        text += "Paragraph \(index) with **bold**, *emphasis*, [link](https://example.invalid/\(index)), and `code`.\n\n"
        text += "- [ ] task \(index)\n- item\n\n1. first\n2. second\n\n> quote \(index)\n\n"
        text += "```swift\nlet value\(index) = \(index)\n```\n\n"
        if index % 40 == 0 {
            text += "| a | b |\n| --- | --- |\n| \(index) | x |\n\n"
        }
    }
    return text
}

/// The background turns are main-queue blocks; a main-actor test is itself one, so
/// it has to suspend for them to run.
@MainActor
private func pump(_ coordinator: NativeTextViewCoordinator, timeout: TimeInterval = 60) async {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while coordinator.stagedStylingActive, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let sampleStride = 11

private func expectSameStyle(
    _ staged: [[NSAttributedString.Key: AnyHashable]],
    _ reference: [[NSAttributedString.Key: AnyHashable]],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard staged.count == reference.count else {
        Issue.record("sample counts differ: \(staged.count) vs \(reference.count)", sourceLocation: sourceLocation)
        return
    }
    if let index = zip(staged, reference).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
        Issue.record("attributes differ at character \(index * sampleStride): staged=\(staged[index]) reference=\(reference[index])",
                     sourceLocation: sourceLocation)
    }
}

/// Font, colour and paragraph attributes at sampled positions; attachments and images
/// are rendered per pass and never compare equal.
private func styleSamples(_ storage: NSAttributedString, stride: Int = sampleStride) -> [[NSAttributedString.Key: AnyHashable]] {
    var samples: [[NSAttributedString.Key: AnyHashable]] = []
    var index = 0
    while index < storage.length {
        var sample: [NSAttributedString.Key: AnyHashable] = [:]
        for (key, value) in storage.attributes(at: index, effectiveRange: nil) {
            if value is NSTextAttachment || value is NSImage { continue }
            if let hashable = value as? AnyHashable { sample[key] = hashable }
        }
        samples.append(sample)
        index += stride
    }
    return samples
}

@MainActor
private func fullRestyleSamples(_ coordinator: NativeTextViewCoordinator, _ textView: NativeTextView) -> [[NSAttributedString.Key: AnyHashable]] {
    let length = (textView.string as NSString).length
    coordinator.restyleParagraphs([NSRange(location: 0, length: length)], in: textView)
    return styleSamples(textView.textStorage!)
}

private func headingLocation(in text: String, fraction: Double) -> Int {
    let ns = text as NSString
    let from = Int(Double(ns.length) * fraction)
    let found = ns.range(of: "\n## Section", options: [], range: NSRange(location: from, length: ns.length - from))
    return found.location + 1
}

/// Character offset of the layout fragment at the top of the viewport.
@MainActor
private func topVisibleLocation(of textView: NativeTextView) -> Int? {
    guard let tlm = textView.textLayoutManager else { return nil }
    let y = textView.visibleRect.minY - textView.textContainerOrigin.y
    guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return nil }
    return tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
}

private func fontSize(_ storage: NSTextStorage, at location: Int) -> CGFloat {
    (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
}

@MainActor
@Suite("Staged styling of a large document", .serialized)
struct StagedStylingTests {

    @Test func planCutsAtBlockEndsAndCoversTheDocument() {
        let blocks = (0..<100).map { Block(kind: .paragraph, range: NSRange(location: $0 * 1_000, length: 1_000)) }
        let plan = NativeTextViewCoordinator.stagedStylingPlan(blocks: blocks, length: 100_000)!
        #expect(plan.initial == NSRange(location: 0, length: 24_000))
        #expect(plan.pending.first?.location == 24_000)
        var cursor = 24_000
        for chunk in plan.pending {
            #expect(chunk.location == cursor)
            #expect(chunk.location % 1_000 == 0 && NSMaxRange(chunk) % 1_000 == 0, "cuts fall on block ends")
            cursor = NSMaxRange(chunk)
        }
        #expect(cursor == 100_000)
        #expect(plan.pending.count == 3)
        #expect(NativeTextViewCoordinator.stagedStylingPlan(blocks: blocks, length: 24_000) == nil)
    }

    @Test func rebuildStylesTheHeadFirstAndTheRestInTheBackground() async {
        let (coordinator, textView, _) = makeEditor()
        let text = largeDocument()
        let base = coordinator.fontSize

        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        let storage = textView.textStorage!
        let early = headingLocation(in: text, fraction: 0.0)
        let late = headingLocation(in: text, fraction: 0.9)
        #expect(coordinator.stagedStylingActive)
        #expect(coordinator.stagedStylingPending.count >= 4)
        #expect(fontSize(storage, at: early + 3) > base, "the head is styled before the first frame")
        #expect(fontSize(storage, at: late + 3) == base, "the tail still carries base attributes")
        #expect(textView.pendingFullLayoutMeasure == false)

        await pump(coordinator)
        #expect(coordinator.stagedStylingActive == false)
        #expect(coordinator.stagedStylingPending.isEmpty)
        #expect(fontSize(storage, at: late + 3) > base)
        let staged = styleSamples(storage)
        expectSameStyle(staged, fullRestyleSamples(coordinator, textView))
    }

    @Test func scrollingPullsTheChunksUnderTheViewportForward() async {
        let (coordinator, textView, scrollView) = makeEditor()
        let text = largeDocument()
        let base = coordinator.fontSize
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        textView.recalcOverscroll(for: scrollView, debugTag: "open")
        let pendingBefore = coordinator.stagedStylingPending.count
        let firstChunk = coordinator.stagedStylingPending.first
        #expect(pendingBefore >= 4)

        // Scroll deep into the document, past the first background chunks.
        let targetY = textView.frame.height * 0.85
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.ensureVisibleLayout()   // what the wrapper's scroll observer does
        let anchorBefore = topVisibleLocation(of: textView)
        coordinator.styleStagedChunksAroundViewport(of: textView)
        #expect(topVisibleLocation(of: textView) == anchorBefore, "styling the chunk above keeps the top line in place")

        #expect(coordinator.stagedStylingPending.count < pendingBefore)
        #expect(coordinator.stagedStylingPending.first == firstChunk, "chunks before the viewport stay queued")
        let visible = textView.visibleRect
        let tlm = textView.textLayoutManager!
        var visibleHeading: Int?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.maxY > visible.minY else { return true }
            let start = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
            if (textView.string as NSString).substring(with: NSRange(location: start, length: min(3, textView.textStorage!.length - start))) == "## " {
                visibleHeading = start
                return false
            }
            return frame.minY < visible.maxY
        }
        if let visibleHeading {
            #expect(fontSize(textView.textStorage!, at: visibleHeading + 3) > base, "the viewport is styled at once")
        } else {
            Issue.record("no heading inside the viewport")
        }

        await pump(coordinator)
        #expect(coordinator.stagedStylingActive == false)
        #expect(topVisibleLocation(of: textView) == anchorBefore, "the background turns keep the top line in place")
        let staged = styleSamples(textView.textStorage!)
        expectSameStyle(staged, fullRestyleSamples(coordinator, textView))
    }

    @Test func editsMoveThePendingChunksAlong() async {
        let (coordinator, textView, _) = makeEditor()
        let text = largeDocument()
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        let before = coordinator.stagedStylingPending
        #expect(before.count >= 4)

        // An insertion ahead of every chunk shifts them all.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("New first line\n", replacementRange: NSRange(location: 0, length: 0))
        let inserted = ("New first line\n" as NSString).length
        #expect(coordinator.stagedStylingPending.map(\.location) == before.map { $0.location + inserted })
        #expect(coordinator.stagedStylingPending.map(\.length) == before.map(\.length))

        // A deletion inside the first chunk (no fence involved) shrinks that chunk
        // and shifts the later ones.
        let first = coordinator.stagedStylingPending[0]
        let ns = textView.string as NSString
        let bold = ns.range(of: "**bold**, ", options: [], range: first)
        #expect(bold.location != NSNotFound)
        textView.insertText("", replacementRange: bold)
        #expect(coordinator.stagedStylingPending[0] == NSRange(location: first.location, length: first.length - bold.length))
        #expect(coordinator.stagedStylingPending[1].location == NSMaxRange(first) + before[1].location - NSMaxRange(before[0]) - bold.length)

        await pump(coordinator)
        #expect(coordinator.stagedStylingActive == false)
        let staged = styleSamples(textView.textStorage!)
        expectSameStyle(staged, fullRestyleSamples(coordinator, textView))
    }

    @Test func aDeletionAcrossAChunkBoundaryKeepsWhatSurvives() {
        let (coordinator, textView, _) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: largeDocument())
        let before = coordinator.stagedStylingPending
        let boundary = before[0].location
        let length = (textView.string as NSString).length
        let parsed = coordinator.parsedDocument(for: textView.string)

        // 120 characters removed: 50 from the styled head, 70 from the first chunk.
        coordinator.shiftStagedStyling(editedRange: NSRange(location: boundary - 50, length: 0), delta: -120, trusted: true,
                                       blocks: parsed.blocks, length: length - 120, wholeDocumentRestyled: false)
        let first = coordinator.stagedStylingPending[0]
        #expect(first.location == boundary - 50, "the chunk now starts where the edit starts")
        #expect(NSMaxRange(first) == NSMaxRange(before[0]) - 120)
        #expect(coordinator.stagedStylingPending[1].location == before[1].location - 120)
        #expect(coordinator.stagedStylingPending.count == before.count)

        // A replacement that swallows a whole chunk drops it.
        let victim = coordinator.stagedStylingPending[1]
        coordinator.shiftStagedStyling(editedRange: NSRange(location: victim.location - 10, length: 5), delta: 5 - (victim.length + 20), trusted: true,
                                       blocks: parsed.blocks, length: length - 120 + 5 - (victim.length + 20), wholeDocumentRestyled: false)
        #expect(coordinator.stagedStylingPending.count == before.count - 1)
        // The deletion reaches 10 characters into the chunk after the victim, so that
        // chunk now starts where the edit starts and ends shifted by the edit's delta.
        let next = coordinator.stagedStylingPending[1]
        #expect(next.location == victim.location - 10)
        #expect(NSMaxRange(next) == NSMaxRange(before[2]) - 120 + 5 - (victim.length + 20))
        coordinator.cancelStagedStyling()
    }

    @Test func untrustedEditReplansFromTheFirstPendingChunk() async {
        let (coordinator, textView, _) = makeEditor()
        let text = largeDocument()
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        let first = coordinator.stagedStylingPending[0].location
        let length = (textView.string as NSString).length
        let parsed = coordinator.parsedDocument(for: textView.string)

        // An edit past the first pending chunk: replan from that chunk, moved by the deletion.
        coordinator.shiftStagedStyling(editedRange: NSRange(location: first + 500, length: 0), delta: -7, trusted: false,
                                       blocks: parsed.blocks, length: length, wholeDocumentRestyled: false)
        #expect(coordinator.stagedStylingPending.first?.location == first - 7)
        #expect(coordinator.stagedStylingPending.last.map(NSMaxRange) == length)

        // An edit in the styled head: text under the chunks styled since may have moved,
        // so the replan starts at the edit.
        coordinator.shiftStagedStyling(editedRange: NSRange(location: 5, length: 0), delta: 3, trusted: false,
                                       blocks: parsed.blocks, length: length, wholeDocumentRestyled: false)
        #expect(coordinator.stagedStylingPending.first?.location == 5)

        coordinator.shiftStagedStyling(editedRange: NSRange(location: 5, length: 0), delta: Int.min, trusted: false,
                                       blocks: parsed.blocks, length: length, wholeDocumentRestyled: false)
        #expect(coordinator.stagedStylingPending.first?.location == 0)

        coordinator.shiftStagedStyling(editedRange: NSRange(location: 5, length: 0), delta: 0, trusted: true,
                                       blocks: parsed.blocks, length: length, wholeDocumentRestyled: true)
        #expect(coordinator.stagedStylingPending.isEmpty)
        #expect(coordinator.stagedStylingActive, "the layout turns still have to finish")
        await pump(coordinator)
        #expect(coordinator.stagedStylingActive == false)
    }

    @Test func openMeasuresAnEstimateAndTheFinishMeasuresExactly() async {
        let (coordinator, textView, scrollView) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: largeDocument())
        textView.pendingFullLayoutMeasure = true
        textView.recalcOverscroll(for: scrollView, debugTag: "open")
        #expect(textView.pendingFullLayoutMeasure == false, "the open path never forces a full layout")
        #expect(textView.baseContentHeight > 400)

        await pump(coordinator)
        let settled = textView.baseContentHeight
        textView.pendingFullLayoutMeasure = true
        textView.recalcOverscroll(for: scrollView, debugTag: "?")
        #expect(abs(textView.baseContentHeight - settled) < 0.5, "the staged finish left the exact height")
    }

    @Test func estimatedHeightFollowsTheLayoutAndARevealReachesTheTail() async {
        let (coordinator, textView, scrollView) = makeEditor()
        textView.configuration.readingWidth = 560   // the engine's own reveal path
        let text = largeDocument()
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        textView.recalcOverscroll(for: scrollView, debugTag: "open")
        let textKitEstimate = textView.baseContentHeight
        #expect(textView.contentHeightIsEstimated)

        // Two turns: the head is laid out, then the first chunk.
        let deadline = Date(timeIntervalSinceNow: 30)
        while coordinator.stagedLayoutEnd <= 24_000, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let extrapolated = textView.baseContentHeight

        // A reveal of a heading near the end lands even though the tail is not laid out.
        let heading = headingLocation(in: text, fraction: 0.9)
        textView.scrollRangeToVisible(NSRange(location: heading, length: 1))
        func headingRect() -> CGRect? {
            let tlm = textView.textLayoutManager!
            guard let location = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: heading),
                  let fragment = tlm.textLayoutFragment(for: location) else { return nil }
            tlm.ensureLayout(for: fragment.rangeInElement)
            return fragment.layoutFragmentFrame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        }
        #expect(headingRect().map { $0.intersects(textView.visibleRect) } == true, "revealed: \(String(describing: headingRect())) in \(textView.visibleRect)")

        await pump(coordinator)
        let exact = textView.baseContentHeight
        #expect(textView.contentHeightIsEstimated == false)
        #expect(exact > textKitEstimate * 1.2, "TextKit's estimate is far below the styled height: \(textKitEstimate) vs \(exact)")
        #expect(abs(extrapolated - exact) < exact * 0.35, "the extrapolation is close: \(extrapolated) vs \(exact)")
        #expect(headingRect().map { $0.intersects(textView.visibleRect) } == true, "still visible after the background turns")
    }

    @Test func stagedOpenMatchesTheSinglePassRebuild() async {
        let text = largeDocument()
        let (staged, stagedView, _) = makeEditor()
        staged.rebuildTextStorageAndStyle(stagedView, from: text)
        await pump(staged)

        let (single, singleView, _) = makeEditor()
        let savedLength = NativeTextViewCoordinator.stagedStylingInitialLength
        NativeTextViewCoordinator.stagedStylingInitialLength = .max   // no await until restored
        single.rebuildTextStorageAndStyle(singleView, from: text)
        NativeTextViewCoordinator.stagedStylingInitialLength = savedLength
        #expect(single.stagedStylingActive == false)

        expectSameStyle(styleSamples(stagedView.textStorage!), styleSamples(singleView.textStorage!))
    }

    @Test func wikiLinkIDsInTheTailSurviveAStorageRebuildBeforeTheChunksArrive() {
        let (coordinator, textView, _) = makeEditor()
        let text = largeDocument() + "See [[Target Note|abc-123]] and ![[Picture|img-7]] at the end.\n"
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        #expect(coordinator.stagedStylingActive)
        let display = textView.string as NSString
        let link = display.range(of: "[[Target Note]]")
        let embed = display.range(of: "![[Picture]]")
        #expect(link.location != NSNotFound && embed.location != NSNotFound)
        let storage = textView.textStorage!
        #expect(storage.attribute(.wikiLinkID, at: link.location + 2, effectiveRange: nil) as? String == "abc-123")
        #expect(storage.attribute(.wikiLinkID, at: embed.location + 3, effectiveRange: nil) as? String == "img-7")
        // The fallback storage rebuild reads the attribute, not the range-keyed metadata.
        let rebuilt = WikiLinkService.makeStorageState(from: textView.string, existingMetadata: [:], textStorage: storage)
        #expect(rebuilt.storage.contains("[[Target Note|abc-123]]"))
        #expect(rebuilt.storage.contains("![[Picture|img-7]]"))
        coordinator.cancelStagedStyling()
    }

    @Test func rebuildOfAnotherDocumentDropsTheQueue() async {
        let (coordinator, textView, _) = makeEditor()
        coordinator.rebuildTextStorageAndStyle(textView, from: largeDocument())
        #expect(coordinator.stagedStylingActive)
        coordinator.rebuildTextStorageAndStyle(textView, from: "# Short\n\nOne paragraph.\n")
        #expect(coordinator.stagedStylingActive == false)
        #expect(coordinator.stagedStylingPending.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.stagedStylingActive == false)
    }
}
