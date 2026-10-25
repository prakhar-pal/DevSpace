import Foundation

/// The private, versioned newline-delimited JSON protocol between the Linux
/// GTK process and its Swift child backend. Terminal byte streams deliberately
/// do not travel over this control protocol.
public enum BackendProtocol {
    public static let version = 1
    public static let maximumFrameBytes = 1_048_576
}

public enum BackendProtocolError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformedMessage
    case frameTooLarge
}

public struct BackendProtocolMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String?
    public let kind: String
    public let payload: [String: String]?

    public init(
        id: String? = nil,
        kind: String,
        payload: [String: String]? = nil,
        version: Int = BackendProtocol.version
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.payload = payload
    }

    public static func decode(_ data: Data) throws -> BackendProtocolMessage {
        guard let message = try? JSONDecoder().decode(BackendProtocolMessage.self, from: data) else {
            throw BackendProtocolError.malformedMessage
        }
        guard message.version == BackendProtocol.version else {
            throw BackendProtocolError.unsupportedVersion(message.version)
        }
        return message
    }

    public func encodeLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

/// Incrementally splits NDJSON without assuming that stdin/pipe reads align to
/// JSON boundaries. A size limit prevents a failed peer from growing memory
/// without bound.
public final class BackendProtocolLineDecoder {
    private var buffered = Data()

    public init() {}

    /// A closed pipe is not a frame delimiter: reject truncated JSON instead
    /// of silently treating a partially written command as clean shutdown.
    public func finish() throws {
        guard buffered.isEmpty else { throw BackendProtocolError.malformedMessage }
    }

    public func append(_ data: Data) throws -> [Data] {
        buffered.append(data)
        var lines: [Data] = []
        while let newline = buffered.firstIndex(of: 0x0A) {
            let line = buffered.prefix(upTo: newline)
            guard line.count <= BackendProtocol.maximumFrameBytes else {
                buffered.removeAll(keepingCapacity: false)
                throw BackendProtocolError.frameTooLarge
            }
            buffered.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }
        guard buffered.count <= BackendProtocol.maximumFrameBytes else {
            buffered.removeAll(keepingCapacity: false)
            throw BackendProtocolError.frameTooLarge
        }
        return lines
    }
}
