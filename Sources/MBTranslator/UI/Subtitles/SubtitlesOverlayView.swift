import AppKit
import SwiftUI

/// Content of the floating M2b subtitles panel. Deliberately a **fixed-size**
/// caption bar (see `SubtitlesPanelController`) rather than one that resizes
/// to hug its content on every update: real captions (Teams/Zoom) use a
/// stable box too, so the eye doesn't have to re-find text that jumps around
/// the screen mid-sentence.
///
/// PL and EN each get a **reserved, fixed-height slot** (`sourceSlotHeight`/
/// `translationSlotHeight`, sized for their worst case: 2 wrapped lines at
/// each block's font size) rather than just flowing one after another in the
/// `VStack` — with the original implementation, a long sentence could grow
/// past its natural single-line height enough to visually run into the
/// other block before either hit its `lineLimit`/panel-edge clipping (see
/// docs/DECISIONS.md, "Follow-up: nakładający się tekst w M2b"). Reserving
/// the slot up front means the two blocks can never overlap regardless of
/// content length. Long text wraps (up to 2 lines) rather than growing the
/// box; `minimumScaleFactor` is a safety net that shrinks the font slightly
/// for the rare sentence that still doesn't fit its slot at 2 lines, so it
/// stays fully visible instead of being clipped — the panel is sized
/// generously enough (see `SubtitlesPanelController.panelSize`) that this
/// should rarely, if ever, actually kick in for a normal-length sentence.
struct SubtitlesOverlayView: View {
    let subtitles: SubtitlesState

    private static let sourceFont = Font.system(size: 16, weight: .regular)
    private static let translationFont = Font.system(size: 21, weight: .semibold)
    private static let sourceSlotHeight: CGFloat = 44
    private static let translationSlotHeight: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if !subtitles.sourceFinal.isEmpty {
                    Text(subtitles.sourceFinal)
                        .foregroundStyle(.white.opacity(0.75))
                } else if !subtitles.sourcePartial.isEmpty {
                    Text(subtitles.sourcePartial)
                        .foregroundStyle(.white.opacity(0.5))
                        .italic()
                } else {
                    Text("Słucham…")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(Self.sourceFont)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: Self.sourceSlotHeight, alignment: .topLeading)

            Text(subtitles.translationFinal)
                .font(Self.translationFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: Self.translationSlotHeight, alignment: .topLeading)
                .opacity(subtitles.translationFinal.isEmpty ? 0 : 1)
        }
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: SubtitlesPanelController.panelSize.width, height: SubtitlesPanelController.panelSize.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.72))
        )
        // A hairline border keeps the panel legible over both very light and
        // very dark call/desktop backgrounds, where a drop shadow alone can
        // disappear.
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
