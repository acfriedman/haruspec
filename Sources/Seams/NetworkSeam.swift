import Foundation
import HaruspecCore

/// The network seam (docs/seams.md: `URLSession` via `URLProtocol` registration) — Apple's sanctioned,
/// no-swizzling interception point. Register it on a `URLSessionConfiguration` and every request the
/// session makes is either **recorded** (record mode delegates to the real network / a live handler
/// and captures status + body) or **replayed** (replay mode serves the recorded response headlessly,
/// no network required). That headless replay is the whole point: CI can re-run the changed code
/// against the golden branch's recorded responses in a pure process.
///
/// v0 keys by `method + URL` and captures status code + body. Header capture, request-body matching,
/// and streaming are not captured. `URLProtocol` instances are created by the URL
/// loading system, so configuration rides on class-level state — one active cassette per install.
public final class CassetteURLProtocol: URLProtocol {
    private static let configLock = NSLock()
    // Guarded by `configLock`; `URLProtocol` instances are created by the URL loading system, so
    // configuration must ride on class-level state.
    private nonisolated(unsafe) static var cassette: Cassette?
    private nonisolated(unsafe) static var liveHandler: (@Sendable (URLRequest) -> (status: Int, body: Data))?

    /// Point a session's config at this protocol. `liveHandler` supplies responses in record mode
    /// (inject a local one in tests, or omit to let real network run); replay ignores it.
    public static func install(
        cassette: Cassette,
        liveHandler: (@Sendable (URLRequest) -> (status: Int, body: Data))? = nil
    ) -> URLSessionConfiguration {
        configLock.lock()
        self.cassette = cassette
        self.liveHandler = liveHandler
        configLock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CassetteURLProtocol.self]
        return config
    }

    private static func currentCassette() -> Cassette? {
        configLock.lock(); defer { configLock.unlock() }
        return cassette
    }

    private static func runLive(_ request: URLRequest) -> (status: Int, body: Data) {
        configLock.lock(); let handler = liveHandler; configLock.unlock()
        return handler?(request) ?? (0, Data())
    }

    // MARK: URLProtocol

    override public class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        guard let cassette = Self.currentCassette(), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let seam = "url:\(request.httpMethod ?? "GET") \(url.absoluteString)"

        let recorded = cassette.step(seam: seam, live: {
            let (status, body) = Self.runLive(request)
            return .object(["status": .int(Int64(status)), "body": .string(body.base64EncodedString())])
        })

        guard case let .object(fields) = recorded,
              case let .int(status)? = fields["status"],
              case let .string(base64)? = fields["body"], let body = Data(base64Encoded: base64)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse)); return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: Int(status),
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}
