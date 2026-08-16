import Foundation

/// The daemon protocol's constants and message shapes.
///
/// Newline-delimited JSON, one object per line. It matches every other format in
/// this ecosystem, it's debuggable with `nc`, and — unlike a binary framing — a
/// captured transcript is readable when something goes wrong at 2am.
///
/// The transport is deliberately *not* part of this file. Keeping the message
/// layer independent of the socket is what makes remote access a later adapter
/// rather than a rewrite, and it's what lets every case below be tested without
/// opening a file descriptor.
public enum WireProtocol {
    /// Bumped only for a breaking change. Present from the first commit so the
    /// server can reject an unknown major by name rather than misparsing it.
    public static let version = 1

    /// Frames larger than this are refused. Without a ceiling, one buggy or
    /// hostile writer can make the reader buffer without bound.
    public static let maxFrameBytes = 1 * 1024 * 1024

    /// Default socket location. Short on purpose: `sun_path` is 104 bytes on
    /// macOS, and a path under Application Support can exceed that for a long
    /// user name.
    public static var defaultSocketPath: String {
        FileSupport.homeDirectory
            .appendingPathComponent(".multitaskmanager", isDirectory: true)
            .appendingPathComponent("sock").path
    }

    public static let methodList = "list"
    public static let methodGet = "get"
    public static let methodHealth = "health"
    public static let methodSubscribe = "subscribe"
    public static let methodAct = "act"
    public static let methodVersion = "version"

    public static let eventSnapshot = "snapshot"
    public static let eventNotify = "notify"
}

public enum MessageType: String, Codable, Sendable {
    case req, res, event
}

/// Why a request was refused. Carried in a response's `error` slot.
public struct ProtocolFault: Codable, Sendable, Error, Equatable {
    public var code: FaultCode
    public var message: String

    public init(_ code: FaultCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum FaultCode: String, Codable, Sendable {
    case unsupportedVersion
    case malformedMessage
    case unknownMethod
    case badParameters
    case notFound
    case actionFailed
    case frameTooLarge
    case internalError
}

/// The fields common to every message, decodable without knowing the payload
/// type. Decoding happens in two passes — header first, then the typed payload —
/// because `params`, `result` and `data` hold different shapes per method, and a
/// single generic envelope would have to lie about that.
public struct MessageHeader: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String?
    public var type: MessageType
    public var method: String?
    public var event: String?
    /// Present on a response that failed. A response carries either this or a
    /// result, never both.
    public var error: ProtocolFault?

    public init(v: Int = WireProtocol.version, id: String? = nil, type: MessageType,
                method: String? = nil, event: String? = nil, error: ProtocolFault? = nil) {
        self.v = v
        self.id = id
        self.type = type
        self.method = method
        self.event = event
        self.error = error
    }
}

/// Encodes and decodes protocol messages. Transport-free by design.
///
/// A fresh coder is built per call rather than held as state: the message volume
/// here is a handful per refresh, and a shared `JSONEncoder` would make this type
/// a piece of mutable state shared across connections for no measurable gain.
public struct MessageCodec: Sendable {
    public init() {}

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Never pretty-print on the wire: a newline inside a frame would split it.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Encoding

    public func encodeRequest<P: Encodable>(id: String, method: String, params: P) throws -> Data {
        try encode(Frame<P, Empty, Empty>(id: id, type: .req, method: method, params: params))
    }

    public func encodeRequest(id: String, method: String) throws -> Data {
        try encodeRequest(id: id, method: method, params: Empty())
    }

    public func encodeResponse<R: Encodable>(id: String, result: R) throws -> Data {
        try encode(Frame<Empty, R, Empty>(id: id, type: .res, result: result))
    }

    public func encodeFault(id: String?, fault: ProtocolFault) throws -> Data {
        try encode(Frame<Empty, Empty, Empty>(id: id, type: .res, error: fault))
    }

    public func encodeEvent<D: Encodable>(_ name: String, data: D) throws -> Data {
        try encode(Frame<Empty, Empty, D>(type: .event, event: name, data: data))
    }

    // MARK: Decoding

    /// Reads the fields present on every message, and enforces the version gate.
    public func decodeHeader(_ frame: Data) throws -> MessageHeader {
        let header: MessageHeader
        do {
            header = try decoder.decode(MessageHeader.self, from: frame)
        } catch {
            throw ProtocolFault(.malformedMessage, "Not a protocol message: \(error)")
        }
        guard header.v == WireProtocol.version else {
            throw ProtocolFault(
                .unsupportedVersion,
                "Protocol v\(header.v) is not supported; this build speaks v\(WireProtocol.version)"
            )
        }
        return header
    }

    /// Decodes a request's `params`.
    public func decodeParams<P: Decodable>(_ type: P.Type, from frame: Data) throws -> P {
        try slot(ParamsSlot<P>.self, from: frame, named: "params").params
    }

    /// Decodes a successful response's `result`.
    public func decodeResult<R: Decodable>(_ type: R.Type, from frame: Data) throws -> R {
        try slot(ResultSlot<R>.self, from: frame, named: "result").result
    }

    /// Decodes an event's `data`.
    public func decodeEventData<D: Decodable>(_ type: D.Type, from frame: Data) throws -> D {
        try slot(DataSlot<D>.self, from: frame, named: "data").data
    }

    private func slot<S: Decodable>(_ type: S.Type, from frame: Data, named name: String) throws -> S {
        do {
            return try decoder.decode(type, from: frame)
        } catch {
            throw ProtocolFault(.badParameters, "Could not read `\(name)`: \(error)")
        }
    }

    private func encode<P: Encodable, R: Encodable, D: Encodable>(_ frame: Frame<P, R, D>) throws -> Data {
        do {
            return try encoder.encode(frame)
        } catch {
            throw ProtocolFault(.internalError, "Could not encode message: \(error)")
        }
    }

    /// Payload-free stand-in for the slots a given message doesn't use.
    public struct Empty: Codable, Sendable, Equatable {
        public init() {}
    }

    /// One wire message. Unused slots are `nil` and so encode as absent.
    private struct Frame<P: Encodable, R: Encodable, D: Encodable>: Encodable {
        var v = WireProtocol.version
        var id: String?
        var type: MessageType
        var method: String?
        var event: String?
        var params: P?
        var result: R?
        var data: D?
        var error: ProtocolFault?
    }

    private struct ParamsSlot<T: Decodable>: Decodable { let params: T }
    private struct ResultSlot<T: Decodable>: Decodable { let result: T }
    private struct DataSlot<T: Decodable>: Decodable { let data: T }
}
