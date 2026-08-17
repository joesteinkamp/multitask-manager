import Foundation

/// What one read off the wire produced.
public struct FrameBatch: Sendable, Equatable {
    /// Complete frames, in order, with their newline stripped.
    public var frames: [Data]
    /// How many frames were dropped for exceeding the size ceiling. Non-zero
    /// means the peer is misbehaving, and the caller should say so rather than
    /// silently losing messages.
    public var oversizedDropped: Int

    public init(frames: [Data] = [], oversizedDropped: Int = 0) {
        self.frames = frames
        self.oversizedDropped = oversizedDropped
    }

    public var isEmpty: Bool { frames.isEmpty && oversizedDropped == 0 }
}

/// Turns a byte stream into newline-delimited frames.
///
/// A socket read boundary has nothing to do with a message boundary: one `read`
/// can return three messages and half of a fourth, and the next can return the
/// rest of that fourth. Splitting on newline *bytes* rather than on decoded
/// characters is what makes a multi-byte UTF-8 sequence straddling two reads
/// survive — the same reason `AuditLogReader` works on `Data` rather than on
/// `String`.
///
/// Deliberately transport-free so every one of these cases is testable without a
/// file descriptor.
public struct FrameReader: Sendable {
    /// Frames longer than this are discarded and counted.
    public let maxFrameBytes: Int

    private var buffer = Data()
    /// Set after an oversized frame, until its terminating newline arrives — the
    /// tail of a frame we already gave up on must not be parsed as a new one.
    private var discardingUntilNewline = false

    public init(maxFrameBytes: Int = WireProtocol.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Folds freshly-read bytes in and returns whatever became complete.
    public mutating func append(_ data: Data) -> FrameBatch {
        var batch = FrameBatch()
        guard !data.isEmpty else { return batch }

        var remaining = data[...]

        while !remaining.isEmpty {
            if discardingUntilNewline {
                guard let newline = remaining.firstIndex(of: UInt8(ascii: "\n")) else {
                    // The rest of this read is still the frame we gave up on.
                    return batch
                }
                discardingUntilNewline = false
                remaining = remaining[remaining.index(after: newline)...]
                continue
            }

            guard let newline = remaining.firstIndex(of: UInt8(ascii: "\n")) else {
                buffer.append(contentsOf: remaining)
                if buffer.count > maxFrameBytes {
                    // Still incomplete and already over the ceiling: stop buffering
                    // now rather than waiting for a newline that may never come.
                    buffer.removeAll(keepingCapacity: false)
                    discardingUntilNewline = true
                    batch.oversizedDropped += 1
                }
                return batch
            }

            buffer.append(contentsOf: remaining[..<newline])
            remaining = remaining[remaining.index(after: newline)...]

            if buffer.count > maxFrameBytes {
                batch.oversizedDropped += 1
            } else if !buffer.isEmpty {
                // A bare newline is a keep-alive, not a message.
                batch.frames.append(buffer)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        return batch
    }

    /// Bytes held back waiting for a newline. Non-zero at disconnect means the
    /// peer cut off mid-message.
    public var pendingByteCount: Int { buffer.count }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        discardingUntilNewline = false
    }
}

/// Appends the newline a frame needs to be a frame.
///
/// One place to get this right, so no call site can forget it — a frame written
/// without its terminator silently merges with the next one.
public enum FrameWriter {
    public static func frame(_ payload: Data) -> Data {
        var out = payload
        out.append(UInt8(ascii: "\n"))
        return out
    }
}
