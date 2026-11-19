//
//  MarkdownStyler+Diagrams.swift
//  MarkdownEngine
//
//  Fenced code blocks of a diagram language (```mermaid …```) render as an
//  image while the caret is outside the block, through the embedder's
//  `DiagramRenderer`. The block collapses exactly like a block formula; with
//  the caret inside, or without a rendered image, it stays a code block.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleDiagramBlocks(_ ctx: StylingContext) -> [StyledRange] {
        let renderer = ctx.services.diagrams
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.scoped(ctx.codeBlockIndexed) {
            guard !ctx.activeTokenIndices.contains(idx),
                  token.contentRange.length > 0,
                  let language = MarkdownTokenizer.extractLanguage(from: token, in: ctx.nsText as String)?.lowercased(),
                  renderer.handles(language: language) else { continue }
            let source = ctx.nsText.substring(with: token.contentRange)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let result = renderer.diagram(for: DiagramRequest(language: language, source: source)),
                  result.size.width > 0, result.size.height > 0 else { continue }

            let config = ctx.configuration.imageEmbed
            let maxWidth: CGFloat = {
                if let tc = ctx.layoutBridge?.firstTextContainer {
                    let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                    if w > 0 && w < config.unreasonableMaxWidth { return w }
                }
                return config.fallbackMaxWidth
            }()
            let scale = min(1, maxWidth / result.size.width)
            let bounds = CGRect(x: 0, y: 0, width: result.size.width * scale, height: result.size.height * scale)

            let rendered = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: result.image,
                imageBounds: bounds,
                paragraphSpacingBefore: config.paragraphSpacing,
                paragraphSpacing: config.paragraphSpacing,
                alignment: .center,
                mode: .collapsedSource(markerTexts: []),
                restyleOnWidthChange: true,
                ctx: ctx,
                attrs: &attrs
            )
            if rendered {
                // The code styling filled the block with the code background,
                // which the fragment would paint full-width behind the image.
                attrs.append((token.range, [.backgroundColor: NSColor.clear]))
            }
        }
        return attrs
    }
}
