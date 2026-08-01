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
struct ProjectContext: Codable, Hashable {
    /// One-line statement of the project's purpose.
    var goal: String?
    /// Filename the goal was read from (e.g. "README.md"), shown for provenance.
    var goalSource: String?

    /// What the active session is working on right now — the most recent user
    /// prompt from the live transcript. `nil` when no readable transcript exists
    /// (e.g. desktop-app or manual entries).
    var now: String?

    /// The next unchecked task(s) from the project's roadmap / todo list.
    var next: [String]
    /// Filename the next steps were read from (e.g. "ROADMAP.md").
    var nextSource: String?

    var isEmpty: Bool { goal == nil && now == nil && next.isEmpty }

    static let empty = ProjectContext(goal: nil, goalSource: nil, now: nil, next: [], nextSource: nil)
}
