import Foundation
import Network

/// Tiny loopback HTTP server so Exam Quest can tell when a game it launched has closed.
///
/// `GET http://127.0.0.1:47620/game` returns `{"sid": ..., "running": ..., "name": ...}`.
/// Every response carries CORS + Private Network Access headers so the site
/// (GitHub Pages or a local dev server) can fetch it. Anything else is a 404.
@MainActor
final class GameStatusServer {
    nonisolated static let port: UInt16 = 47620

    private let status: @MainActor () -> [String: Any]
    private var listener: NWListener?

    init(status: @escaping @MainActor () -> [String: Any]) { self.status = status }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else {
            NSLog("DevBoard: game status server could not listen on \(Self.port)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        l.stateUpdateHandler = { state in
            if case .failed(let error) = state { NSLog("DevBoard: game status server failed: \(error)") }
        }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    /// Reads until the end of the request headers (requests here never have bodies).
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { conn.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || done || error != nil || buffer.count > 16384 {
                    self.respond(conn, request: buffer)
                } else {
                    self.receive(conn, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(while: { $0 != 13 && $0 != 10 }), as: UTF8.self)
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1].split(separator: "?", maxSplits: 1).first ?? "") : ""

        let code: String
        var body = Data()
        if method == "OPTIONS" {
            code = "204 No Content"
        } else if method == "GET" && path == "/game" {
            code = "200 OK"
            body = (try? JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys])) ?? Data("{}".utf8)
        } else {
            code = "404 Not Found"
            body = Data(#"{"error":"not found"}"#.utf8)
        }

        let head = """
        HTTP/1.1 \(code)\r
        Content-Type: application/json\r
        Cache-Control: no-store\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Private-Network: true\r
        Access-Control-Allow-Methods: GET, OPTIONS\r
        Access-Control-Allow-Headers: *\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
