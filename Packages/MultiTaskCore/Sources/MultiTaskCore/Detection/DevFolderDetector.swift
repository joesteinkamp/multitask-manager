import Foundation

/// Tool-agnostic activity signal: watches the user's designated dev folders for
/// recently-edited files and surfaces one session per top-level project.
///
/// For each configured root, it walks the tree (pruning heavy/noise directories),
/// finds files modified within `maxAge`, and groups them by the first path
/// component under the root — that component is treated as the "project". The
/// newest matching file's mtime becomes the session's activity time.
public struct DevFolderDetector: SessionDetector {
    public let id = "devFolders"
    public let displayName = "Dev Folders"

    /// Absolute paths the user designated as dev roots.
    public var roots: [String]
    public var maxAge: TimeInterval

    public init(roots: [String], maxAge: TimeInterval = 6 * 60 * 60) {
        self.roots = roots
        self.maxAge = maxAge
    }

    static let ignoredDirNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", ".next", "out",
        "target", "Pods", "DerivedData", ".venv", "venv", "__pycache__",
        ".gradle", "vendor", ".cache", ".turbo", "coverage"
    ]

    public func detect() async -> DetectionOutcome {
        guard !roots.isEmpty else { return .empty }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [Session] = []
        var missing: [String] = []

        for rootPath in roots {
            let root = URL(fileURLWithPath: FileSupport.expandingTilde(rootPath), isDirectory: true)
            guard FileSupport.isDirectory(root) else {
                missing.append(rootPath)
                continue
            }
            sessions.append(contentsOf: scan(root: root, cutoff: cutoff))
        }

        let degraded = missing.isEmpty ? nil : DegradedReason(
            detectorId: id,
            message: "Dev folder not found: \(missing.joined(separator: ", "))"
        )
        return DetectionOutcome(sessions: sessions, degraded: degraded)
    }

    private func scan(root: URL, cutoff: Date) -> [Session] {
        guard let enumerator = FileSupport.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        // project name -> (newest mtime, project path)
        var byProject: [String: (Date, String)] = [:]
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 20_000 { break } // safety bound for very large trees

            if FileSupport.isDirectory(url) {
                if Self.ignoredDirNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let mtime = FileSupport.modificationDate(of: url)
            guard mtime >= cutoff else { continue }

            // First path component under the root identifies the project.
            let relative = url.path.dropFirst(root.path.count).drop(while: { $0 == "/" })
            guard let projectComponent = relative.split(separator: "/").first.map(String.init),
                  !projectComponent.isEmpty
            else { continue }

            let projectPath = root.appendingPathComponent(projectComponent).path
            if let existing = byProject[projectComponent], existing.0 >= mtime { continue }
            byProject[projectComponent] = (mtime, projectPath)
        }

        return byProject.map { name, value in
            Session(
                id: "folder:\(value.1)",
                title: name,
                projectName: name,
                projectPath: value.1,
                source: .devFolder,
                lastActivity: value.0
            )
        }
    }
}
