import Foundation

/// A plain-text briefing for a project, assembled entirely from files already on
/// disk — **no language model involved**. It answers three questions so you can
/// re-orient on a project without opening it:
///
/// - **Goal:** what this project is for (from its description docs).
/// - **Now:** what the live session is doing this moment (latest transcript prompt).
/// - **Next:** what to pick up when it's waiting on you (roadmap / todo checkboxes).
///
/// Surfaced under each session row in the popover. Everything here is derived by
/// `ProjectContextReader`; the struct itself just carries the result.
public struct ProjectContext: Codable, Hashable, Sendable {
    /// One-line statement of the project's purpose.
    public var goal: String?
    /// Filename the goal was read from (e.g. "README.md"), shown for provenance.
    public var goalSource: String?

    /// What the active session is working on right now — the most recent user
    /// prompt from the live transcript. `nil` when no readable transcript exists
    /// (e.g. desktop-app or manual entries).
    public var now: String?

    /// The next unchecked task(s) from the project's roadmap / todo list.
    public var next: [String]
    /// Filename the next steps were read from (e.g. "ROADMAP.md").
    public var nextSource: String?

    public init(goal: String? = nil, goalSource: String? = nil, now: String? = nil,
                next: [String] = [], nextSource: String? = nil) {
        self.goal = goal
        self.goalSource = goalSource
        self.now = now
        self.next = next
        self.nextSource = nextSource
    }

    public var isEmpty: Bool { goal == nil && now == nil && next.isEmpty }

    public static let empty = ProjectContext()
}
