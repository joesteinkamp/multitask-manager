import Foundation
import Testing
@testable import MultiTaskCore

@Suite("MessageCodec")
struct MessageCodecTests {
    let codec = MessageCodec()

    @Test("A request round-trips through header and params")
    func requestRoundTrip() throws {
        let query = SessionQuery(waitingOnly: true, projectPath: "/p", refresh: true)
        let frame = try codec.encodeRequest(id: "7", method: WireProtocol.methodList, params: query)

        let header = try codec.decodeHeader(frame)
        #expect(header.type == .req)
        #expect(header.id == "7")
        #expect(header.method == WireProtocol.methodList)
        #expect(header.v == WireProtocol.version)
        #expect(try codec.decodeParams(SessionQuery.self, from: frame) == query)
    }

    @Test("A response round-trips a snapshot, dates included")
    func responseRoundTrip() throws {
        var snapshot = EngineSnapshot()
        snapshot.sessions = [Session.stub(id: "a", lastActivity: Fixtures.auditNow, status: .needsAttention)]
        snapshot.refreshedAt = Fixtures.auditNow

        let frame = try codec.encodeResponse(id: "7", result: snapshot)
        let header = try codec.decodeHeader(frame)
        #expect(header.type == .res)
        #expect(header.error == nil)

        let decoded = try codec.decodeResult(EngineSnapshot.self, from: frame)
        #expect(decoded.sessions.map(\.id) == ["a"])
        #expect(decoded.sessions[0].status == .needsAttention)
        // ISO-8601 has second precision, so compare at that resolution.
        #expect(abs(decoded.refreshedAt.timeIntervalSince(Fixtures.auditNow)) < 1)
    }

    @Test("An event carries its name and payload")
    func eventRoundTrip() throws {
        let notification = PendingNotification(kind: .single(sessionId: "a"),
                                               title: "app", body: "Needs approval",
                                               primarySessionId: "a")
        let frame = try codec.encodeEvent(WireProtocol.eventNotify, data: notification)

        let header = try codec.decodeHeader(frame)
        #expect(header.type == .event)
        #expect(header.event == WireProtocol.eventNotify)
        #expect(header.id == nil)

        let decoded = try codec.decodeEventData(PendingNotification.self, from: frame)
        #expect(decoded == notification)
    }

    @Test("A fault round-trips with its code")
    func faultRoundTrip() throws {
        let fault = ProtocolFault(.unknownMethod, "No such method: teleport")
        let frame = try codec.encodeFault(id: "9", fault: fault)

        let header = try codec.decodeHeader(frame)
        #expect(header.type == .res)
        #expect(header.error == fault)
    }

    @Test("An unknown protocol version is refused by name, not misparsed")
    func versionGate() throws {
        // A message from a future build. The point of carrying `v` from the first
        // commit is that this fails loudly instead of half-decoding.
        let future = Data(#"{"v":99,"id":"1","type":"req","method":"list"}"#.utf8)

        let fault = expectError(ProtocolFault.self) {
            try codec.decodeHeader(future)
        }
        #expect(fault?.code == .unsupportedVersion)
        #expect(fault?.message.contains("v\(WireProtocol.version)") == true)
    }

    @Test("Garbage is a malformed message, not a crash")
    func malformedMessage() {
        let fault = expectError(ProtocolFault.self) {
            try codec.decodeHeader(Data("not json at all".utf8))
        }
        #expect(fault?.code == .malformedMessage)
    }

    @Test("Asking for a slot the message doesn't have is a clean parameter error")
    func missingSlot() throws {
        let frame = try codec.encodeRequest(id: "1", method: WireProtocol.methodHealth)
        let fault = expectError(ProtocolFault.self) {
            try codec.decodeParams(SessionQuery.self, from: frame)
        }
        #expect(fault?.code == .badParameters)
    }

    @Test("Encoded frames never contain a newline, which would split them")
    func framesAreSingleLine() throws {
        var snapshot = EngineSnapshot()
        snapshot.sessions = [Session.stub(id: "a\nb", project: "multi\nline", lastActivity: Fixtures.auditNow)]
        snapshot.degraded = [DegradedReason(detectorId: "x", message: "line one\nline two")]

        let frame = try codec.encodeResponse(id: "1", result: snapshot)
        #expect(!frame.contains(UInt8(ascii: "\n")))

        // …and the embedded newlines survive as data.
        let decoded = try codec.decodeResult(EngineSnapshot.self, from: frame)
        #expect(decoded.sessions[0].id == "a\nb")
        #expect(decoded.degraded[0].message == "line one\nline two")
    }

    @Test("Every action survives the wire")
    func actionsRoundTrip() throws {
        let actions: [EngineAction] = [
            .refresh, .hide(sessionId: "a"), .unhide(sessionId: "a"), .clearHidden,
            .pin(sessionId: "a"), .unpin(sessionId: "a"),
            .rename(sessionId: "a", title: "New name"),
            .addManual(title: "By hand", projectPath: "/p"),
            .removeManual(sessionId: "manual:1"),
            .mute(projectPath: "/p"), .unmute(projectPath: "/p")
        ]
        for action in actions {
            let frame = try codec.encodeRequest(id: "1", method: WireProtocol.methodAct, params: action)
            #expect(try codec.decodeParams(EngineAction.self, from: frame) == action)
        }
    }
}

@Suite("FrameReader")
struct FrameReaderTests {

    @Test("Splits a buffer holding several complete frames")
    func splitsCompleteFrames() {
        var reader = FrameReader()
        let batch = reader.append(Data("one\ntwo\nthree\n".utf8))

        #expect(batch.frames.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
        #expect(batch.oversizedDropped == 0)
        #expect(reader.pendingByteCount == 0)
    }

    @Test("Holds a trailing partial frame until its newline arrives")
    func buffersPartialFrame() {
        var reader = FrameReader()

        let first = reader.append(Data("complete\npar".utf8))
        #expect(first.frames.map { String(decoding: $0, as: UTF8.self) } == ["complete"])
        #expect(reader.pendingByteCount == 3)

        let second = reader.append(Data("tial\n".utf8))
        #expect(second.frames.map { String(decoding: $0, as: UTF8.self) } == ["partial"])
        #expect(reader.pendingByteCount == 0)
    }

    @Test("A read boundary inside a multi-byte character doesn't corrupt the frame")
    func multiByteAcrossReads() {
        var reader = FrameReader()
        let bytes = Array("naïve—project\n".utf8)
        let cut = bytes.firstIndex(of: 0xE2)!   // inside the em dash

        _ = reader.append(Data(bytes[..<(cut + 1)]))
        let batch = reader.append(Data(bytes[(cut + 1)...]))

        #expect(batch.frames.count == 1)
        #expect(String(decoding: batch.frames[0], as: UTF8.self) == "naïve—project")
    }

    @Test("One byte at a time still assembles the frame")
    func bytewiseDelivery() {
        var reader = FrameReader()
        var frames: [Data] = []
        for byte in Array("hello\nworld\n".utf8) {
            frames.append(contentsOf: reader.append(Data([byte])).frames)
        }
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["hello", "world"])
    }

    @Test("An oversized frame is dropped and counted, and the next one still parses")
    func oversizedFrameDropped() {
        var reader = FrameReader(maxFrameBytes: 32)
        let huge = String(repeating: "x", count: 100)

        let batch = reader.append(Data("\(huge)\ngood\n".utf8))
        #expect(batch.oversizedDropped == 1)
        #expect(batch.frames.map { String(decoding: $0, as: UTF8.self) } == ["good"])
    }

    @Test("The tail of a dropped frame isn't parsed as a new one")
    func resyncsAfterOversize() {
        var reader = FrameReader(maxFrameBytes: 16)

        // Over the ceiling before any newline arrives: the reader gives up now
        // rather than buffering toward a newline that may never come.
        let first = reader.append(Data(String(repeating: "x", count: 40).utf8))
        #expect(first.oversizedDropped == 1)
        #expect(first.frames.isEmpty)

        // The rest of that doomed frame must be discarded, not treated as a frame.
        let second = reader.append(Data("stillTheSameFrame\ngood\n".utf8))
        #expect(second.frames.map { String(decoding: $0, as: UTF8.self) } == ["good"])
    }

    @Test("A bare newline is a keep-alive, not an empty message")
    func blankLinesIgnored() {
        var reader = FrameReader()
        let batch = reader.append(Data("\n\nreal\n\n".utf8))
        #expect(batch.frames.map { String(decoding: $0, as: UTF8.self) } == ["real"])
    }

    @Test("Reset drops buffered bytes")
    func resetClearsBuffer() {
        var reader = FrameReader()
        _ = reader.append(Data("partial".utf8))
        #expect(reader.pendingByteCount == 7)
        reader.reset()
        #expect(reader.pendingByteCount == 0)
    }

    @Test("Round-trips real messages through the writer and reader together")
    func codecThroughFraming() throws {
        let codec = MessageCodec()
        var reader = FrameReader()

        var stream = Data()
        stream.append(FrameWriter.frame(try codec.encodeRequest(id: "1", method: WireProtocol.methodList,
                                                                params: SessionQuery.all)))
        stream.append(FrameWriter.frame(try codec.encodeRequest(id: "2", method: WireProtocol.methodHealth)))

        // Deliver it in two arbitrary chunks, as a socket would.
        let split = stream.count / 3
        var frames = reader.append(stream.prefix(split)).frames
        frames.append(contentsOf: reader.append(stream.suffix(from: split)).frames)

        #expect(frames.count == 2)
        #expect(try codec.decodeHeader(frames[0]).method == WireProtocol.methodList)
        #expect(try codec.decodeHeader(frames[1]).method == WireProtocol.methodHealth)
    }
}
