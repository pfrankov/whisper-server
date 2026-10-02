import XCTest
import XCTVapor
import NIOEmbedded
import NIOHTTP1
import NIOHTTPCompression

/// Model-free dependency tests. Native app tests still require whisper.xcframework.
final class HTTPDependencyTests: XCTestCase {
    private final class RequestHeadObserver: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        var heads = 0

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if case .head = unwrapInboundIn(data) { heads += 1 }
            context.fireChannelRead(data)
        }
    }

    func testExcessHeadersFailBeforeAnApplicationReceivesARequest() throws {
        let observer = RequestHeadObserver()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        // Same default decoder construction as Vapor 4.115's HTTP/1 pipeline.
        try channel.pipeline.syncOperations.addHandlers(
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), observer
        )
        try channel.writeInbound(ByteBuffer(string: "GET /v1/models HTTP/1.1\r\nHost: localhost\r\n"))
        // Bounded to <100 KiB. Individual fields are valid; their total exceeds 80 KiB.
        var overflow: Error?
        for index in 0..<90 {
            do {
                try channel.writeInbound(ByteBuffer(string: "X-\(index): \(String(repeating: "a", count: 1024))\r\n"))
            } catch {
                overflow = error
                break
            }
        }
        XCTAssertEqual(overflow as? HTTPParserError, .headerOverflow)
        XCTAssertEqual(observer.heads, 0, "Headers must be rejected before auth/route middleware sees the head")
    }

    func testOrdinaryMultipartHeadersAndBodyRemainIntact() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
        defer { _ = try? channel.finish() }
        let body = "--fixture\r\nContent-Disposition: form-data; name=\"file\"; filename=\"synthetic.wav\"\r\n\r\nsynthetic\r\n--fixture--\r\n"
        let headers = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=fixture\r\nContent-Length: \(body.utf8.count)\r\nAccept: text/event-stream\r\n\r\n"
        try channel.writeInbound(ByteBuffer(string: headers + body))
        guard case .head(let head) = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Missing request head")
        }
        XCTAssertEqual(head.uri, "/v1/audio/transcriptions")
        XCTAssertEqual(head.headers.first(name: .accept), "text/event-stream")
        guard case .body(let decoded) = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Missing request body")
        }
        XCTAssertEqual(String(buffer: decoded), body)
        guard case .end = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Missing request end")
        }
    }

    func testInflatedContentLengthCannotBypassVaporDecompressionRatio() throws {
        let channel = EmbeddedChannel(handler: NIOHTTPRequestDecompressor(limit: .ratio(25)))
        defer { _ = try? channel.finish() }
        // gzip of 100,000 zero bytes, generated with Python gzip.compress(..., mtime=0).
        let compressed = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAACA+3BMQEAAADCoPVPbQ0PoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIBXA32VEdSghgEA"))
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/audio/transcriptions", headers: [
            "Content-Encoding": "gzip", "Content-Length": "100000"
        ])
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(bytes: compressed)))) { error in
            XCTAssertTrue(error is NIOHTTPDecompression.DecompressionError)
        }
    }

    func testVaporModelAndTranscriptionTransportContractsWithSyntheticResponses() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        app.get("v1", "models") { _ in ["object": "list"] }
        app.post("v1", "audio", "transcriptions") { req -> Response in
            struct Fixture: Content { var file: File; var stream: Bool? }
            let fixture = try req.content.decode(Fixture.self)
            XCTAssertEqual(String(buffer: fixture.file.data), "synthetic")
            if fixture.stream == true {
                return Response(headers: ["Content-Type": "text/event-stream"], body: .init(stream: { writer in
                    writer.write(.buffer(ByteBuffer(string: "data: synthetic\n\nevent: end\ndata: \n\n")), promise: nil)
                    writer.write(.end, promise: nil)
                }))
            }
            return Response(headers: ["Content-Type": "application/json"], body: .init(string: "{\"text\":\"synthetic\"}"))
        }
        let live = try app.testable(method: .running(hostname: "127.0.0.1", port: 0))
        try live.test(.GET, "v1/models") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode([String: String].self)["object"], "list")
        }
        for streaming in [false, true] {
            let body = "--fixture\r\nContent-Disposition: form-data; name=\"file\"; filename=\"synthetic.wav\"\r\nContent-Type: audio/wav\r\n\r\nsynthetic\r\n--fixture\r\nContent-Disposition: form-data; name=\"stream\"\r\n\r\n\(streaming)\r\n--fixture--\r\n"
            try live.test(.POST, "v1/audio/transcriptions", headers: [
                "Content-Type": "multipart/form-data; boundary=fixture", "Accept": "text/event-stream"
            ], body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
                if streaming {
                    XCTAssertEqual(response.headers.first(name: .contentType), "text/event-stream")
                    XCTAssertEqual(response.body.string, "data: synthetic\n\nevent: end\ndata: \n\n")
                } else {
                    XCTAssertEqual(try response.content.decode([String: String].self)["text"], "synthetic")
                }
            }
        }
    }
}
