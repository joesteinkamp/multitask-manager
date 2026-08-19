import SwiftUI
import AppKit
import MultiTaskCore

@main
struct MultiTaskManagerApp: App {
    @StateObject private var store = SessionStore()

    init() {
        // The notification presenter needs a way back to the store so its
        // "Open" action can focus the right session. Set once, at launch.
        NotificationPresenter.store = nil
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .onAppear { NotificationPresenter.store = store }
        } label: {
            // The ambient channel. It answers one question — is anything waiting
            // on me — and spends colour exactly once to answer it.
            //
            // **Colour appears only when you must act.** A menu bar with no
            // colour in it is then a fact you can read without focusing, which
            // is the most valuable thing this surface can offer. Working is
            // shown, in the bar's own ink, because work in flight is news you
            // are allowed to ignore.
            //
            // The glyph changes with the state as well as the colour: outline →
            // filled → bell is legible in greyscale, to a colour-blind reader,
            // and in a screenshot. Colour is the accelerator, never the message.
            Image(nsImage: MenuBarIcon.image(for: store.barState))
            if let count = store.barState.count {
                Text("\(count)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// Draws the menu bar icon for a state.
///
/// Built as an `NSImage` rather than a SwiftUI `Image` because macOS renders a
/// menu bar label as a *template* — flattening it to the bar's own ink and
/// discarding any tint. A non-template image is the supported way to keep a
/// colour, and it is used for exactly one state.
enum MenuBarIcon {

    static func image(for state: BarState) -> NSImage {
        switch state {
        case .needsYou:
            // The one coloured thing in the bar. Orange survives on both light
            // and dark menu bars, which a subtler tint would not.
            return symbol("bell.badge.fill", tint: .systemOrange,
                          describedAs: "Waiting on you")
        case .working:
            return symbol("square.stack.3d.up.fill", tint: nil,
                          describedAs: "Agents working")
        case .complete:
            return symbol("checkmark.circle", tint: nil,
                          describedAs: "Finished")
        case .calm:
            return symbol("square.stack.3d.up", tint: nil,
                          describedAs: "Nothing waiting")
        }
    }

    private static func symbol(_ name: String, tint: NSColor?,
                               describedAs description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        guard let tint else {
            // Template: macOS inverts it with the menu bar, which is what every
            // other icon up there does and what these states should do too.
            base.isTemplate = true
            return base
        }

        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.accessibilityDescription = description
        return tinted
    }
}
