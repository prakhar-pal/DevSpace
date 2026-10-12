import Foundation
import XCTest
@testable import DevSpaceCore

final class BackendProtocolTests: XCTestCase {
    func testFrameLimitAppliesToEachMessageNotTheReadBatch() throws {
        let decoder = BackendProtocolLineDecoder()
        let frame = Data((String(repeating: "x", count: 600_000) + "\n").utf8)
        let messages = try decoder.append(frame + frame)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.count), [600_000, 600_000])
    }

    func testFrameLimitRejectsAnOversizedDelimitedMessage() {
        let decoder = BackendProtocolLineDecoder()
        let oversized = Data((String(repeating: "x", count: 1_048_577) + "\n").utf8)
        XCTAssertThrowsError(try decoder.append(oversized)) { error in
            XCTAssertEqual(error as? BackendProtocolError, .frameTooLarge)
        }
    }

    func testDecoderReassemblesFragmentedNewlineDelimitedMessages() throws {
        let decoder = BackendProtocolLineDecoder()
        let first = try decoder.append(Data("{\"version\":1,".utf8))
        let second = try decoder.append(Data("\"kind\":\"ping\"}\n".utf8))

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(
            try second.map(BackendProtocolMessage.decode),
            [BackendProtocolMessage(kind: "ping")]
        )
    }

    func testDecoderSeparatesMultipleMessagesInOneChunk() throws {
        let decoder = BackendProtocolLineDecoder()
        let messages = try decoder.append(Data(
            "{\"version\":1,\"kind\":\"ping\"}\n{\"version\":1,\"id\":\"2\",\"kind\":\"shutdown\"}\n".utf8
        ))

        XCTAssertEqual(
            try messages.map(BackendProtocolMessage.decode),
            [BackendProtocolMessage(kind: "ping"), BackendProtocolMessage(id: "2", kind: "shutdown")]
        )
    }

    func testMessageRejectsAnUnsupportedProtocolVersion() {
        XCTAssertThrowsError(try BackendProtocolMessage.decode(Data("{\"version\":2,\"kind\":\"ping\"}".utf8)))
    }
}
