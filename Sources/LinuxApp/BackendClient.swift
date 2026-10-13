import Foundation
import Glibc
import DevSpaceCore

enum BackendClientError: Error, Equatable {
    case invalidChannel
    case alreadyStarted
    case notReady
    case frameTooLarge
    case queueFull
}

/// Owns the Swift backend subprocess and its bounded, versioned control pipe.
/// All UI delivery is pulled from `takeReceived()` on GTK's main loop.
final class BackendClient {
    enum State: Equatable {
        case stopped
        case starting
        case ready
        case shuttingDown
        case failed
    }

    private let executableURL: URL
    private let arguments: [String]
    private let channel: String
    private let applicationIdentifier: String
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let stateLock = NSLock()
    private var currentState: State = .stopped
    private var failureMessage: String?
    private var handshakeID: String?
    private var shutdownID: String?
    private var shutdownAcknowledged = false
    private var stdoutClosed = false
    private var processExitStatus: Int32?
    private var requestCounter: UInt64 = 0
    private var inputClosed = false
    private let decoder = BackendProtocolLineDecoder()
    private let receiveLock = NSLock()
    private var received: [(BackendProtocolMessage, Int)] = []
    private var receivedBytes = 0
    private let writeLock = NSLock()
    private var queuedWriteBytes = 0
    private let writer = DispatchQueue(label: "devspace.linux-backend-writer")
    private var started = false

    init(executableURL: URL, arguments: [String] = [], channel: String) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.channel = channel
        applicationIdentifier = channel == "development"
            ? "com.prakharp.devspace.dev"
            : "com.prakharp.devspace"
    }

    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    var failure: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return failureMessage
    }

    func start() throws {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            throw BackendClientError.alreadyStarted
        }
        guard channel == "development" || channel == "production" else {
            stateLock.unlock()
            throw BackendClientError.invalidChannel
        }
        started = true
        currentState = .starting
        stateLock.unlock()

        _ = Glibc.signal(SIGPIPE, SIG_IGN)
        process.executableURL = executableURL
        process.arguments = arguments.isEmpty ? ["--channel", channel] : arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] process in
            self?.backendExited(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            fail("backend could not start: \(error)")
            throw error
        }

        let output = outputPipe.fileHandleForReading
        let descriptor = output.fileDescriptor
        let flags = Glibc.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Glibc.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            fail("backend control pipe could not be made nonblocking")
            throw BackendClientError.notReady
        }
        output.readabilityHandler = { [weak self] handle in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Glibc.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                self?.consume(Data(buffer.prefix(count)))
            } else if count == 0 {
                self?.backendOutputClosed()
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                self?.fail("backend control pipe read failed: \(errno)")
            }
        }

        do {
            _ = try sendMessage("handshake", payload: nil, allowedState: .starting)
        } catch {
            fail("backend handshake could not be sent: \(error)")
            throw error
        }
    }

    @discardableResult
    func send(_ kind: String, payload: [String: String]? = nil) throws -> String {
        try sendMessage(kind, payload: payload, allowedState: .ready)
    }

    @discardableResult
    func shutdown() throws -> String {
        let id = try sendMessage("shutdown", payload: nil, allowedState: .ready, shuttingDown: true)
        return id
    }

    func takeReceived() -> [BackendProtocolMessage] {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        let messages = received.map(\.0)
        received.removeAll(keepingCapacity: true)
        receivedBytes = 0
        return messages
    }

    /// Emergency cleanup for test harnesses and startup failures. Normal app
    /// shutdown sends the protocol command and waits for the backend to exit.
    func terminate() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        closeInput()
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
    }

    deinit {
        terminate()
        try? outputPipe.fileHandleForReading.close()
    }

    private func sendMessage(
        _ kind: String,
        payload: [String: String]?,
        allowedState: State,
        shuttingDown: Bool = false
    ) throws -> String {
        stateLock.lock()
        guard currentState == allowedState else {
            stateLock.unlock()
            throw BackendClientError.notReady
        }
        requestCounter &+= 1
        let id = String(requestCounter)
        if kind == "handshake" { handshakeID = id }
        if shuttingDown {
            shutdownID = id
            shutdownAcknowledged = false
            currentState = .shuttingDown
        }
        stateLock.unlock()

        let line: Data
        do {
            line = try BackendProtocolMessage(id: id, kind: kind, payload: payload).encodeLine()
        } catch {
            if shuttingDown || kind == "handshake" { fail("could not encode backend command") }
            throw error
        }
        guard line.count <= BackendProtocol.maximumFrameBytes else {
            if shuttingDown || kind == "handshake" { fail("backend command exceeded the frame limit") }
            throw BackendClientError.frameTooLarge
        }

        writeLock.lock()
        guard queuedWriteBytes <= BackendProtocol.maximumFrameBytes - line.count else {
            writeLock.unlock()
            fail("backend write queue is full")
            throw BackendClientError.queueFull
        }
        queuedWriteBytes += line.count
        writeLock.unlock()

        writer.async { [weak self] in
            guard let self else { return }
            let success = self.writeAll(line)
            self.writeLock.lock()
            self.queuedWriteBytes -= line.count
            self.writeLock.unlock()
            if !success { self.fail("backend control pipe write failed") }
        }
        return id
    }

    private func writeAll(_ data: Data) -> Bool {
        let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Glibc.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private func consume(_ data: Data) {
        do {
            for line in try decoder.append(data) {
                let message = try BackendProtocolMessage.decode(line)
                try accept(message, byteCount: line.count)
            }
        } catch {
            fail("invalid backend response: \(error)")
        }
    }

    private func accept(_ message: BackendProtocolMessage, byteCount: Int) throws {
        stateLock.lock()
        switch currentState {
        case .starting:
            guard message.kind == "ready", message.id == handshakeID,
                  message.payload?["channel"] == channel,
                  message.payload?["application_id"] == applicationIdentifier,
                  message.payload?["protocol_version"] == String(BackendProtocol.version) else {
                stateLock.unlock()
                throw BackendClientError.invalidChannel
            }
            currentState = .ready
        case .ready:
            guard message.kind != "ready" else {
                stateLock.unlock()
                throw BackendClientError.invalidChannel
            }
        case .shuttingDown:
            if message.kind == "stopped" {
                guard message.id == shutdownID else {
                    stateLock.unlock()
                    throw BackendClientError.invalidChannel
                }
                shutdownAcknowledged = true
            }
        case .stopped, .failed:
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        receiveLock.lock()
        guard byteCount <= BackendProtocol.maximumFrameBytes - receivedBytes else {
            receiveLock.unlock()
            throw BackendProtocolError.frameTooLarge
        }
        received.append((message, byteCount))
        receivedBytes += byteCount
        receiveLock.unlock()
    }

    private func backendOutputClosed() {
        do {
            try decoder.finish()
        } catch {
            fail("backend closed with an incomplete frame")
            return
        }
        stateLock.lock()
        stdoutClosed = true
        if currentState == .shuttingDown && shutdownAcknowledged {
            finishExitIfKnown()
        } else if currentState != .failed && currentState != .stopped {
            currentState = .failed
            failureMessage = "backend output closed unexpectedly"
        }
        stateLock.unlock()
    }

    private func backendExited(status: Int32) {
        stateLock.lock()
        processExitStatus = status
        finishExitIfKnown()
        if currentState != .stopped && currentState != .failed && stdoutClosed {
            currentState = .failed
            failureMessage = "backend exited with status \(status)"
        }
        stateLock.unlock()
    }

    private func finishExitIfKnown() {
        guard stdoutClosed, let status = processExitStatus else { return }
        if currentState == .shuttingDown && shutdownAcknowledged && status == 0 {
            currentState = .stopped
            failureMessage = nil
        } else if currentState != .failed {
            currentState = .failed
            failureMessage = "backend exited unexpectedly with status \(status)"
        }
    }

    private func fail(_ message: String) {
        stateLock.lock()
        var shouldCloseInput = false
        if currentState != .stopped && currentState != .failed {
            currentState = .failed
            failureMessage = message
            if !inputClosed {
                inputClosed = true
                shouldCloseInput = true
            }
        }
        stateLock.unlock()
        if shouldCloseInput { try? inputPipe.fileHandleForWriting.close() }
    }

    private func closeInput() {
        stateLock.lock()
        let shouldClose = !inputClosed
        inputClosed = true
        stateLock.unlock()
        if shouldClose { try? inputPipe.fileHandleForWriting.close() }
    }
}
