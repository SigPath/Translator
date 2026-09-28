import AppKit
import SwiftUI

/// Owns the floating, non-activating panel that shows live subtitles over
/// whatever app the user is in (typically a video call window) while
/// translating — M2b. Built directly on `NSPanel`/AppKit rather than a
/// SwiftUI `Window` scene: SwiftUI's window scenes don't expose the
/// non-activating + floating-level + borderless combination a subtitle
/// overlay needs (it must float above the call window but never steal
/// keyboard focus or bring the app itself to the front, which would
/// interrupt the call).
///
/// Fixed-size panel (`panelSize`), not one that grows/shrinks to fit
/// content: real captions (Teams/Zoom) use a stable box for the same
/// reason — text that resizes its container on every update is harder to
/// track with a glance than text that truncates within a fixed box. See
/// `SubtitlesOverlayView`.
///
/// The `NSPanel` itself is created lazily, on the first `show()` call, not
/// in `init()`: this controller is constructed very early (inside
/// `MBTranslatorApp.init()`, before the app has finished launching), and
/// creating AppKit windows that early — while very likely safe in practice
/// — isn't something worth risking without a real Mac to verify it on; a
/// window that's only ever created once the user actually clicks Start has
/// no such question mark over it.
@MainActor
final class SubtitlesPanelController {
    static let panelSize = NSSize(width: 560, height: 110)

    private let subtitles: SubtitlesState
    private var panel: NSPanel?

    init(subtitles: SubtitlesState) {
        self.subtitles = subtitles
    }

    /// Shows the panel without activating the app or taking focus —
    /// `orderFrontRegardless()`, not `makeKeyAndOrderFront(_:)`, is
    /// deliberate: the latter would try to make the panel key, which the
    /// `NonActivatingPanel` override below refuses anyway, but staying with
    /// the "regardless" ordering call keeps the intent explicit at the call
    /// site too.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.floating` is the standard level for always-on-top HUD/utility
        // windows (matches system OSDs like the volume overlay) and is
        // known to work above normal windowed apps. Whether it's enough to
        // stay visible over a video-call app running in *true* full-screen
        // mode (not just full-screen-space-switching) hasn't been verified
        // on a real Mac yet — if testing shows the panel disappearing there,
        // raising this to `.screenSaver` is the fix to try. Deliberately not
        // set that high pre-emptively: very high window levels also sit
        // above system UI (Spotlight, notification banners), which would be
        // more intrusive than this glance-at overlay should be.
        panel.level = .floating
        // Follow the user to whatever Space/Desktop their call window is
        // on, including a Space running one of *our own* app's windows
        // full-screen (`.fullScreenAuxiliary`) — not guaranteed to cover
        // another app's full-screen window, see the `level` comment above.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // SwiftUI content draws its own shadow (`SubtitlesOverlayView`'s
        // rounded background), which respects the rounded corners; the
        // window-level shadow below is a plain rectangle that would show as
        // an ugly halo around the transparent margins, so it's off.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // `NSPanel` defaults `hidesOnDeactivate` to `true` (unlike
        // `NSWindow`) — this app is essentially never the frontmost/active
        // app while this panel is showing (it's an `LSUIElement` accessory
        // app whose whole point here is to float over some *other*
        // frontmost app, e.g. a call), so the default would hide the panel
        // almost immediately after it appears.
        panel.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: SubtitlesOverlayView(subtitles: subtitles))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hostingView

        positionInitially(panel)
        return panel
    }

    /// Restores wherever the user last dragged the panel to (persisted by
    /// AppKit itself via the frame-autosave mechanism, keyed by name); falls
    /// back to a sensible default — bottom-center of the main screen, clear
    /// of the Dock — the first time the app ever shows it.
    private func positionInitially(_ panel: NSPanel) {
        let autosaveName = "SubtitlesPanel"
        panel.setFrameAutosaveName(autosaveName)
        guard !panel.setFrameUsingName(autosaveName) else { return }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = Self.panelSize
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}

/// `canBecomeKey`/`canBecomeMain` overridden to `false`: this panel must
/// never take keyboard focus or activate the app — it's a glanceable
/// overlay over a video call, not a window the user interacts with via
/// keyboard. Dragging via `isMovableByWindowBackground` works without key
/// status.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
