import SwiftUI
import MultiTaskCore

/// Presentation for the core's semantic types.
///
/// These live here rather than on the types themselves because `MultiTaskCore`
/// imports Foundation only — a `Color` property on `SessionStatus` is what used
/// to make the models un-portable, and moving it out is what let the engine
/// build and test on Linux.
/// Maps the generated `DesignTokens` onto SwiftUI types.
///
/// The values are **not** defined here — they come from `DESIGN.json` through
/// `DesignTokens`, so the Windows client reads the same numbers instead of a
/// second hand-maintained copy that drifts by two points at a time. This file is
/// only the translation into `CGFloat`, `Color`, and `Font`, which is the part
/// that genuinely cannot be shared.
enum AppTheme {
    // MARK: Spacing

    /// Between lines that belong to one thought.
    static let hairSpacing = CGFloat(DesignTokens.Spacing.hair)
    static let tightSpacing = CGFloat(DesignTokens.Spacing.tight)
    /// Between distinct rows.
    static let rowSpacing = CGFloat(DesignTokens.Spacing.row)
    /// Inside a grouped, bordered block.
    static let rowPadding = CGFloat(DesignTokens.Spacing.group)
    static let sectionSpacing = CGFloat(DesignTokens.Spacing.section)
    static let loosePadding = CGFloat(DesignTokens.Spacing.loose)
    /// Empty states only — the one screen nobody is scanning.
    static let spaciousPadding = CGFloat(DesignTokens.Spacing.spacious)

    // MARK: Shape

    static let controlRadius = CGFloat(DesignTokens.Radius.control)
    static let groupRadius = CGFloat(DesignTokens.Radius.group)

    // MARK: Size

    static let popoverWidth = CGFloat(DesignTokens.Size.popoverWidth)
    static let sheetWidth = CGFloat(DesignTokens.Size.sheetWidth)
    static let settingsWidth = CGFloat(DesignTokens.Size.settingsWidth)
    /// A run's state, on its own line.
    static let statusDot = CGFloat(DesignTokens.Size.statusDot)
    /// A marker beside caption text, where the larger dot reads as chunky.
    static let inlineDot = CGFloat(DesignTokens.Size.inlineDot)
    static let statusGlyph = CGFloat(DesignTokens.Size.statusGlyph)
    static let iconSmall = CGFloat(DesignTokens.Size.iconSmall)
    /// Aligns content nested under a row with the glyph above it.
    static let nestedIndent = CGFloat(DesignTokens.Size.nestedIndent)

    // MARK: Type

    /// Monospaced, for a command or a path — text where misreading a flag is the
    /// failure the text exists to prevent.
    static let monoDetail = Font.system(size: CGFloat(DesignTokens.FontSize.monoDetail),
                                        design: .monospaced)
    static let monoDense = Font.system(size: CGFloat(DesignTokens.FontSize.monoDense),
                                       design: .monospaced)
    /// A small glyph, not prose — so a fixed size is correct here.
    static let glyphFont = Font.system(size: CGFloat(DesignTokens.FontSize.glyphAffordance))
    /// An inline meta icon — smaller than a status glyph, larger than an affordance.
    static let iconFont = Font.system(size: CGFloat(DesignTokens.Size.iconSmall))
    /// A row's status glyph.
    static let statusGlyphFont = Font.system(size: CGFloat(DesignTokens.Size.statusGlyph))

    static let sectionTitle = Font.headline
    static let rowTitle = Font.callout
    static let rowDetail = Font.caption
    static let rowMeta = Font.caption2

    // MARK: Colour

    /// Something is waiting on the person. The one role permitted to interrupt.
    static let attentionColor = color(.attention)
    /// Progressing on its own. Deliberately *not* green — see `completeColor`.
    static let workingColor = color(.working)
    /// Finished. Green lives here and nowhere else.
    static let completeColor = color(.complete)
    /// Available to pick up.
    static let readyColor = color(.ready)
    static let blockedColor = color(.blocked)
    static let dormantColor = color(.dormant)
    static let idleColor = color(.idle)
    static let unknownColor = color(.unknown)
    /// Finished, and fine. Reads as settled rather than as a success to celebrate.
    static let calmColor = color(.dormant)

    static let groupFill = DesignTokens.Emphasis.groupFill
    static let groupBorder = DesignTokens.Emphasis.groupBorder

    /// Resolves a role to the macOS **system** colour named in `DESIGN.json`.
    ///
    /// System colours rather than the fallback hexes, because they already meet
    /// contrast in both appearances and already respond to Increase Contrast and
    /// the colour-blind accommodations — none of which a hand-picked hex re-earns.
    /// The fallback is used only if a name ever fails to resolve, which would
    /// otherwise render as invisible text.
    static func color(_ role: DesignTokens.ColorRole) -> Color {
        switch role {
        case .attention: return Color(nsColor: .systemOrange)
        case .working: return Color(nsColor: .controlAccentColor)
        case .complete: return Color(nsColor: .systemGreen)
        case .ready: return Color(nsColor: .controlAccentColor)
        case .idle: return Color(nsColor: .systemYellow)
        case .blocked: return Color(nsColor: .systemPurple)
        case .dormant: return Color(nsColor: .secondaryLabelColor)
        case .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    // MARK: Motion

    /// Animation for direct manipulation only.
    static let disclosure = Animation.easeOut(duration: DesignTokens.Motion.disclosure)

    /// Deliberately **no** animation for a data refresh. A row that slides when a
    /// number changes makes a list that updates every few seconds feel
    /// unreliable, and this is a surface read in a glance while thinking about
    /// something else.
    static let refresh: Animation? = nil
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .working: return AppTheme.workingColor
        case .needsAttention: return AppTheme.attentionColor
        case .complete: return AppTheme.completeColor
        // Grey, not the project role's yellow. One session going quiet while
        // its siblings work is ordinary; a whole project going quiet is the
        // waste this app watches for. Same word, different stakes.
        case .idle: return AppTheme.dormantColor
        case .unknown: return AppTheme.unknownColor
        }
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .needsYou: return AppTheme.attentionColor
        case .working: return AppTheme.workingColor
        case .ready: return AppTheme.readyColor
        case .idle: return AppTheme.idleColor
        case .blocked: return AppTheme.blockedColor
        case .dormant: return AppTheme.dormantColor
        }
    }

    var symbolName: String {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .working: return "circle.fill"
        case .ready: return "arrow.right.circle.fill"
        case .blocked: return "pause.circle.fill"
        // An hourglass, not a pause: nothing is holding this project up, time is
        // simply passing while nothing happens to it.
        case .idle: return "hourglass"
        case .dormant: return "moon.zzz.fill"
        }
    }
}

extension WaitingReason {
    var symbolName: String {
        switch self {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Formats activity timestamps as compact relative strings.
enum RelativeTime {
    static func string(from date: Date, status: SessionStatus) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let elapsed = compact(seconds)
        switch status {
        case .needsAttention: return "waiting \(elapsed)"
        case .complete: return "finished \(elapsed) ago"
        case .working: return seconds < 5 ? "now" : "\(elapsed) ago"
        default: return "\(elapsed) ago"
        }
    }

    static func ago(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        return seconds < 5 ? "just now" : "\(compact(seconds)) ago"
    }

    static func compact(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
