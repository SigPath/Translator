import AppKit
import SwiftUI

/// Content of the floating M2b subtitles panel. Deliberately a **fixed-size**
/// caption bar (see `SubtitlesPanelController`) rather than one that resizes
/// to hug its content on every update: real captions (Teams/Zoom) use a
/// stable box too, so the eye doesn't have to re-find text that jumps around
/// the screen mid-sentence.
///
/// Since M4 the panel is split in two halves: left = the user's own speech
/// (PL → EN, microphone), right = the remote party in Teams (EN → PL,
/// process tap) — see `CaptionColumn`.
///
/// Within each half, source and translation each get a **reserved, fixed-height slot** (`sourceSlotHeight`/
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            CaptionColumn(
                title: String(localized: "Ty · PL → EN"),
                caption: subtitles.outgoing,
                isActive: subtitles.isOutgoingActive,
                listeningText: String(localized: "Słucham…")
            )

            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1)
                .padding(.vertical, 4)

            CaptionColumn(
                title: String(localized: "Rozmówca · EN → PL"),
                caption: subtitles.incoming,
                isActive: subtitles.isIncomingActive,
                listeningText: String(localized: "Słucham rozmówcy…")
            )
        }
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// One half of the panel. Keeps the M2b fixed-slot layout (see the type
/// doc above): source and translation each get a reserved, fixed-height
/// slot so they can never overlap, whatever the text length.
private struct CaptionColumn: View {
    let title: String
    let caption: LiveCaption
    let isActive: Bool
    let listeningText: String

    private static let sourceFont = Font.system(size: 15, weight: .regular)
    private static let translationFont = Font.system(size: 20, weight: .semibold)
    private static let sourceSlotHeight: CGFloat = 42
    private static let translationSlotHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(isActive ? 0.55 : 0.3))

            Group {
                if !isActive {
                    Text("Wyłączone")
                        .foregroundStyle(.white.opacity(0.3))
                } else if !caption.sourceFinal.isEmpty {
                    Text(caption.sourceFinal)
                        .foregroundStyle(.white.opacity(0.75))
                } else if !caption.sourcePartial.isEmpty {
                    Text(caption.sourcePartial)
                        .foregroundStyle(.white.opacity(0.5))
                        .italic()
                } else {
                    Text(listeningText)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(Self.sourceFont)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: Self.sourceSlotHeight, alignment: .topLeading)

            Text(caption.translationFinal)
                .font(Self.translationFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: Self.translationSlotHeight, alignment: .topLeading)
                .opacity(isActive && !caption.translationFinal.isEmpty ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
