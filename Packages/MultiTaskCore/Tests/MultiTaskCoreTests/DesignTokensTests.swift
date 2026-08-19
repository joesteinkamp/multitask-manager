import Foundation
import Testing
@testable import MultiTaskCore

/// `DESIGN.json` is the source; `DesignTokens.swift` is generated from it.
///
/// Without a test the generator is a suggestion: someone edits the JSON, forgets
/// to run the script, and the two disagree silently — which is exactly the drift
/// the single source was introduced to prevent, now with an extra file to
/// mislead the next reader.
@Suite("Design tokens track DESIGN.json")
struct DesignTokensTests {

    /// The repository root, found from this file rather than the working
    /// directory, which differs between `swift test` and Xcode.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)            // …/Tests/MultiTaskCoreTests/DesignTokensTests.swift
            .deletingLastPathComponent()           // …/Tests/MultiTaskCoreTests
            .deletingLastPathComponent()           // …/Tests
            .deletingLastPathComponent()           // …/MultiTaskCore
            .deletingLastPathComponent()           // …/Packages
            .deletingLastPathComponent()           // repository root
    }

    private static func design() throws -> [String: Any] {
        let url = root.appendingPathComponent("DESIGN.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func numbers(_ group: String, in design: [String: Any]) throws -> [String: Double] {
        let node = try #require(design[group] as? [String: Any])
        return node.reduce(into: [:]) { result, entry in
            guard !entry.key.hasPrefix("$"), let value = entry.value as? NSNumber else { return }
            result[entry.key] = value.doubleValue
        }
    }

    @Test("Every spacing, radius, and size value matches the JSON")
    func scalarsMatch() throws {
        let design = try Self.design()

        let spacing = try Self.numbers("spacing", in: design)
        #expect(DesignTokens.Spacing.hair == spacing["hair"])
        #expect(DesignTokens.Spacing.tight == spacing["tight"])
        #expect(DesignTokens.Spacing.row == spacing["row"])
        #expect(DesignTokens.Spacing.group == spacing["group"])
        #expect(DesignTokens.Spacing.section == spacing["section"])
        #expect(DesignTokens.Spacing.loose == spacing["loose"])

        let radius = try Self.numbers("radius", in: design)
        #expect(DesignTokens.Radius.control == radius["control"])
        #expect(DesignTokens.Radius.group == radius["group"])

        let size = try Self.numbers("size", in: design)
        #expect(DesignTokens.Size.popoverWidth == size["popoverWidth"])
        #expect(DesignTokens.Size.sheetWidth == size["sheetWidth"])
        #expect(DesignTokens.Size.statusDot == size["statusDot"])
    }

    @Test("Every colour role in the JSON exists in code, and vice versa")
    func colorRolesMatch() throws {
        let design = try Self.design()
        let color = try #require(design["color"] as? [String: Any])
        let roles = try #require(color["roles"] as? [String: Any])

        let inJSON = Set(roles.keys)
        let inCode = Set(DesignTokens.ColorRole.allCases.map(\.rawValue))
        // Named rather than counted: a mismatch should say which role went missing.
        #expect(inJSON == inCode, "in JSON only: \(inJSON.subtracting(inCode)); in code only: \(inCode.subtracting(inJSON))")

        for role in DesignTokens.ColorRole.allCases {
            let spec = try #require(roles[role.rawValue] as? [String: Any])
            #expect(role.macOSSystemColorName == spec["macOS"] as? String)
            #expect(role.fallbackHex == spec["fallback"] as? String)
            // A role with no stated meaning gets reused for something else.
            #expect(!role.meaning.isEmpty)
        }
    }

    /// The collision that prompted this: green meant "working", "all clear", and
    /// "healthy" at once, so it meant nothing.
    @Test("Green belongs to complete, and to nothing else")
    func greenIsReservedForDone() {
        let green = DesignTokens.ColorRole.complete
        #expect(green.macOSSystemColorName == "systemGreen")

        for role in DesignTokens.ColorRole.allCases where role != .complete {
            #expect(role.macOSSystemColorName != "systemGreen",
                    "\(role.rawValue) also claims green — the signal stops meaning anything")
        }
    }

    @Test("Work in progress does not wear the colour of work finished")
    func workingIsNotComplete() {
        #expect(DesignTokens.ColorRole.working.macOSSystemColorName
                != DesignTokens.ColorRole.complete.macOSSystemColorName)
    }

    @Test("Only one role is permitted to interrupt")
    func oneAttentionColour() {
        // Orange is the interrupt. If a second role took it, the badge would be
        // lit by things that are not asking for anything.
        let orange = DesignTokens.ColorRole.allCases
            .filter { $0.macOSSystemColorName == "systemOrange" }
        #expect(orange == [.attention])
    }

    /// `idle` and `dormant` are the same absence at two timescales — stopped
    /// now, and stopped since last week. If they shared a colour the urgent one
    /// would inherit the quiet one's "reported, never highlighted" reading,
    /// which is the exact mistake that let idle projects pass as healthy.
    @Test("Stopped-now and stopped-for-a-week are told apart")
    func idleIsNotDormant() {
        #expect(DesignTokens.ColorRole.idle.macOSSystemColorName
                != DesignTokens.ColorRole.dormant.macOSSystemColorName)
        #expect(DesignTokens.ColorRole.idle.fallbackHex
                != DesignTokens.ColorRole.dormant.fallbackHex)
        // And it is not the interrupt either — idle is waste, not a question.
        #expect(DesignTokens.ColorRole.idle.macOSSystemColorName != "systemOrange")
    }

    @Test("Every fallback colour is a six-digit hex")
    func fallbacksAreUsable() {
        for role in DesignTokens.ColorRole.allCases {
            let hex = role.fallbackHex
            #expect(hex.hasPrefix("#"))
            #expect(hex.count == 7, "\(role.rawValue) fallback \(hex) is not #RRGGBB")
            #expect(UInt32(hex.dropFirst(), radix: 16) != nil, "\(role.rawValue) fallback isn't hex")
        }
    }

    /// The rule that keeps the list a status surface rather than a moving target.
    @Test("Refreshing animates nothing")
    func refreshDoesNotAnimate() {
        // A row that slides when a number changes makes a list that updates every
        // few seconds feel unreliable, and this is read in a glance.
        #expect(DesignTokens.Motion.refresh == 0)
    }

    @Test("The generated file is in sync with DESIGN.json")
    func generatedFileIsCurrent() throws {
        // The real guard. Everything above checks values that were generated
        // together; this checks that the generator was actually re-run.
        let script = Self.root.appendingPathComponent("Scripts/generate-tokens.py")
        try #require(FileManager.default.fileExists(atPath: script.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            // Not even `env` here. Skip rather than fail; the value checks above
            // still cover the contents, and CI's `design` job runs the real check
            // on a runner that has python3.
            return
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        // 127 is `env` reporting that python3 is not installed — it is not the
        // generator disagreeing with DESIGN.json. The earlier `catch` did not
        // cover this: `env` itself launches fine and *exits* 127, so the guard
        // never fired and the swift:6.0 container failed this test on every run.
        guard process.terminationStatus != 127 else { return }

        #expect(process.terminationStatus == 0, "\(text)")
    }
}

/// Writing files in a way that survives a failed atomic rename.
@Suite("Resilient writes")
struct ResilientWriteTests {

    @Test("Writes the content, creating any missing directories")
    func writesAndCreatesDirectories() throws {
        let dir = TempDir()
        let target = dir.url.appendingPathComponent("a/b/c/notes.md")

        try FileSupport.write("hello", to: target)

        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello")
    }

    @Test("Replaces existing content rather than appending to it")
    func replaces() throws {
        let dir = TempDir()
        let target = dir.url.appendingPathComponent("notes.md")

        try FileSupport.write("first", to: target)
        try FileSupport.write("second", to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "second")
    }

    @Test("Round-trips bytes that aren't valid UTF-8 text")
    func binarySafe() throws {
        let dir = TempDir()
        let target = dir.url.appendingPathComponent("blob.bin")
        let data = Data([0xFF, 0x00, 0xFE, 0x41])

        try FileSupport.write(data, to: target)
        #expect(try Data(contentsOf: target) == data)
    }

    @Test("A path that cannot be written reports the failure rather than losing it")
    func reportsRealFailures() {
        // A directory where a file is expected: the fallback cannot rescue this,
        // and it must surface rather than silently do nothing.
        let dir = TempDir()
        let target = dir.makeDirectory("occupied")
        #expect(throws: (any Error).self) {
            try FileSupport.write("x", to: target)
        }
    }
}
