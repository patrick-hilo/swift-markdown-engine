//
//  NativeTextView+FrameAndOverscroll.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Frame-size management, content-height measurement (TextKit-2 last-fragment
//  + end-segment pattern), bottom-overscroll application, and transient-shrink
//  scroll-position restoration.
//

import AppKit

extension NativeTextView {
    /// Real content height including overscroll, excluding the click-below-text inflation.
    var scrollableContentHeight: CGFloat {
        max(ceil(baseContentHeight + activeBottomOverscroll), 0)
    }

    func recalcOverscroll(
        for scrollView: NSScrollView,
        targetWidth: CGFloat? = nil,
        debugTag: String = "?"
    ) {
        scrollView.contentInsets.bottom = 0

        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        // File switch/resize forces full layout until height settles; typing stays O(edit).
        if debugTag == "?" { pendingFullLayoutMeasure = true }
        // The open path measures TextKit's estimate: the text there is either about to
        // be replaced by the styled document or is being styled and laid out in stages
        // after the first frame, and the staged finish measures the exact height.
        if debugTag == "open" { pendingFullLayoutMeasure = false }
        let forcedFullLayout = pendingFullLayoutMeasure
        let measured = measuredBaseContentHeight(
            minimumHeight: lineHeight,
            forceFullLayout: pendingFullLayoutMeasure
        )
        let visibleHeight = scrollView.contentView.bounds.height
        let resolvedOverscroll = resolvedOverscroll(
            baseContentHeight: measured,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )

        let baseHeightChanged = abs(measured - baseContentHeight) > 0.5
        let overscrollChanged = abs(resolvedOverscroll - activeBottomOverscroll) > 0.5
        // One forced full layout makes the height exact; the flag re-arms on the next
        // switch or resize. Waiting for the height to settle instead kept the flag up
        // through every edit after a resize, and each paste into a long document then
        // paid a full document layout on the main thread.
        if forcedFullLayout || !(baseHeightChanged || overscrollChanged) { pendingFullLayoutMeasure = false }
        // A persistent fullLayout=1 with hChanged/osChanged flipping every
        // keystroke = the bistable-height loop: every keystroke then pays a
        // FULL document ensureLayout inside the overscroll span.
        PerfTrace.note {
            "overscroll[\(debugTag)]: fullLayout=\(forcedFullLayout ? 1 : 0) h=\(Int(measured))\(baseHeightChanged ? " hChanged" : "")\(overscrollChanged ? " osChanged" : "")"
        }
        guard baseHeightChanged || overscrollChanged else { return }
        baseContentHeight = measured
        activeBottomOverscroll = resolvedOverscroll
        applyManagedFrameSize(width: targetWidth ?? frame.size.width)
    }

    /// Re-run the policy with the CURRENT base content height — no TextKit
    /// re-measure. For header-band changes (runs per animation frame).
    func reapplyOverscrollPolicy(for scrollView: NSScrollView) {
        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        let resolved = resolvedOverscroll(
            baseContentHeight: baseContentHeight,
            visibleHeight: scrollView.contentView.bounds.height,
            lineHeight: lineHeight
        )
        guard abs(resolved - activeBottomOverscroll) > 0.5 else { return }
        activeBottomOverscroll = resolved
        applyManagedFrameSize(width: frame.size.width)
    }

    /// Shared policy evaluation, including the header band stacked above the text —
    /// without it, a short text under an expanded band gets no slack.
    private func resolvedOverscroll(
        baseContentHeight: CGFloat,
        visibleHeight: CGFloat,
        lineHeight: CGFloat
    ) -> CGFloat {
        // Overscroll is a scroll-comfort affordance; meaningless without internal scrolling.
        guard configuration.heightBehavior == .scrolls else { return 0 }
        let headerHeight = (superview as? NativeTextViewContainer)?.headerHeight ?? 0
        let policy = BottomOverscrollPolicy(
            overscrollPercent: overscrollPercent,
            minOverscrollPoints: minOverscrollPoints,
            maxOverscrollPoints: maxOverscrollPoints,
            activationStartFraction: configuration.overscroll.activationStartFraction,
            activationRangeFraction: configuration.overscroll.activationRangeFraction
        )
        return policy.activeOverscroll(
            baseContentHeight: baseContentHeight,
            headerHeight: headerHeight,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )
    }

    /// Lays out the paragraphs of an edit so the next height measurement is exact there.
    /// TextKit estimates the height of fragments it has not laid out yet; measuring from
    /// the document end after a paste would otherwise under-count the pasted paragraphs.
    func ensureLayout(forCharacterRange range: NSRange) {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              range.location != NSNotFound else { return }
        let length = (string as NSString).length
        let start = min(range.location, length)
        let end = min(NSMaxRange(range), length)
        guard let from = content.location(layoutManager.documentRange.location, offsetBy: start),
              let to = content.location(layoutManager.documentRange.location, offsetBy: end),
              let textRange = NSTextRange(location: from, end: to) else { return }
        layoutManager.ensureLayout(for: textRange)
    }

    /// Lays out `start ..< end` by walking the fragments with `.ensuresLayout`. Unlike
    /// `ensureLayout(for:)`, the walk re-lays out fragments an attribute change
    /// invalidated, so their heights are fresh afterwards; the cached frames below them
    /// move only when TextKit draws. A staged open depends on the fresh heights for its
    /// anchoring and its sequential layout.
    func layOutFragments(from start: Int, to end: Int) {
        guard end > start, let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager else { return }
        let length = (string as NSString).length
        guard let from = content.location(layoutManager.documentRange.location, offsetBy: min(start, length)),
              let to = content.location(layoutManager.documentRange.location, offsetBy: min(end, length)) else { return }
        layoutManager.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) { fragment in
            fragment.rangeInElement.location.compare(to) == .orderedAscending
        }
    }

    func measuredBaseContentHeight(minimumHeight: CGFloat, forceFullLayout: Bool = false) -> CGFloat {
        let minimumContentHeight = ceil(max(minimumHeight, 0) + (textContainerInset.height * 2))
        guard let textLayoutManager else { return minimumContentHeight }

        // Partial TextKit-2 layout under-measures and oscillates; force full layout only on switch/resize.
        if forceFullLayout {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }

        let documentEnd = textLayoutManager.documentRange.endLocation

        // Lay out the last fragment; gives a max-Y fallback if enumerateTextSegments misses it.
        var fragmentMaxY: CGFloat = 0
        var visited = 0
        // Geometry of the fragment containing the document end — the extra line
        // fragment normalization below needs its frame and line boxes.
        var lastFragmentFrame: NSRect = .zero
        var lastFragmentLineBoxes: [CGRect] = []
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEnd,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if visited == 0 {
                lastFragmentFrame = frame
                lastFragmentLineBoxes = fragment.textLineFragments.map { $0.typographicBounds }
            }
            fragmentMaxY = max(fragmentMaxY, frame.maxY)
            // Trailing block image draws below TextKit's height; count its surface extent so it scrolls.
            let surfaceMaxY = frame.origin.y + fragment.renderingSurfaceBounds.maxY
            if surfaceMaxY > frame.maxY + 8 { fragmentMaxY = max(fragmentMaxY, surfaceMaxY) }
            visited += 1
            return visited < 3
        }

        // End-segment maxY = authoritative document height in TextKit 2.
        let segmentRange = NSTextRange(location: documentEnd)
        textLayoutManager.ensureLayout(for: segmentRange)
        var segmentMaxY: CGFloat = 0
        var segmentMinY: CGFloat = 0
        textLayoutManager.enumerateTextSegments(
            in: segmentRange,
            type: .standard,
            options: .middleFragmentsExcluded
        ) { _, rect, _, _ in
            if rect.maxY >= segmentMaxY {
                segmentMaxY = rect.maxY
                segmentMinY = rect.minY
            }
            return true
        }

        var rawHeight = max(segmentMaxY, fragmentMaxY)

        // With a trailing "\n", the last line is TextKit's extra line fragment.
        // Its metrics follow the final newline's attributes — not the body style a
        // typed line would get — so the measured height would jump on the first
        // typed character. Normalize the empty last line to body metrics.
        if segmentMaxY > 0, let storage = textStorage, storage.mutableString.hasSuffix("\n") {
            let bodyLineHeight = ceil(layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge))
                + configuration.paragraph.lineHeightExtraSpacing

            // TextKit omits the final paragraph's paragraphSpacing above the extra
            // line fragment but inserts it once a real character follows — add the
            // missing gap so typing stays height-neutral.
            let ns = storage.mutableString
            let lastParaRange = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
            let lastParaStyle = storage.attribute(
                .paragraphStyle, at: lastParaRange.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let paragraphSpacing = lastParaStyle?.paragraphSpacing ?? 0
            let prevLineBottom: CGFloat
            if lastFragmentLineBoxes.count >= 2 {
                let secondToLast = lastFragmentLineBoxes[lastFragmentLineBoxes.count - 2]
                prevLineBottom = lastFragmentFrame.minY + secondToLast.maxY
            } else {
                prevLineBottom = lastFragmentFrame.minY
            }
            let appliedGap = max(segmentMinY - prevLineBottom, 0)
            let missingSpacing = max(paragraphSpacing - appliedGap, 0)
            let normalizedEnd = segmentMinY + missingSpacing + bodyLineHeight
            if abs(rawHeight - segmentMaxY) < 0.5 {
                // The extra line itself is the bottom-most content — replace it.
                rawHeight = normalizedEnd
            } else {
                // Something else (e.g. a trailing image surface) reaches lower — keep it.
                rawHeight = max(rawHeight, normalizedEnd)
            }
        }

        let measured = max(ceil(rawHeight + (textContainerInset.height * 2)), minimumContentHeight)
        guard contentHeightIsEstimated, !forceFullLayout else { return measured }
        return max(measured, estimatedContentHeightFloor)
    }

    /// Extrapolates the document height from the text laid out so far (`0 ..< end`)
    /// and adopts it as the floor of the estimated height. TextKit's own estimate for
    /// text it has not laid out is far below the styled height, and a scroll past it
    /// is cut off at the frame.
    func raiseEstimatedContentHeight(laidOutThrough end: Int, for scrollView: NSScrollView) {
        guard contentHeightIsEstimated, end > 0,
              let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager else { return }
        let length = (string as NSString).length
        guard end < length,
              let location = content.location(layoutManager.documentRange.location, offsetBy: end - 1),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return }
        let laidOut = fragment.layoutFragmentFrame.maxY
        let extrapolated = ceil(laidOut * CGFloat(length) / CGFloat(end) + textContainerInset.height * 2)
        guard extrapolated > estimatedContentHeightFloor + 0.5 else { return }
        estimatedContentHeightFloor = extrapolated
        recalcOverscroll(for: scrollView, debugTag: "estimate")
    }

    /// Fixed reading-column width = wrap width + horizontal insets on both sides.
    var readingColumnWidth: CGFloat {
        (configuration.readingWidth ?? 0) + configuration.textInsets.horizontal * 2
    }

    func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll), 0)
        let height: CGFloat
        switch configuration.heightBehavior {
        case .scrolls:
            // The container stacks a header band ABOVE this text view, so the text view only
            // needs to fill the viewport MINUS that band for the whole document view to fill
            // the viewport on short docs (header + textView ≥ viewport).
            let headerH = (superview as? NativeTextViewContainer)?.headerHeight ?? 0
            let scrollViewHeight = max((enclosingScrollView?.contentView.bounds.height ?? 0) - headerH, 0)
            height = max(contentHeight, scrollViewHeight)
        case .fitsContent:
            height = contentHeight
        }
        // Reading column: the column keeps its fixed wrap width; its centered X is
        // owned by `centerReadingColumn` (driven from the container's restack).
        let targetWidth = configuration.readingWidth != nil ? readingColumnWidth : max(width, 0)
        let targetSize = NSSize(
            width: targetWidth,
            height: height
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
        // Tell the container our height changed so it can re-stack (move us below the
        // header) and size itself. Re-entrancy is guarded inside the container.
        (superview as? NativeTextViewContainer)?.textViewDidResize()

        // Nudge SwiftUI to re-query sizeThatFits when content height changes outside
        // the text binding (e.g. image/LaTeX load, font-size change, header band).
        if configuration.heightBehavior == .fitsContent {
            enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }

    /// Re-center the column by moving its X (not resizing it) so it stays smooth during live resize.
    /// Adopt a reading width on a live text view: re-fix the wrap width, resize the
    /// column and re-center it. Without this an embedder that changes its reading
    /// column has to rebuild the editor, which costs the scroll position and a full
    /// re-layout of the document.
    func applyReadingWidth(_ width: CGFloat?) {
        guard configuration.readingWidth != width else { return }
        configuration.readingWidth = width
        let clipWidth = enclosingScrollView?.contentView.bounds.width
            ?? superview?.bounds.width ?? frame.width
        if let width, let container = textContainer {
            container.widthTracksTextView = false
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        } else if let container = textContainer {
            container.widthTracksTextView = true
        }
        applyManagedFrameSize(width: clipWidth)
        if width != nil {
            centerReadingColumn(forClipWidth: clipWidth)
        } else if abs(frame.origin.x) > 0.5 {
            setFrameOrigin(NSPoint(x: 0, y: frame.origin.y))
        }
        scheduleTableRestyleForReadingWidth()
    }

    /// Re-measure the document's tables for a reading column that just changed.
    ///
    /// A table's column widths — and whether it is wide enough to scroll at all
    /// — are measured for the width it was styled at. Nothing else re-measures
    /// them under a reading column: the frame keeps the column's fixed width, so
    /// the width-change restyle in `setFrameSize` never fires. That is the width
    /// error from step 3; without this a table styled for the provisional width
    /// (925 pt for an 800-pt window on the Mini) stays that wide inside a 736-pt
    /// column and spills out of it.
    ///
    /// Coalesced and deferred to the end of a live resize, because the embedder
    /// recomputes the reading width from the window geometry: dragging the
    /// window edge or the sidebar divider calls this once per frame, and the
    /// restyle re-measures every table in the document at a width no frame
    /// shares with the next, so every measurement misses the layout cache.
    private func scheduleTableRestyleForReadingWidth() {
        // Not during a staged open: `finishStagedStyling` does the same pass once
        // against the settled width, and doing it per turn would restyle every
        // table paragraph of a large document repeatedly.
        guard !contentHeightIsEstimated else { return }
        guard !pendingTableWidthRestyle else { return }
        pendingTableWidthRestyle = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTableWidthRestyle = false
            // Still resizing: the width is not the one to measure for yet.
            // `viewDidEndLiveResize` runs the pass once the drag settles.
            guard !self.inLiveResize else {
                self.needsTableWidthRestyleAfterResize = true
                return
            }
            self.restyleTableParagraphsForWidthChange()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard needsTableWidthRestyleAfterResize else { return }
        needsTableWidthRestyleAfterResize = false
        restyleTableParagraphsForWidthChange()
    }

    func centerReadingColumn(forClipWidth clipWidth: CGFloat) {
        guard configuration.readingWidth != nil,
              let container = superview as? NativeTextViewContainer else { return }
        if abs(container.frame.size.width - clipWidth) > 0.5 {
            var f = container.frame
            f.size.width = max(clipWidth, 0)
            container.frame = f
        }
        let originX = floor(max(0, (clipWidth - readingColumnWidth) / 2))
        let delta = originX - frame.origin.x
        if abs(delta) > 0.5 {
            setFrameOrigin(NSPoint(x: originX, y: frame.origin.y))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if isApplyingManagedFrameSize {
            super.setFrameSize(newSize)
            return
        }

        guard let scrollView = enclosingScrollView else {
            baseContentHeight = max(newSize.height, 0)
            super.setFrameSize(newSize)
            return
        }

        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        if widthChanged {
            pendingFullLayoutMeasure = true   // re-wrap → re-measure height against a full layout
            isApplyingManagedFrameSize = true
            super.setFrameSize(NSSize(width: newSize.width, height: frame.size.height))
            isApplyingManagedFrameSize = false
        }

        recalcOverscroll(for: scrollView, targetWidth: newSize.width, debugTag: "setFrameSize")

        // Width change → only rendered table paragraphs need restyling. Their image
        // width can change, and an initially narrow table can become scrollable.
        if widthChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.configuration.readingWidth == nil {
                    self.restyleTableParagraphsForWidthChange()
                }
            }
        }
    }

    /// Restyle only table paragraphs via stamped anchor ranges; avoids re-tokenizing the doc.
    func restyleTableParagraphsForWidthChange() {
        guard let storage = textStorage,
              let coord = delegate as? NativeTextViewCoordinator else { return }
        var ranges: [NSRange] = []
        var seen: Set<String> = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.scrollableBlockFullRange, in: fullRange, options: []) { value, _, _ in
            guard let v = value as? NSValue else { return }
            let r = v.rangeValue
            let key = "\(r.location):\(r.length)"
            if seen.insert(key).inserted { ranges.append(r) }
        }
        // A source ID is a content hash, so editing a table's cells orphans its
        // scroll offset. This walk already has the document open; drop what no
        // anchor claims any more, the way the overlay reconcile used to.
        if !tableHorizontalScrollOffsets.isEmpty {
            var live: Set<Int> = []
            storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, _, _ in
                if let id = value as? Int { live.insert(id) }
            }
            tableHorizontalScrollOffsets = tableHorizontalScrollOffsets.filter { live.contains($0.key) }
        }
        guard !ranges.isEmpty else { return }
        coord.restyleParagraphs(ranges, in: self)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        // Runs from inside AppKit's post-edit processing — outside every
        // sequential span; accumulate so the frame stops hiding it.
        PerfTrace.accumulate("reveal") { revealRangeIfNeeded(range) }
    }

    private func revealRangeIfNeeded(_ range: NSRange) {
        if suppressAutoRevealOnce {
            suppressAutoRevealOnce = false
            return
        }
        if configuration.heightBehavior == .fitsContent {
            // The inner scroll view has no scrollable range, so the default
            // scrollRangeToVisible does nothing useful. Propagate the caret rect
            // to the enclosing (page-level) scroll view so it keeps the caret
            // on-screen. AppKit's scrollRectToVisible propagation can stall at
            // a nested NSScrollView boundary, so we walk up explicitly.
            super.scrollRangeToVisible(range)
            propagateCaretRevealToEnclosingScroller(range: range)
            return
        }
        // Only the reading column needs manual reveal; default keeps AppKit's native implementation.
        guard configuration.readingWidth != nil else {
            super.scrollRangeToVisible(range)
            return
        }
        // Explicit reveal: native scrollRangeToVisible can't position the container's centered subview.
        // A caret at the document end has no fragment at its location; step back one
        // char there so the last line's fragment is found (else nothing reveals).
        let docLength = (self.string as NSString).length
        let revealOffset = min(range.location, max(0, docLength - 1))
        guard let tlm = textLayoutManager,
              let scrollView = enclosingScrollView,
              let start = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: revealOffset) else {
            super.scrollRangeToVisible(range)
            return
        }
        if contentHeightIsEstimated {
            // A staged open has not laid the document out yet. The enumeration below
            // reads the caret's position once, and a settle inside it does not refresh
            // that reading, so lay out up to the caret first; and grow the frame to the
            // extrapolated height, or the scroll is cut off at the estimate.
            let upToCaret = min(range.location + 1, docLength)
            PerfTrace.accumulate("revealSettle") { layOutFragments(from: 0, to: upToCaret) }
            raiseEstimatedContentHeight(laidOutThrough: upToCaret, for: scrollView)
        }
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let cv = scrollView.contentView
            let insetsTop = scrollView.contentInsets.top
            // Reveal the CARET's line, not the whole layout fragment. An active image/latex embed
            // renders its block below the source line via paragraphSpacing, so layoutFragmentFrame is
            // as tall as the image; revealing its maxY would scroll the viewport down by the block
            // height even though the caret sits on the source line at the top. Frames are text-view-
            // local; lift by the text view's offset inside the container (the header band).
            var revealRect = fragment.layoutFragmentFrame
            // Reveal the ACTUAL caret location's segment (not the stepped-back revealOffset), so a
            // freshly soft-wrapped last line at the document end still scrolls into view; fall back to
            // the stepped-back offset only when the true end-of-document has no segment of its own.
            func caretSegmentRect(fallback: CGRect) -> CGRect {
                var rect = fallback
                for segOffset in [min(range.location, docLength), revealOffset] {
                    guard let segLoc = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: segOffset) else { continue }
                    var found = false
                    tlm.enumerateTextSegments(in: NSTextRange(location: segLoc), type: .standard, options: []) { _, segFrame, _, _ in
                        if segFrame.height > 0 { rect = segFrame; found = true }   // caret rect = its line, not the block
                        return false
                    }
                    if found { break }
                }
                return rect
            }
            revealRect = caretSegmentRect(fallback: revealRect)
            var frame = revealRect.offsetBy(dx: 0, dy: self.frame.origin.y)
            let visibleTop = cv.bounds.origin.y + insetsTop
            let visibleBottom = cv.bounds.origin.y + cv.bounds.height
            let margin: CGFloat = 24
            if frame.minY < visibleTop || frame.maxY > visibleBottom {
                // The caret's Y is the sum of the fragment heights above it;
                // while any of those are estimate-only (a table image estimates
                // as one text line, ~250pt short), the caret reads far too high
                // and typing "reveals" upward. Settle layout up to the caret
                // before trusting an out-of-view verdict — spurious ones then
                // dissolve, genuine jumps get the correct target. Free when the
                // caret is already visible (the common per-keystroke case).
                if let end = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: min(range.location + 1, docLength)),
                   let settleRange = NSTextRange(location: tlm.documentRange.location, end: end) {
                    // O(doc-start → caret) real layout — the prime suspect
                    // whenever `+reveal` dominates a frame.
                    PerfTrace.accumulate("revealSettle") { tlm.ensureLayout(for: settleRange) }
                }
                revealRect = caretSegmentRect(fallback: revealRect)
                frame = revealRect.offsetBy(dx: 0, dy: self.frame.origin.y)
            }
            let targetY: CGFloat
            if frame.minY < visibleTop {
                targetY = frame.minY - insetsTop - margin
            } else if frame.maxY > visibleBottom {
                targetY = frame.maxY - cv.bounds.height + margin
            } else {
                return false   // already visible (or a spurious verdict, corrected)
            }
            PerfTrace.stamp("reveal", 0, "target=\(Int(targetY)) caretY=\(Int(frame.minY)) frameH=\(Int(self.frame.height)) estimated=\(contentHeightIsEstimated)")
            (scrollView as? ClampedScrollView)?.cancelPendingScrollRestore()
            cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(cv)
            (scrollView as? ClampedScrollView)?.clampToInsets()
            return false
        }
    }

    /// Walk the view hierarchy above the inner scroll view to find the
    /// enclosing (page-level) scroller and ask it to reveal the caret rect.
    /// Used in `.fitsContent` where the inner scroll view cannot scroll.
    private func propagateCaretRevealToEnclosingScroller(range: NSRange) {
        guard let innerScrollView = enclosingScrollView,
              let tlm = textLayoutManager,
              let start = tlm.textContentManager?.location(
                  tlm.documentRange.location, offsetBy: range.location
              ) else { return }
        // Compute the caret rect in window coordinates so we can convert it
        // into whichever enclosing scroller we find.
        var caretRect: CGRect?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            caretRect = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: self.frame.origin.y)
            return false
        }
        guard let rect = caretRect else { return }
        // Convert from document-view space (container) to the inner scroll
        // view's coordinate space, then to window, so we can convert into
        // any ancestor we find.
        let container = innerScrollView.documentView ?? self
        let rectInWindow = container.convert(rect, to: nil)
        // Walk up past the inner scroll view looking for a parent NSScrollView.
        var view: NSView? = innerScrollView.superview
        while let v = view {
            if let outerScrollView = v as? NSScrollView, outerScrollView !== innerScrollView {
                guard let outerDocView = outerScrollView.documentView else { return }
                let rectInOuter = outerDocView.convert(rectInWindow, from: nil)
                outerDocView.scrollToVisible(rectInOuter)
                return
            }
            view = v.superview
        }
    }

    /// Force TextKit 2 to lay out all fragments within the current visible rect.
    /// Walks from the document head, not the viewport: a fragment's Y is the
    /// sum of the heights above it, so leaving anything above merely estimated
    /// shifts the visible content when it later settles. A viewport-scoped walk
    /// (tried as a perf win) caused content shifts, spurious caret reveals, and
    /// a bistable frame height; steady-state cost here is an enumeration over
    /// already-laid-out fragments.
    func ensureVisibleLayout() {
        guard let tlm = textLayoutManager else { return }
        let visBot = visibleRect.maxY
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragment.layoutFragmentFrame.minY <= visBot
        }
    }
}
