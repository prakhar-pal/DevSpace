import Foundation
import Network
import Security

// Port of src-tauri/src/notify.rs — the desktop side of the Claude Code
// notification path: a loopback HTTP listener the in-pod hook reaches over the
// reverse SSH tunnel, plus token load/create and event->message mapping.

public struct NotifyPayload: Decodable, Equatable {
    public let podID: String
    public let event: String
    public let token: String

    enum CodingKeys: String, CodingKey {
        case podID = "pod_id"
        case event
        case token
    }

    public init(podID: String, event: String, token: String) {
        self.podID = podID
        self.event = event
        self.token = token
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        podID = try c.decode(String.self, forKey: .podID)
        event = try c.decode(String.self, forKey: .event)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }
}

public struct DidePayload: Decodable, Equatable {
    public let podID: String
    public let path: String
    public let token: String

    enum CodingKeys: String, CodingKey {
        case podID = "pod_id"
        case pathB64 = "path_b64"
        case token
    }

    public init(podID: String, path: String, token: String) {
        self.podID = podID
        self.path = path
        self.token = token
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        podID = try c.decode(String.self, forKey: .podID)
        token = try c.decode(String.self, forKey: .token)

        let encodedPath = try c.decode(String.self, forKey: .pathB64)
        guard let pathData = Data(base64Encoded: encodedPath),
              let decodedPath = String(data: pathData, encoding: .utf8),
              !decodedPath.isEmpty,
              (decodedPath as NSString).isAbsolutePath
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .pathB64,
                in: c,
                debugDescription: "path_b64 must decode to a non-empty absolute UTF-8 path"
            )
        }
        path = decodedPath
    }
}

public enum Notify {
    /// Map a Claude Code hook event name to a user-facing message.
    public static func messageFor(_ event: String) -> String {
        event == "Stop" ? "Claude finished" : "Claude needs your input"
    }

    /// 16 random bytes as hex from the OS CSPRNG. **Fails closed** if the RNG is
    /// unavailable so callers never run with a predictable token.
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DevpodError("OS RNG unavailable: \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Load the persisted notify token or create+persist one (stable across
    /// restarts so hooks keep matching). Stored owner-only (0600) under
    /// ~/Library/Application Support/DevSpace.
    public static func loadOrCreateToken() throws -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else {
            throw DevpodError("no HOME")
        }
        let dir = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/DevSpace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("notify-token")

        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            let t = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count == 32, t.allSatisfy(\.isHexDigit) {
                return t
            }
        }
        let token = try randomToken()
        try token.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return token
    }

    /// Parse a raw HTTP request body into a payload (shared by the listener).
    static func parsePayload(_ body: Data) -> NotifyPayload? {
        try? JSONDecoder().decode(NotifyPayload.self, from: body)
    }

    static func parseDidePayload(_ body: Data) -> DidePayload? {
        try? JSONDecoder().decode(DidePayload.self, from: body)
    }
}

/// Loopback HTTP listener on `SSH.listenerPort`. For each `POST /notify` whose
/// token matches, invokes `onNotify(podID, message)`. Minimal HTTP/1.1 parsing
/// over Network.framework (the in-pod `curl` is the only client).
public final class NotifyListener: @unchecked Sendable {
    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private let expectedToken: String
    private let port: UInt16
    private let onNotify: (String, String) -> Void
    private let onDide: (DidePayload) -> Void
    private var listener: NWListener?

    public init(
        expectedToken: String,
        port: UInt16 = SSH.listenerPort,
        onNotify: @escaping (String, String) -> Void,
        onDide: @escaping (DidePayload) -> Void = { _ in }
    ) {
        self.expectedToken = expectedToken
        self.port = port
        self.onNotify = onNotify
        self.onDide = onDide
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback only (mirrors tiny_http's 127.0.0.1 bind).
        params.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let request = Self.completeRequest(buf) {
                self.process(request: request, conn: conn)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    /// Returns the request body once headers + Content-Length bytes have all
    /// arrived; nil if more data is needed.
    private static func completeRequest(_ buf: Data) -> HTTPRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buf.range(of: sep) else { return nil }
        let headerData = buf.subdata(in: buf.startIndex ..< r.lowerBound)
        let header = String(decoding: headerData, as: UTF8.self)
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        let contentLength = header
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyStart = r.upperBound
        let available = buf.distance(from: bodyStart, to: buf.endIndex)
        guard available >= contentLength else { return nil }
        let body = buf.subdata(in: bodyStart ..< buf.index(bodyStart, offsetBy: contentLength))
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        let method = requestLine.count > 0 ? String(requestLine[0]) : ""
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""
        return HTTPRequest(method: method, path: path, body: body)
    }

    private func process(request: HTTPRequest, conn: NWConnection) {
        switch (request.method, request.path) {
        case ("POST", "/notify"):
            if let payload = Notify.parsePayload(request.body) {
                if payload.token == expectedToken {
                    onNotify(payload.podID, Notify.messageFor(payload.event))
                } else {
                    Log.write("notify: token mismatch — ignoring (stale hook?)")
                }
            } else {
                Log.write("notify: unparseable body (ignored)")
            }

        case ("POST", "/dide"):
            if let payload = Notify.parseDidePayload(request.body) {
                if payload.token == expectedToken {
                    onDide(payload)
                } else {
                    Log.write("dide: token mismatch — ignoring")
                }
            } else {
                Log.write("dide: invalid request (ignored)")
            }

        default:
            break
        }
        let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
