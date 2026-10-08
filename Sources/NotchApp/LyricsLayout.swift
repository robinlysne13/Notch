import CoreGraphics

/// Where the lyric sheet has to sit for one line to be in the middle of the panel.
///
/// The sheet is slid rather than scrolled, so its position is arithmetic rather than something
/// the framework works out: the line being sung is centred by offsetting the whole column by the
/// height of everything above it. Lyric lines wrap, so those heights have to be measured, and a
/// line that has not been measured yet stands in at `estimatedRow` until it has.
struct LyricsLayout {
    let spacing: CGFloat
    /// Stands in for a line not yet measured.
    let estimatedRow: CGFloat

    /// The vertical offset that centres `index` in a panel `viewport` tall.
    ///
    /// Before the first line is sung there is no current line, so the sheet waits with its
    /// opening line centred.
    func offset(centring index: Int?, of count: Int, in viewport: CGFloat, heights: [Int: CGFloat]) -> CGFloat {
        guard count > 0, viewport > 0 else { return 0 }
        let index = min(max(index ?? 0, 0), count - 1)
        var above: CGFloat = 0
        for row in 0..<index {
            above += height(of: row, in: heights) + spacing
        }
        return viewport / 2 - above - height(of: index, in: heights) / 2
    }

    private func height(of row: Int, in heights: [Int: CGFloat]) -> CGFloat {
        heights[row] ?? estimatedRow
    }
}

extension LyricsLayout {
    /// How far the sheet may be slid by hand: from its opening line centred to its closing line
    /// centred, so browsing cannot push every lyric off the panel.
    func browsing(_ count: Int, in viewport: CGFloat, heights: [Int: CGFloat]) -> ClosedRange<CGFloat> {
        guard count > 0, viewport > 0 else { return 0...0 }
        let first = offset(centring: 0, of: count, in: viewport, heights: heights)
        let last = offset(centring: count - 1, of: count, in: viewport, heights: heights)
        // Centring a later line means sliding the sheet further up, so `last` is the lower bound.
        return min(first, last)...max(first, last)
    }

    /// `offset` held inside the browsing range.
    func clamped(
        _ offset: CGFloat,
        count: Int,
        in viewport: CGFloat,
        heights: [Int: CGFloat]
    ) -> CGFloat {
        let range = browsing(count, in: viewport, heights: heights)
        return min(max(offset, range.lowerBound), range.upperBound)
    }
}
