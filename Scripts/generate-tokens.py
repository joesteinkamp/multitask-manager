#!/usr/bin/env python3
"""Generates Sources/MultiTaskCore/Design/DesignTokens.swift from DESIGN.json.

Run after editing DESIGN.json, and commit both files. `DesignTokensTests` fails
if they disagree, so drift is a red test rather than a discovery six months later.

The generated file imports Foundation only. That is the whole point: the values
live in the cross-platform engine, and each platform maps them to its own types
(SwiftUI `Color` and `CGFloat` on macOS, WinUI's equivalents on Windows) instead
of two clients transcribing one design system twice.

    python3 Scripts/generate-tokens.py           # write the file
    python3 Scripts/generate-tokens.py --check    # exit 1 if it would change
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "DESIGN.json"
TARGET = ROOT / "Packages/MultiTaskCore/Sources/MultiTaskCore/Design/DesignTokens.swift"

HEADER = """// Generated from DESIGN.json by Scripts/generate-tokens.py. Do not edit.
//
// Edit DESIGN.json and re-run the script; `DesignTokensTests` fails if this file
// and DESIGN.json disagree.
//
// Foundation only, like the rest of MultiTaskCore. These are raw values; each
// platform maps them to its own types. That is what keeps the macOS and Windows
// interfaces from drifting by two points of padding and one shade of orange.

import Foundation
"""


def literal(value):
    """A Swift literal, preserving int-ness so `2` doesn't become `2.0`."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(value)
    return '"%s"' % value


def scalars(node):
    """The scalar entries of a dict, skipping `$comment` and nested objects."""
    return [(k, v) for k, v in node.items()
            if not k.startswith("$") and not isinstance(v, (dict, list))]


def emit(design):
    out = [HEADER]

    out.append("""
/// Every constant the interfaces share, generated from `DESIGN.json`.
///
/// Values, not appearances: `Double` and `String`, so this compiles on Linux in
/// CI and on Windows in the client that has no SwiftUI to map them with.
public enum DesignTokens {""")

    def group(name, node, doc):
        out.append("")
        out.append("    /// %s" % doc)
        out.append("    public enum %s {" % name)
        for key, value in scalars(node):
            out.append("        public static let %s: Double = %s" % (key, float(value)))
        out.append("    }")

    group("Spacing", design["spacing"], "Gaps, in points.")
    group("Radius", design["radius"], "Corner radii, in points.")
    group("Size", design["size"], "Fixed dimensions, in points.")

    # Type: roles are names the platform resolves; mono and glyph are real sizes.
    out.append("")
    out.append("    /// Type roles. Each platform resolves the name to its own")
    out.append("    /// semantic font, so text keeps following the user's accessibility")
    out.append("    /// settings instead of being pinned to a point size.")
    out.append("    public enum TypeRole {")
    for key, value in scalars(design["type"]["roles"]):
        out.append("        public static let %s = %s" % (key, literal(value)))
    out.append("    }")

    out.append("")
    out.append("    /// Sizes for text that is not prose — a command, a glyph.")
    out.append("    public enum FontSize {")
    for key, value in scalars(design["type"]["mono"]):
        out.append("        public static let mono%s: Double = %s" % (key[:1].upper() + key[1:], float(value)))
    for key, value in scalars(design["type"]["glyph"]):
        out.append("        public static let glyph%s: Double = %s" % (key[:1].upper() + key[1:], float(value)))
    out.append("    }")

    # Colour roles, as an enum the platform switches on.
    roles = design["color"]["roles"]
    out.append("")
    out.append("    /// What a colour *means*, rather than which colour it is.")
    out.append("    ///")
    out.append("    /// The platform maps each case to its own system colour: system")
    out.append("    /// colours already satisfy contrast in both appearances and already")
    out.append("    /// respond to Increase Contrast and the colour-blind accommodations,")
    out.append("    /// none of which a hand-picked hex re-earns for free.")
    out.append("    public enum ColorRole: String, CaseIterable, Sendable {")
    for key in roles:
        out.append("        case %s" % key)
    out.append("")
    out.append("        /// What this role is for. Kept in code because the reason a colour")
    out.append("        /// exists is what stops it being reused for something else.")
    out.append("        public var meaning: String {")
    out.append("            switch self {")
    for key, spec in roles.items():
        out.append("            case .%s: return %s" % (key, literal(spec["meaning"])))
    out.append("            }")
    out.append("        }")
    out.append("")
    out.append("        /// The macOS system colour name this role resolves to.")
    out.append("        public var macOSSystemColorName: String {")
    out.append("            switch self {")
    for key, spec in roles.items():
        out.append("            case .%s: return %s" % (key, literal(spec["macOS"])))
    out.append("            }")
    out.append("        }")
    out.append("")
    out.append("        /// For platforms with no system equivalent. Never preferred on macOS.")
    out.append("        public var fallbackHex: String {")
    out.append("            switch self {")
    for key, spec in roles.items():
        out.append("            case .%s: return %s" % (key, literal(spec["fallback"])))
    out.append("            }")
    out.append("        }")
    out.append("    }")

    group("Emphasis", design["color"]["emphasis"], "Opacities for the one grouped block the design allows.")
    group("Motion", design["motion"], "Durations, in seconds. `refresh` is 0 on purpose.")

    out.append("}")
    out.append("")
    return "\n".join(out)


def main():
    design = json.loads(SOURCE.read_text())
    generated = emit(design)

    if "--check" in sys.argv:
        current = TARGET.read_text() if TARGET.exists() else ""
        if current != generated:
            print("DesignTokens.swift is out of date. Run Scripts/generate-tokens.py.")
            return 1
        print("DesignTokens.swift matches DESIGN.json.")
        return 0

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(generated)
    print("Wrote %s" % TARGET.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
