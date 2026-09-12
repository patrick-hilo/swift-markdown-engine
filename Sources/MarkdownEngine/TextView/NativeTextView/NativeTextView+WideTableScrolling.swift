//
//  NativeTextView+WideTableScrolling.swift
//  MarkdownEngine
//
//  Horizontal scrolling for tables that are wider than their column.
//
//  The table is drawn by its layout fragment, clipped to the column and shifted
//  by an offset kept per table in `tableHorizontalScrollOffsets`. This file owns
//  what keeps that usable: turning a gesture or a drag of the drawn scroller
//  into a new offset, and getting the fragment to repaint with it.
//

import AppKit

extension NativeTextView {

    /// What a scroll gesture is moving, decided once and then held for the
    /// whole gesture.
    ///
    /// The first events of a trackpad gesture carry no delta at all, so the
    /// decision cannot be made when the gesture begins; it waits for the first
    /// event that moved something and stands from then on.
    enum WideTableScrollGesture {
        case undecided
        case table(sourceID: Int, box: CGRect)
        case document
    }

    /// One step of a scroll gesture, as far as this file cares.
    ///
    /// `discrete` is a legacy mouse wheel or a shift-wheel: a single event with
    /// no gesture around it, decided and released within itself.
    enum WideTableScrollStep {
        case began, changed, ended, momentum, momentumEnded, discrete
    }

    // MARK: - Scroll gesture

    override func scrollWheel(with event: NSEvent) {
        endTableCellEditing()
        let step: WideTableScrollStep
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            step = .began
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            step = .ended
        } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            step = .momentumEnded
        } else if !event.momentumPhase.isEmpty {
            step = .momentum
        } else if !event.phase.isEmpty {
            step = .changed
        } else {
            step = .discrete
        }
        let consumed = handleWideTableScroll(
            step: step,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            at: convert(event.locationInWindow, from: nil)
        )
        if consumed { return }
        super.scrollWheel(with: event)
    }

    /// Moves a wide table's content instead of the document, and reports whether
    /// it took the step.
    ///
    /// The axis is decided once per gesture, the way `NSScrollView`'s
    /// predominant-axis scrolling does it and the hosting scroll view used to.
    /// Deciding per step on raw deltas would hand the table every frame of a
    /// vertical flick whose horizontal noise happens to win, and the momentum
    /// tail — where the vertical delta decays toward zero while the horizontal
    /// jitter does not — would creep the table sideways under a reader who never
    /// scrolled it sideways. The decision needs a clear margin, so a diagonal
    /// gesture stays with the document, and it waits for the first step that
    /// moved something: the first events of a trackpad gesture carry no delta at
    /// all, so there is nothing to decide on when the gesture begins.
    ///
    /// Momentum needs no arithmetic of its own — the decaying deltas move the
    /// offset like any other step — but it never decides anything: a tail can
    /// only continue a gesture the table already owns. At either end the offset
    /// clamps and the step is still taken, so a gesture that runs into the edge
    /// stops there instead of turning into a vertical scroll halfway through.
    func handleWideTableScroll(
        step: WideTableScrollStep,
        deltaX: CGFloat,
        deltaY: CGFloat,
        at viewPoint: CGPoint
    ) -> Bool {
        switch step {
        case .began: wideTableScrollGesture = .undecided
        case .discrete: wideTableScrollGesture = nil
        default: break
        }
        defer { if step == .momentumEnded { wideTableScrollGesture = nil } }

        let gesture: WideTableScrollGesture
        switch step {
        case .momentum, .momentumEnded:
            guard let latched = wideTableScrollGesture else { return false }
            gesture = latched
        case .discrete:
            guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return false }
            gesture = decideWideTableScroll(deltaX: deltaX, deltaY: deltaY, at: viewPoint)
        case .began, .changed, .ended:
            if let latched = wideTableScrollGesture, case .undecided = latched {
                guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return false }
                let decided = decideWideTableScroll(deltaX: deltaX, deltaY: deltaY, at: viewPoint)
                wideTableScrollGesture = decided
                gesture = decided
            } else {
                guard let latched = wideTableScrollGesture else { return false }
                gesture = latched
            }
        }
        guard case let .table(sourceID, latchedBox) = gesture else { return false }

        // Re-resolve from the box's middle: the header band can move the table
        // under the pointer while the gesture runs.
        guard let scrollable = wideTableBox(at: CGPoint(x: latchedBox.midX, y: latchedBox.midY)),
              scrollable.sourceID == sourceID, scrollable.maxOffset > 0.5 else { return true }

        // Read the offset through the same clamp the drawing applies: after the
        // box grew, the stored value can be past the new end, and comparing the
        // move against it would swallow the gesture's first step.
        let current = min(scrollable.maxOffset, max(0, tableHorizontalScrollOffsets[sourceID] ?? 0))
        let next = min(scrollable.maxOffset, max(0, current - deltaX))
        guard abs(next - current) > 0.01 else { return true }
        setWideTableOffset(next, sourceID: sourceID, box: scrollable.box)
        return true
    }

    /// Whether this gesture belongs to a wide table or to the document.
    private func decideWideTableScroll(deltaX: CGFloat, deltaY: CGFloat, at viewPoint: CGPoint) -> WideTableScrollGesture {
        // Two to one: enough that a gesture meant as vertical keeps its frames.
        guard abs(deltaX) > 2 * abs(deltaY) else { return .document }
        guard let scrollable = wideTableBox(at: viewPoint), scrollable.maxOffset > 0.5 else { return .document }
        return .table(sourceID: scrollable.sourceID, box: scrollable.box)
    }

    // MARK: - Dragging the drawn scroller

    /// A drag of a wide table's drawn scroller in progress.
    struct WideTableScrollerDrag {
        let sourceID: Int
        let box: CGRect
        let track: CGRect
        let knobWidth: CGFloat
        let maxOffset: CGFloat
        /// Where inside the knob the pointer holds it.
        let grab: CGFloat
    }

    /// Starts a drag of a wide table's scroller: a press outside the knob jumps
    /// it under the pointer first, the way a scroller's track click does.
    /// Returns nil when the press is not on a scroller strip.
    ///
    /// The drawn scroller replaces a real `NSScroller` the hosting scroll view
    /// supplied, which could be dragged — without this a reader on a mouse, with
    /// no horizontal scroll axis, has no way to reach the right-hand columns.
    func pressWideTableScroller(at viewPoint: CGPoint) -> WideTableScrollerDrag? {
        guard let scrollable = wideTableBox(at: viewPoint),
              scrollable.maxOffset > 0.5,
              scrollable.scrollerStrip.contains(viewPoint) else { return nil }

        let track = MarkdownTextLayoutFragment.scrollerTrack(for: scrollable)
        let knobWidth = MarkdownTextLayoutFragment.scrollerKnobWidth(for: scrollable)
        let travel = max(0, track.width - knobWidth)
        let current = min(scrollable.maxOffset, max(0, tableHorizontalScrollOffsets[scrollable.sourceID] ?? 0))
        let knobLeft = track.minX + travel * (scrollable.maxOffset > 0 ? current / scrollable.maxOffset : 0)
        let knob = CGRect(x: knobLeft, y: track.minY, width: knobWidth, height: track.height)

        let drag = WideTableScrollerDrag(
            sourceID: scrollable.sourceID,
            box: scrollable.box,
            track: track,
            knobWidth: knobWidth,
            maxOffset: scrollable.maxOffset,
            grab: knob.contains(viewPoint) ? viewPoint.x - knobLeft : knobWidth / 2
        )
        if !knob.contains(viewPoint) { dragWideTableScroller(drag, toPointerX: viewPoint.x) }
        return drag
    }

    /// Moves the knob so the point it was grabbed at sits under `pointerX`.
    func dragWideTableScroller(_ drag: WideTableScrollerDrag, toPointerX pointerX: CGFloat) {
        let travel = max(0, drag.track.width - drag.knobWidth)
        guard travel > 0 else { return }
        let knobLeft = pointerX - drag.grab
        let offset = min(drag.maxOffset, max(0, (knobLeft - drag.track.minX) / travel * drag.maxOffset))
        setWideTableOffset(offset, sourceID: drag.sourceID, box: drag.box)
    }

    /// Mouse-down entry point, called from the text view's `mouseDown`.
    func beginWideTableScrollerDrag(with event: NSEvent) -> Bool {
        guard let drag = pressWideTableScroller(at: convert(event.locationInWindow, from: nil)) else {
            return false
        }
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                            timeout: .infinity, mode: .eventTracking) { tracked, stop in
            guard let tracked, tracked.type != .leftMouseUp else { stop.pointee = true; return }
            self.dragWideTableScroller(drag, toPointerX: self.convert(tracked.locationInWindow, from: nil).x)
        }
        return true
    }

    /// Stores a table's offset and repaints its fragment.
    private func setWideTableOffset(_ offset: CGFloat, sourceID: Int, box: CGRect) {
        guard tableHorizontalScrollOffsets[sourceID] != offset else { return }
        tableHorizontalScrollOffsets[sourceID] = offset
        // The reader moved something; a vertical restore still queued from the
        // open would otherwise yank the viewport out from under the gesture.
        (enclosingScrollView as? ClampedScrollView)?.cancelPendingScrollRestore()
        invalidateFragmentSurface(in: box)
    }

    /// The wide table under `viewPoint`, or nil.
    ///
    /// Resolved through the fragment under the point, not by walking the
    /// document's table anchors: a scroll event arrives per frame, and a
    /// document-wide attribute scan per event would cost O(document) on a file
    /// with 150 tables.
    func wideTableBox(at viewPoint: CGPoint) -> MarkdownTextLayoutFragment.ScrollableBlockBox? {
        // A table's rendering surface can extend beyond the prose container.
        // Resolve its fragment by Y inside that container, then test the actual box.
        let containerWidth = textContainer?.size.width ?? 1
        let lookupX = min(max(0, viewPoint.x - textContainerOrigin.x), max(0, containerWidth - 1))
        let containerPoint = CGPoint(x: lookupX,
                                     y: viewPoint.y - textContainerOrigin.y)
        guard let tlm = textLayoutManager,
              let fragment = tlm.textLayoutFragment(for: containerPoint) as? MarkdownTextLayoutFragment
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        let origin = CGPoint(x: frame.minX + textContainerOrigin.x,
                             y: frame.minY + textContainerOrigin.y)
        return fragment.scrollableBlockBoxes(at: origin).first { $0.box.contains(viewPoint) }
    }

    // MARK: - Repainting one fragment

    /// Repaints the layout fragment covering `rect` (view coordinates).
    ///
    /// TextKit 2 gives every layout fragment its own layer-backed subview whose
    /// frame is the fragment's rendering surface, and `NSTextLayoutFragment.draw`
    /// renders into that view's backing store. Nothing in the public layout API
    /// reaches it once the fragment exists: `invalidateRenderingAttributes`,
    /// `invalidateLayout` on the manager or on the fragment, `layoutViewport`
    /// and `setNeedsDisplay` on the text view all leave the fragment object
    /// standing, and a standing fragment keeps its surface. Only an edit that
    /// makes the manager build a NEW fragment repaints — measured against the
    /// running app on 2026-09-08, `docs/evidence/2026-09-08-fragment-surface-spike`
    /// in the pType repository. That surface cache is why wide tables used to be
    /// hosted in an `NSScrollView` overlay.
    ///
    /// This is the one place in the engine that depends on that view structure,
    /// and it depends on geometry alone — no class name is matched anywhere. The
    /// `setNeedsDisplay` below does nothing today and is the fallback for a macOS
    /// that stops making a view per fragment. Failure mode if the structure
    /// changes: a wide table stops repainting while it is scrolled sideways, no
    /// crash and nothing else affected. `TableFragmentSurfaceTests` is the
    /// tripwire that catches it on a new system version.
    func invalidateFragmentSurface(in rect: CGRect) {
        setNeedsDisplay(rect)
        for surface in fragmentSurfaceViews(covering: rect) {
            surface.setNeedsDisplay(surface.convert(rect, from: self))
        }
    }

    /// Every descendant whose frame covers part of `rect`, in view coordinates.
    ///
    /// Geometry is the whole rule — no class is named and none is skipped, so
    /// nothing here breaks when AppKit renames or reshuffles its private views.
    /// The walk does NOT stop at a view that misses the rect: the surfaces sit
    /// inside a container AppKit leaves at zero height, and a container that
    /// fails the test still has children that pass it.
    func fragmentSurfaceViews(covering rect: CGRect) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            for subview in view.subviews {
                if subview.convert(rect, from: self).intersects(subview.bounds) {
                    found.append(subview)
                }
                walk(subview)
            }
        }
        walk(self)
        return found
    }
}
