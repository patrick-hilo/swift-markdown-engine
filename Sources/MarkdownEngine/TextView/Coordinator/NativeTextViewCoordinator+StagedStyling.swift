//
//  NativeTextViewCoordinator+StagedStyling.swift
//  MarkdownEngine
//
//  Opening a large document used to style every paragraph and lay the whole
//  document out twice before the first frame. A staged open styles the head of
//  the document synchronously and hands the rest to later runloop turns in
//  block-aligned chunks: each turn styles the next chunk and lays the document
//  out up to its end, so the main thread never blocks for the whole document.
//  Scrolling into unstyled text styles the chunks under the viewport at once;
//  an edit while chunks are pending moves their ranges along. Only attributes
//  are ever deferred, never the text. The exact height is measured once at the
//  end; until then the overscroll policy works from a height extrapolated from
//  the part laid out so far.
//

import AppKit

extension NativeTextViewCoordinator {
    /// UTF-16 length styled synchronously by a rebuild; a document no longer than
    /// this keeps the single-pass open.
    static var stagedStylingInitialLength = 24_000
    /// Target UTF-16 length of one background chunk.
    static var stagedStylingChunkLength = 32_000
    /// UTF-16 units styled beyond the viewport when the reader scrolls into
    /// unstyled text.
    static var stagedStylingViewportMargin = 4_000
    /// Most UTF-16 units laid out by one background turn when the sequential layout
    /// has to catch up with chunks the viewport pulled forward.
    static var stagedLayoutStepLength = 64_000

    struct StagedStylingPlan: Equatable {
        let initial: NSRange
        let pending: [NSRange]
    }

    /// Cuts the document at block ends into the synchronous head and the chunks
    /// that follow; nil when the document is short enough for a single pass.
    static func stagedStylingPlan(blocks: [Block], length: Int) -> StagedStylingPlan? {
        guard length > stagedStylingInitialLength else { return nil }
        let cuts = chunkCuts(blocks: blocks, from: 0, length: length, firstTarget: stagedStylingInitialLength)
        guard cuts.count >= 2 else { return nil }
        let initial = NSRange(location: 0, length: cuts[0])
        return StagedStylingPlan(initial: initial, pending: ranges(between: cuts))
    }

    /// Block-aligned chunks covering `start ..< length`.
    static func stagedChunks(blocks: [Block], from start: Int, length: Int) -> [NSRange] {
        guard start < length else { return [] }
        let cuts = chunkCuts(blocks: blocks, from: start, length: length, firstTarget: start + stagedStylingChunkLength)
        return ranges(between: [start] + cuts)
    }

    /// Block ends at or past each chunk target, always ending with `length`.
    private static func chunkCuts(blocks: [Block], from start: Int, length: Int, firstTarget: Int) -> [Int] {
        var cuts: [Int] = []
        var target = firstTarget
        for block in blocks {
            let end = NSMaxRange(block.range)
            guard end > start else { continue }
            if end >= target, end < length {
                cuts.append(end)
                target = end + stagedStylingChunkLength
            }
        }
        cuts.append(length)
        return cuts
    }

    private static func ranges(between cuts: [Int]) -> [NSRange] {
        var result: [NSRange] = []
        for index in 1..<cuts.count where cuts[index] > cuts[index - 1] {
            result.append(NSRange(location: cuts[index - 1], length: cuts[index] - cuts[index - 1]))
        }
        return result
    }

    // MARK: - Lifecycle

    /// Called by the rebuild after the head is styled: the rest follows one chunk per
    /// runloop turn. The head's layout is not forced either; the first turn lays it out.
    func beginStagedStyling(_ plan: StagedStylingPlan) {
        stagedStylingGeneration &+= 1
        stagedStylingPending = plan.pending
        stagedLayoutEnd = 0
        stagedStylingActive = true
        stagedStylingContainerWidth = textView?.textContainer?.size.width ?? 0
        if let native = textView as? NativeTextView {
            native.contentHeightIsEstimated = true
            native.estimatedContentHeightFloor = 0
        }
        scheduleStagedStylingTurn()
    }

    /// Drops any staged work; a rebuild of another document calls this first.
    func cancelStagedStyling() {
        stagedStylingGeneration &+= 1
        stagedStylingPending = []
        stagedStylingActive = false
        stagedLayoutEnd = 0
        if let native = textView as? NativeTextView {
            native.contentHeightIsEstimated = false
            native.estimatedContentHeightFloor = 0
        }
    }

    /// Styles every pending chunk now. A saved scroll offset is restored against the
    /// exact document, so the wrapper drains the queue before applying one; the layout
    /// turns and the exact measurement still follow.
    func drainStagedStyling(_ textView: NSTextView) {
        guard stagedStylingActive, !stagedStylingPending.isEmpty else { return }
        let length = (textView.string as NSString).length
        let chunks = stagedStylingPending.map { clamp($0, to: length) }.filter { $0.length > 0 }
        stagedStylingPending = []
        preservingFindHighlights(in: chunks, of: textView) {
            restyleParagraphs(chunks, in: textView)
        }
    }

    private func scheduleStagedStylingTurn() {
        let generation = stagedStylingGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.stagedStylingGeneration else { return }
            self.stagedStylingTurn()
        }
    }

    /// One background turn: lay out toward the next chunk when the viewport pulled
    /// chunks ahead of the sequential layout, otherwise style the next chunk and
    /// lay it out. Finishes with the one exact measurement once nothing is left.
    func stagedStylingTurn() {
        guard stagedStylingActive else { return }
        guard let textView else { cancelStagedStyling(); return }
        let length = (textView.string as NSString).length
        // Debug-only breakdown of one turn, printed like a keystroke frame.
        PerfTrace.begin(docLength: length)
        if let next = stagedStylingPending.first, next.location <= stagedLayoutEnd {
            stagedStylingPending.removeFirst()
            let chunk = clamp(next, to: length)
            keepingViewportAnchor(of: textView, restyling: [chunk]) {
                if chunk.length > 0 {
                    PerfTrace.measure("stagedStyle") {
                        preservingFindHighlights(in: [chunk], of: textView) { restyleParagraphs([chunk], in: textView) }
                    }
                }
                PerfTrace.measure("stagedLayout") { ensureStagedLayout(upTo: NSMaxRange(chunk), in: textView) }
            }
            PerfTrace.note { "staged chunk=\(chunk.location)+\(chunk.length) pending=\(self.stagedStylingPending.count)" }
        } else {
            // Layout only, catching up with chunks the viewport pulled forward: the text
            // between is already laid out by the scroll observer, so nothing moves.
            let goal = stagedStylingPending.first?.location ?? length
            let step = min(goal, stagedLayoutEnd + Self.stagedLayoutStepLength)
            PerfTrace.measure("stagedLayout") { ensureStagedLayout(upTo: step, in: textView) }
            PerfTrace.note { "staged layout→\(step) pending=\(self.stagedStylingPending.count)" }
        }
        if let native = textView as? NativeTextView, let scrollView = textView.enclosingScrollView {
            PerfTrace.measure("stagedEstimate") {
                native.raiseEstimatedContentHeight(laidOutThrough: stagedLayoutEnd, for: scrollView)
            }
        }
        PerfTrace.end()
        if stagedStylingPending.isEmpty, stagedLayoutEnd >= length {
            finishStagedStyling(textView)
        } else {
            scheduleStagedStylingTurn()
        }
    }

    private func ensureStagedLayout(upTo end: Int, in textView: NSTextView) {
        guard end > stagedLayoutEnd else { return }
        (textView as? NativeTextView)?.layOutFragments(from: stagedLayoutEnd, to: end)
        stagedLayoutEnd = end
    }

    private func finishStagedStyling(_ textView: NSTextView) {
        stagedStylingActive = false
        stagedStylingPending = []
        guard let native = textView as? NativeTextView else { return }
        native.contentHeightIsEstimated = false
        native.estimatedContentHeightFloor = 0
        guard let scrollView = textView.enclosingScrollView else { return }
        // Everything is laid out, so the forced measurement only enumerates; it
        // turns the estimate the open path worked with into the exact height.
        // The head was styled on the first update pass. SwiftUI hands the editor a
        // provisional width there (925 pt for an 800-pt window on the Mini), the reading
        // column settles later, and with a reading column a width change restyles no
        // tables; the chunks then rendered their tables for the real width. One pass over
        // the table paragraphs makes the head match.
        if let width = textView.textContainer?.size.width, abs(width - stagedStylingContainerWidth) > 0.5 {
            native.restyleTableParagraphsForWidthChange()
        }
        native.pendingFullLayoutMeasure = true
        native.recalcOverscroll(for: scrollView, debugTag: "staged")
        (scrollView as? ClampedScrollView)?.clampToInsets()
    }

    // MARK: - Viewport

    /// Styles the pending chunks around the visible text at once, so scrolling ahead
    /// of the background turns never shows base-font text for longer than a frame.
    func styleStagedChunksAroundViewport(of textView: NSTextView) {
        guard stagedStylingActive, !stagedStylingPending.isEmpty, !isKeepingViewportAnchor,
              let visible = visibleCharacterRange(of: textView) else { return }
        let margin = Self.stagedStylingViewportMargin
        let window = NSRange(location: max(0, visible.location - margin),
                             length: visible.length + 2 * margin)
        let hits = stagedStylingPending.filter { NSIntersectionRange($0, window).length > 0 }
        guard !hits.isEmpty else { return }
        stagedStylingPending.removeAll { NSIntersectionRange($0, window).length > 0 }
        let length = (textView.string as NSString).length
        let chunks = hits.map { clamp($0, to: length) }.filter { $0.length > 0 }
        keepingViewportAnchor(of: textView, restyling: chunks) {
            preservingFindHighlights(in: chunks, of: textView) { restyleParagraphs(chunks, in: textView) }
        }
        PerfTrace.stamp("staged viewport", 0, "pulled=\(hits.count) pending=\(stagedStylingPending.count)")
    }

    /// Runs `body`, which restyles or lays out `ranges`, and keeps the line at the top
    /// of the viewport where it was. Restyled text above the viewport changes height,
    /// and without this the text under the reader's eyes moves by the difference.
    /// The shift is the change in the summed heights of the affected fragments above
    /// the anchor: fragments a restyle re-lays out carry fresh heights, while TextKit
    /// moves the cached frames below them only when it draws, so absolute positions
    /// read here would not show the change yet.
    private func keepingViewportAnchor(of textView: NSTextView, restyling ranges: [NSRange], _ body: () -> Void) {
        // In `.fitsContent` the inner clip view never scrolls; the page scroller
        // above it is out of reach from here.
        guard let native = textView as? NativeTextView,
              native.configuration.heightBehavior == .scrolls,
              let scrollView = textView.enclosingScrollView,
              let tlm = textView.textLayoutManager,
              let content = tlm.textContentManager else { return body() }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        guard visible.height > 0, visible.minY > origin.y + 0.5,
              let anchor = tlm.textLayoutFragment(for: CGPoint(x: 0, y: visible.minY - origin.y)) else { return body() }
        let anchorOffset = tlm.offset(from: tlm.documentRange.location, to: anchor.rangeInElement.location)
        let above = ranges.compactMap { range -> NSRange? in
            let end = min(NSMaxRange(range), anchorOffset)
            return end > range.location ? NSRange(location: range.location, length: end - range.location) : nil
        }
        guard !above.isEmpty else { return body() }
        func heightAbove() -> CGFloat {
            var sum: CGFloat = 0
            for range in above {
                guard let from = content.location(tlm.documentRange.location, offsetBy: range.location),
                      let to = content.location(tlm.documentRange.location, offsetBy: NSMaxRange(range)) else { continue }
                tlm.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) { fragment in
                    guard fragment.rangeInElement.location.compare(to) == .orderedAscending else { return false }
                    sum += fragment.layoutFragmentFrame.height
                    return true
                }
            }
            return sum
        }
        let before = heightAbove()
        isKeepingViewportAnchor = true
        defer { isKeepingViewportAnchor = false }
        body()
        let after = heightAbove()
        let delta = after - before
        PerfTrace.stamp("staged anchor", 0, "offset=\(anchorOffset) before=\(Int(before)) after=\(Int(after)) clipY=\(Int(scrollView.contentView.bounds.origin.y))")
        guard abs(delta) > 0.5 else { return }
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
    }

    /// A chunk restyle lays base attributes down first, which wipes find's
    /// highlights; put them back so a search started right after opening keeps its
    /// marks in the tail.
    private func preservingFindHighlights(in chunks: [NSRange], of textView: NSTextView, _ body: () -> Void) {
        guard let storage = textView.textStorage else { return body() }
        var marks: [(NSRange, Any)] = []
        for chunk in chunks {
            storage.enumerateAttribute(.findHighlight, in: chunk, options: []) { value, range, _ in
                guard value != nil,
                      let color = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) else { return }
                marks.append((range, color))
            }
        }
        body()
        guard !marks.isEmpty else { return }
        storage.beginEditing()
        for (range, color) in marks {
            storage.addAttribute(.backgroundColor, value: color, range: range)
            storage.addAttribute(.findHighlight, value: true, range: range)
        }
        storage.endEditing()
    }

    /// Character range under the visible rect; TextKit answers from estimated
    /// geometry for fragments it has not laid out, which the margin absorbs.
    private func visibleCharacterRange(of textView: NSTextView) -> NSRange? {
        guard let tlm = textView.textLayoutManager else { return nil }
        let rect = textView.visibleRect
        guard rect.height > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let top = CGPoint(x: 0, y: rect.minY - origin.y)
        let bottom = CGPoint(x: 0, y: rect.maxY - origin.y)
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        let end = tlm.textLayoutFragment(for: bottom)?.rangeInElement.endLocation ?? tlm.documentRange.endLocation
        let from = tlm.offset(from: tlm.documentRange.location, to: start)
        let to = tlm.offset(from: tlm.documentRange.location, to: end)
        guard to >= from else { return nil }
        return NSRange(location: from, length: to - from)
    }

    // MARK: - Edits

    /// Moves the pending chunks with an edit. A trusted single edit maps every range
    /// through the change; anything else re-plans from the first pending location
    /// (or the document start when the length change is unknown) — more styling in
    /// the background, never a missed paragraph. A pass that already restyled the
    /// whole document clears the queue.
    func shiftStagedStyling(
        editedRange: NSRange,
        delta: Int,
        trusted: Bool,
        blocks: [Block],
        length: Int,
        wholeDocumentRestyled: Bool
    ) {
        guard stagedStylingActive else { return }
        if wholeDocumentRestyled {
            stagedStylingPending = []
            return
        }
        if trusted, delta != Int.min, editedRange.location != NSNotFound {
            guard !stagedStylingPending.isEmpty else { return }
            let editStart = editedRange.location
            let newEnd = NSMaxRange(editedRange)
            let oldEnd = newEnd - delta
            func map(_ position: Int, inside: Int) -> Int {
                if position <= editStart { return position }
                if position >= oldEnd { return position + delta }
                return inside
            }
            func inside(_ position: Int) -> Bool { position > editStart && position < oldEnd }
            stagedStylingPending = stagedStylingPending.compactMap { range in
                // A chunk the edit swallowed whole is covered by the edit's own restyle.
                if inside(range.location), inside(NSMaxRange(range)) { return nil }
                let start = map(range.location, inside: editStart)
                let end = map(NSMaxRange(range), inside: newEnd)
                return end > start ? NSRange(location: start, length: end - start) : nil
            }
            stagedLayoutEnd = min(map(stagedLayoutEnd, inside: editStart), length)
        } else {
            // A mutation the descriptor does not describe (IME commit, interceptor
            // batch) may have moved text under chunks styled since; restyle from the
            // edit or the first pending chunk, whichever comes first. With an empty
            // queue this re-queues the tail the edit may have shifted.
            let first = stagedStylingPending.map(\.location).min() ?? length
            let edit = editedRange.location == NSNotFound ? length : editedRange.location
            let start = delta == Int.min ? 0 : max(0, min(first, edit) + min(delta, 0))
            stagedStylingPending = Self.stagedChunks(blocks: blocks, from: start, length: length)
            stagedLayoutEnd = min(stagedLayoutEnd, start)
        }
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(NSMaxRange(range), length)
        return NSRange(location: start, length: max(0, end - start))
    }
}
