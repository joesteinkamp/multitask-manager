// Generated from DESIGN.json by Scripts/generate-tokens.py. Do not edit.
//
// Edit DESIGN.json and re-run the script; `DesignTokensTests` fails if this file
// and DESIGN.json disagree.
//
// Foundation only, like the rest of MultiTaskCore. These are raw values; each
// platform maps them to its own types. That is what keeps the macOS and Windows
// interfaces from drifting by two points of padding and one shade of orange.

import Foundation


/// Every constant the interfaces share, generated from `DESIGN.json`.
///
/// Values, not appearances: `Double` and `String`, so this compiles on Linux in
/// CI and on Windows in the client that has no SwiftUI to map them with.
public enum DesignTokens {

    /// Gaps, in points.
    public enum Spacing {
        public static let hair: Double = 2.0
        public static let tight: Double = 4.0
        public static let row: Double = 6.0
        public static let group: Double = 8.0
        public static let section: Double = 12.0
        public static let loose: Double = 16.0
        public static let spacious: Double = 24.0
    }

    /// Corner radii, in points.
    public enum Radius {
        public static let control: Double = 6.0
        public static let group: Double = 8.0
    }

    /// Fixed dimensions, in points.
    public enum Size {
        public static let popoverWidth: Double = 380.0
        public static let sheetWidth: Double = 460.0
        public static let settingsWidth: Double = 480.0
        public static let statusDot: Double = 7.0
        public static let inlineDot: Double = 5.0
        public static let statusGlyph: Double = 12.0
        public static let iconSmall: Double = 10.0
        public static let nestedIndent: Double = 22.0
    }

    /// Type roles. Each platform resolves the name to its own
    /// semantic font, so text keeps following the user's accessibility
    /// settings instead of being pinned to a point size.
    public enum TypeRole {
        public static let sectionTitle = "headline"
        public static let rowTitle = "callout"
        public static let rowDetail = "caption"
        public static let rowMeta = "caption2"
    }

    /// Sizes for text that is not prose — a command, a glyph.
    public enum FontSize {
        public static let monoDetail: Double = 11.0
        public static let monoDense: Double = 10.0
        public static let glyphAffordance: Double = 9.0
    }

    /// What a colour *means*, rather than which colour it is.
    ///
    /// The platform maps each case to its own system colour: system
    /// colours already satisfy contrast in both appearances and already
    /// respond to Increase Contrast and the colour-blind accommodations,
    /// none of which a hand-picked hex re-earns for free.
    public enum ColorRole: String, CaseIterable, Sendable {
        case attention
        case working
        case ready
        case blocked
        case dormant
        case unknown

        /// What this role is for. Kept in code because the reason a colour
        /// exists is what stops it being reused for something else.
        public var meaning: String {
            switch self {
            case .attention: return "Something is waiting on the person. The only role permitted to interrupt."
            case .working: return "Progressing on its own. No action wanted."
            case .ready: return "Available to pick up."
            case .blocked: return "Waiting on something impersonal — a dependency, another task."
            case .dormant: return "Quiet with nothing ready. Reported, never highlighted."
            case .unknown: return "The app cannot tell. Distinct from 'nothing is happening'."
            }
        }

        /// The macOS system colour name this role resolves to.
        public var macOSSystemColorName: String {
            switch self {
            case .attention: return "systemOrange"
            case .working: return "systemGreen"
            case .ready: return "controlAccentColor"
            case .blocked: return "systemPurple"
            case .dormant: return "secondaryLabelColor"
            case .unknown: return "tertiaryLabelColor"
            }
        }

        /// For platforms with no system equivalent. Never preferred on macOS.
        public var fallbackHex: String {
            switch self {
            case .attention: return "#E8730A"
            case .working: return "#1E8E3E"
            case .ready: return "#0A6ED1"
            case .blocked: return "#7A3DB8"
            case .dormant: return "#6B6B70"
            case .unknown: return "#8E8E93"
            }
        }
    }

    /// Opacities for the one grouped block the design allows.
    public enum Emphasis {
        public static let groupFill: Double = 0.08
        public static let groupBorder: Double = 0.35
        public static let subtleFill: Double = 0.08
    }

    /// Durations, in seconds. `refresh` is 0 on purpose.
    public enum Motion {
        public static let disclosure: Double = 0.15
        public static let sheet: Double = 0.2
        public static let refresh: Double = 0.0
    }
}
