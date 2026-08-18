import Foundation
import Darwin
import MultiTaskCore

/// Reads the running process table, with each process's working directory.
///
/// The Darwin half of finding a session's terminal: `TerminalResolver` decides
/// what the tree *means* and is tested on Linux, this only gathers it.
///
/// Every session on this machine belongs to the user running the app, so
/// `proc_pidinfo` can read their working directories. It cannot read another
/// user's, and does not try — a process whose directory is unreadable simply
/// carries `nil` and is skipped by the match.
enum ProcessSnapshot {

    /// Every process this user can see, newest listing each call.
    ///
    /// Taken on demand rather than cached: it is read when someone clicks
    /// "go to the terminal", and a cached tree would send them to a window that
    /// closed ten minutes ago.
    static func current() -> [RunningProcess] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0

        // Sized first, then read: the table changes between the two calls, so the
        // buffer is deliberately over-allocated and the result trimmed to what
        // the second call reports.
        guard sysctl(&name, u_int(name.count - 1), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }
        let capacity = length + (length / 4)
        var buffer = [UInt8](repeating: 0, count: capacity)
        var read = capacity
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            sysctl(&name, u_int(name.count - 1), raw.baseAddress, &read, nil, 0) == 0
        }
        guard ok else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = read / stride
        guard count > 0 else { return [] }

        return buffer.withUnsafeBytes { raw -> [RunningProcess] in
            guard let base = raw.baseAddress else { return [] }
            var found: [RunningProcess] = []
            found.reserveCapacity(count)
            for index in 0..<count {
                let entry = base.load(fromByteOffset: index * stride, as: kinfo_proc.self)
                let pid = entry.kp_proc.p_pid
                guard pid > 0 else { continue }
                found.append(RunningProcess(
                    pid: pid,
                    parentPid: entry.kp_eproc.e_ppid,
                    executablePath: executablePath(of: pid),
                    workingDirectory: workingDirectory(of: pid)
                ))
            }
            return found
        }
    }

    private static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        // Short read means "not permitted" or "gone" — both are a `nil` here, not
        // an error worth surfacing: the caller is looking for one match among
        // hundreds of processes it has no business reading.
        guard read == size else { return nil }
        var path = info.pvi_cdir.vip_path
        return withUnsafeBytes(of: &path) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let value = String(cString: base)
            return value.isEmpty ? nil : value
        }
    }
}
