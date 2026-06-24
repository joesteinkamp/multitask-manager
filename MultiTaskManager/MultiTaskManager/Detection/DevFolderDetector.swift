import Foundation

/// Tool-agnostic activity signal: watches the user's designated dev folders for
/// recently-edited files and surfaces one session per top-level project.
///
/// For each configured root, it walks the tree (pruning heavy/noise directories),
/// finds files modified within `maxAge`, and groups them by the first path
/// component under the root — that component is treated as the "project". The
/// newest matching file's mtime becomes the session's activity time.
struct DevFolderDetector: SessionDetector {
    let id = "devFolders"
    let displayName = "Dev Folders"

    /// Absolute paths the user designated as dev roots.
    var roots: [String]
    var maxAge: TimeInterval = 6 * 60 * 60

    private static let ignoredDirNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", ".next", "out",
        "target", "Pods", "DerivedData", ".venv", "venv", "__pycache__",
        ".gradle", "vendor", ".cache", ".turbo", "coverage"
    ]

    func detect() -> [Session] {
        guard !roots.isEmpty else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [Session] = []

        for rootPath in roots {
            let root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
            guard DetectorSupport.isDirectory(root) else { continue }
            sessions.append(contentsOf: scan(root: root, cutoff: cutoff))
        }
        return sessions
    }

    private func scan(root: URL, cutoff: Date) -> [Session] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = DetectorSupport.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        // project name -> (newest mtime, project path)
        var byProject: [String: (Date, String)] = [:]
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 20_000 { break } // safety bound for very large trees

            if DetectorSupport.isDirectory(url) {
                if Self.ignoredDirNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let mtime = DetectorSupport.modificationDate(of: url)
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
