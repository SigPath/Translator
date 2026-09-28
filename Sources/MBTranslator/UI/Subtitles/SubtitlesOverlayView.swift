import AppKit
import SwiftUI

/// Content of the floating M2b subtitles panel. Deliberately a **fixed-size**
/// caption bar (see `SubtitlesPanelController`) rather than one that resizes
/// to hug its content on every update: real captions (Teams/Zoom) use a
/// stable box too, so the eye doesn't have to re-find text that jumps around
/// the screen mid-sentence. Long lines truncate instead of growing the box.
struct SubtitlesOverlayView: View {
    let subtitles: SubtitlesState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            .font(.system(size: 15, weight: .regular))
            .lineLimit(2)

            Text(subtitles.translationFinal)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .opacity(subtitles.translationFinal.isEmpty ? 0 : 1)
        }
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
