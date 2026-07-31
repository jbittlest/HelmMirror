//
//  WebServer.swift
//  helmbridge
//
//  A deliberately small HTTP/1.1 server built on NWListener. It has exactly one
//  job: hand the phone the mirror page, the HLS playlist and its segments, and
//  take touches back. No frameworks beyond Foundation + Network.
//
//  Routes
//    GET  /             -> Web/index.html
//    GET  /<asset>      -> webRoot (.html .js .png .webmanifest only)
//    GET  /stream.m3u8  -> hlsDir  (application/vnd.apple.mpegurl, no-store)
//    GET  /seg*.ts      -> hlsDir  (video/mp2t)
//    GET  /status       -> {"streaming":bool,"detail":"..."}
//    POST /touch        -> {"x":Double,"y":Double,"down":0|1} -> 204
//    anything else      -> 404
//

import Foundation
import Network

// MARK: - Errors

enum WebServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case listenFailed(port: UInt16, underlying: String)

    var description: String {
        switch self {
        case .invalidPort(let p):
            return "Port \(p) is not a usable port number. Try --port 8080."
        case .listenFailed(let port, let underlying):
            return """
            Could not open port \(port) on this Mac (\(underlying)).
            Something else is probably already using it — run again with, for \
            example, --port 8081.
            """
        }
    }
}

// MARK: - Limits

/// The phone only ever sends a request line, a few headers and a ~60 byte
/// touch body, so everything here is generous.
private enum Limits {
    static let headerBytes = 16 * 1024
    static let bodyBytes = 32 * 1024
    static let requestBytes = 64 * 1024
    static let readChunk = 32 * 1024
    static let maxConnections = 64
    /// Keep-alive sockets that go quiet for this long are reclaimed, so a phone
    /// that walks out of Wi-Fi range cannot leak a connection.
    static let idleTimeout: TimeInterval = 90
    static let reapInterval: UInt64 = 15_000_000_000  // 15 s
}

// MARK: - WebServer

actor WebServer {

    typealias TouchHandler = @Sendable (Double, Double, Bool) async -> Void
    typealias StatusProvider = @Sendable () async -> (streaming: Bool, detail: String)

    private let port: UInt16
    private let webRoot: URL
    private let hlsDir: URL
    private let onTouch: TouchHandler
    private let statusProvider: StatusProvider

    private let queue = DispatchQueue(label: "helmbridge.web", qos: .userInitiated)
    private var listener: NWListener?
    private var reaper: Task<Void, Never>?
    private var clients: [UInt64: Client] = [:]
    private var nextClientID: UInt64 = 0

    init(port: UInt16,
         webRoot: URL,
         hlsDir: URL,
         onTouch: @escaping @Sendable (Double, Double, Bool) async -> Void,
         status: @escaping @Sendable () async -> (streaming: Bool, detail: String)) {
        self.port = port
        self.webRoot = webRoot
        self.hlsDir = hlsDir
        self.onTouch = onTouch
        self.statusProvider = status
    }

    // MARK: Lifecycle

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw WebServerError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true            // touches must not wait on Nagle
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw WebServerError.listenFailed(port: port, underlying: "\(error)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            let reason = "\(error)"
            Task { await self?.listenerFailed(reason) }
        }

        self.listener = listener
        listener.start(queue: queue)

        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Limits.reapInterval)
                guard let self, !Task.isCancelled else { return }
                await self.reapIdleConnections()
            }
        }
    }

    func stop() {
        reaper?.cancel()
        reaper = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { close(id) }   // close() mutates `clients`
    }

    private func listenerFailed(_ reason: String) {
        let message = WebServerError.listenFailed(port: port, underlying: reason).description
        FileHandle.standardError.write(Data(("\n" + message + "\n").utf8))
        stop()
    }

    // MARK: Connections

    private struct Client {
        let connection: NWConnection
        var inbound = Data()
        /// True while `pump` owns this client, so a late read cannot start a
        /// second parse of the same buffer.
        var parsing = false
        var peerFinished = false
        var lastActivity = Date()

        init(connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        // At the cap, drop the stalest socket rather than the caller: a phone
        // that just tapped must never be turned away by connections a previous
        // page left lying around.
        while clients.count >= Limits.maxConnections {
            guard let stalest = clients.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key else { break }
            close(stalest)
        }

        let id = nextClientID
        nextClientID &+= 1
        clients[id] = Client(connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.forget(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func close(_ id: UInt64) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }

    private func forget(_ id: UInt64) {
        clients.removeValue(forKey: id)
    }

    private func reapIdleConnections() {
        let cutoff = Date().addingTimeInterval(-Limits.idleTimeout)
        for (id, client) in clients where client.lastActivity < cutoff {
            close(id)
        }
    }

    /// Exactly one read is outstanding per connection at any time: a read is
    /// only re-armed from `pump` once the buffer holds no further request.
    private func receive(_ id: UInt64) {
        guard let connection = clients[id]?.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Limits.readChunk) { [weak self] data, _, isComplete, error in
            // Only Sendable values are carried back into the actor.
            let chunk = data
            let finished = isComplete
            let failed = error != nil
            Task { await self?.ingest(id: id, chunk: chunk, finished: finished, failed: failed) }
        }
    }

    private func ingest(id: UInt64, chunk: Data?, finished: Bool, failed: Bool) async {
        guard clients[id] != nil else { return }
        if failed { close(id); return }

        if let chunk, !chunk.isEmpty {
            clients[id]?.inbound.append(chunk)
            clients[id]?.lastActivity = Date()
        }
        if finished { clients[id]?.peerFinished = true }

        await pump(id)
    }

    /// Parse and answer every complete request sitting in the buffer, then
    /// either re-arm the read or close.
    private func pump(_ id: UInt64) async {
        guard var client = clients[id], !client.parsing else { return }
        client.parsing = true
        clients[id] = client

        while true {
            guard let buffer = clients[id]?.inbound else { return }

            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                guard var current = clients[id] else { return }
                current.parsing = false
                clients[id] = current
                if current.peerFinished {
                    close(id)          // peer sent FIN mid-request: nothing more is coming
                } else {
                    receive(id)
                }
                return

            case .invalid(let status, let reason):
                clients[id]?.parsing = false
                respond(id: id, response: .status(status, reason: reason), keepAlive: false)
                return

            case .complete(let request, let consumed):
                guard clients[id] != nil else { return }
                clients[id]?.inbound = Data(buffer.dropFirst(consumed))

                let response = await makeResponse(for: request)

                // The actor suspended while building the response; the client
                // may have gone away in the meantime.
                guard clients[id] != nil else { return }
                let keepAlive = request.keepAlive && clients[id]?.peerFinished != true
                respond(id: id, response: response, keepAlive: keepAlive)

                if !keepAlive {
                    clients[id]?.parsing = false
                    return
                }
                // Loop: a pipelined request may already be in the buffer.
            }
        }
    }

    private func respond(id: UInt64, response: HTTPResponse, keepAlive: Bool) {
        guard let connection = clients[id]?.connection else { return }
        clients[id]?.lastActivity = Date()

        let bytes = response.serialized(keepAlive: keepAlive)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            guard !keepAlive else { return }
            Task { await self?.close(id) }
        })
    }

    // MARK: Routing

    private func makeResponse(for request: HTTPRequest) async -> HTTPResponse {
        // A cross-origin JSON POST from the page triggers a CORS preflight;
        // answer it so /touch is reachable when the page was not served by us.
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, reason: "No Content", headers: [
                ("Access-Control-Allow-Methods", "GET, HEAD, POST, OPTIONS"),
                ("Access-Control-Allow-Headers", "Content-Type"),
                ("Access-Control-Max-Age", "600")
            ])
        }

        guard let path = SafePath(target: request.target) else {
            return .status(404, reason: "Not Found")   // traversal attempt or unparseable target
        }

        let isRead = request.method == "GET" || request.method == "HEAD"
        let omitBody = request.method == "HEAD"

        if isRead {
            // Root document.
            if path.components.isEmpty {
                return file(under: webRoot,
                            components: ["index.html"],
                            contentType: "text/html; charset=utf-8",
                            cacheControl: nil,
                            omitBody: omitBody)
            }

            if path.components.count == 1 {
                let name = path.components[0]

                if name == "status" {
                    let (streaming, detail) = await statusProvider()
                    return .json(statusJSON(streaming: streaming, detail: detail), omitBody: omitBody)
                }
                if name == "stream.m3u8" {
                    return file(under: hlsDir,
                                components: [name],
                                contentType: "application/vnd.apple.mpegurl",
                                cacheControl: "no-store",
                                omitBody: omitBody)
                }
                if name.hasPrefix("seg"), name.hasSuffix(".ts") {
                    return file(under: hlsDir,
                                components: [name],
                                contentType: "video/mp2t",
                                cacheControl: nil,
                                omitBody: omitBody)
                }
            }

            // Static assets from the bundled Web directory, allow-listed by type.
            if let type = Self.assetContentTypes[path.fileExtension] {
                return file(under: webRoot,
                            components: path.components,
                            contentType: type,
                            cacheControl: nil,
                            omitBody: omitBody)
            }

            return .status(404, reason: "Not Found")
        }

        if request.method == "POST", path.components == ["touch"] {
            guard let touch = TouchCommand(json: request.body) else {
                return .status(400, reason: "Bad Request")
            }
            await onTouch(touch.x, touch.y, touch.down)
            return HTTPResponse(status: 204, reason: "No Content")
        }

        return .status(404, reason: "Not Found")
    }

    private static let assetContentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "png": "image/png",
        "webmanifest": "application/manifest+json"
    ]

    private func statusJSON(streaming: Bool, detail: String) -> Data {
        let object: [String: Any] = ["streaming": streaming, "detail": detail]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: []) {
            return data
        }
        return Data(#"{"streaming":false,"detail":"status unavailable"}"#.utf8)
    }

    // MARK: File serving

    /// Serves `components` from `root` — but only after proving the resolved
    /// path really is inside `root`. Anything else is a 404, never a read.
    private func file(under root: URL,
                      components: [String],
                      contentType: String,
                      cacheControl: String?,
                      omitBody: Bool) -> HTTPResponse {
        guard let url = Self.resolve(components, under: root),
              let data = try? Data(contentsOf: url) else {
            return .status(404, reason: "Not Found")
        }

        var headers = [("Content-Type", contentType)]
        if let cacheControl { headers.append(("Cache-Control", cacheControl)) }
        return HTTPResponse(status: 200, reason: "OK", headers: headers, body: data, omitBody: omitBody)
    }

    private static func resolve(_ components: [String], under root: URL) -> URL? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var candidate = root
        for component in components { candidate.appendPathComponent(component) }

        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolved.path
        // Belt and braces: SafePath already rejected "..", this catches symlinks
        // that point out of the directory we are willing to serve.
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return resolved
    }
}

// MARK: - Safe path

/// A request target reduced to plain, traversal-free path components.
private struct SafePath {
    let components: [String]
    /// Lowercased extension of the last component, "" when there is none.
    let fileExtension: String

    init?(target: String) {
        // Strip query and fragment, then percent-decode once.
        var raw = target
        if let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            raw = String(raw[raw.startIndex..<cut])
        }
        // Absolute-form targets ("GET http://host/path") are legal HTTP/1.1.
        if let range = raw.range(of: "://"),
           let slash = raw[range.upperBound...].firstIndex(of: "/") {
            raw = String(raw[slash...])
        }
        guard let decoded = raw.removingPercentEncoding else { return nil }

        // Reject anything that could escape the served directory or confuse the
        // file system, before it ever reaches a path API.
        guard !decoded.contains("\0"), !decoded.contains("\\"), !decoded.contains("..") else { return nil }

        var parts: [String] = []
        for piece in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(piece)
            guard component != ".", component != ".." else { return nil }
            guard !component.hasPrefix(".") else { return nil }   // no dotfiles
            parts.append(component)
        }

        self.components = parts
        if let last = parts.last, let dot = last.lastIndex(of: "."), dot != last.startIndex {
            self.fileExtension = String(last[last.index(after: dot)...]).lowercased()
        } else {
            self.fileExtension = ""
        }
    }
}

// MARK: - Touch command

private struct TouchCommand {
    let x: Double
    let y: Double
    let down: Bool

    /// {"x":0.42,"y":0.87,"down":1} — `down` may be 0/1 or true/false.
    init?(json: Data) {
        guard !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: json, options: []),
              let dict = object as? [String: Any],
              let rawX = (dict["x"] as? NSNumber)?.doubleValue,
              let rawY = (dict["y"] as? NSNumber)?.doubleValue,
              rawX.isFinite, rawY.isFinite else { return nil }

        self.x = min(1, max(0, rawX))
        self.y = min(1, max(0, rawY))
        self.down = (dict["down"] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - HTTP request

private struct HTTPRequest {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]     // keys lowercased
    let body: Data
    let keepAlive: Bool

    enum ParseResult {
        case incomplete
        case invalid(Int, reason: String)
        case complete(HTTPRequest, consumed: Int)
    }

    /// Parses one request from the head of `buffer`. `buffer` is a stream, so a
    /// partial request is normal and simply means "read more".
    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = findHeaderEnd(buffer) else {
            if buffer.count > Limits.headerBytes {
                return .invalid(431, reason: "Request Header Fields Too Large")
            }
            return .incomplete
        }
        if headerEnd > Limits.headerBytes {
            return .invalid(431, reason: "Request Header Fields Too Large")
        }

        let base = buffer.startIndex
        // Split on the wire bytes, not on Characters: Swift treats CRLF as a
        // single grapheme, so String.split(separator: "\n") never fires here.
        var lines = splitCRLF(buffer[base..<(base + headerEnd)])
        guard !lines.isEmpty else { return .invalid(400, reason: "Bad Request") }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid(400, reason: "Bad Request") }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let version = requestLine.count >= 3 ? String(requestLine[2]).uppercased() : "HTTP/1.0"

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        // We never advertise chunked upload support and the page never uses it.
        if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            return .invalid(411, reason: "Length Required")
        }

        var contentLength = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return .invalid(400, reason: "Bad Request")
            }
            contentLength = value
        }
        if contentLength > Limits.bodyBytes {
            return .invalid(413, reason: "Payload Too Large")
        }

        let bodyStart = headerEnd + 4
        let total = bodyStart + contentLength
        guard buffer.count >= total else {
            if buffer.count > Limits.requestBytes {
                return .invalid(413, reason: "Payload Too Large")
            }
            return .incomplete
        }
        let body = Data(buffer[(base + bodyStart)..<(base + total)])

        let connection = headers["connection"]?.lowercased() ?? ""
        let keepAlive: Bool = {
            if connection.contains("close") { return false }
            if version == "HTTP/1.0" { return connection.contains("keep-alive") }
            return true
        }()

        let request = HTTPRequest(method: method,
                                  target: target,
                                  version: version,
                                  headers: headers,
                                  body: body,
                                  keepAlive: keepAlive)
        return .complete(request, consumed: total)
    }

    /// Splits a header block into lines on literal CRLF pairs.
    private static func splitCRLF(_ block: Data.SubSequence) -> [String] {
        let bytes = [UInt8](block)
        var lines: [String] = []
        var start = 0
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x0D, bytes[i + 1] == 0x0A {
                lines.append(String(decoding: bytes[start..<i], as: UTF8.self))
                i += 2
                start = i
            } else {
                i += 1
            }
        }
        if start < bytes.count {
            lines.append(String(decoding: bytes[start...], as: UTF8.self))
        }
        return lines
    }

    /// Offset of the CRLF CRLF that ends the header block, relative to the
    /// start of `data`.
    private static func findHeaderEnd(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let limit = bytes.count - 4
            while i <= limit {
                if bytes[i] == 0x0D, bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                    return i
                }
                i += 1
            }
            return nil
        }
    }
}

// MARK: - HTTP response

private struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [(String, String)] = []
    var body: Data = Data()
    var omitBody: Bool = false        // HEAD: headers only, Content-Length still accurate

    static func status(_ code: Int, reason: String) -> HTTPResponse {
        let text = "\(code) \(reason)\n"
        return HTTPResponse(status: code,
                            reason: reason,
                            headers: [("Content-Type", "text/plain; charset=utf-8")],
                            body: Data(text.utf8))
    }

    static func json(_ data: Data, omitBody: Bool) -> HTTPResponse {
        HTTPResponse(status: 200,
                     reason: "OK",
                     headers: [("Content-Type", "application/json; charset=utf-8"),
                               ("Cache-Control", "no-store")],
                     body: data,
                     omitBody: omitBody)
    }

    func serialized(keepAlive: Bool) -> Data {
        let hasBody = status != 204 && status != 304
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        // The phone may load the page from anywhere; every reply is open.
        head += "Access-Control-Allow-Origin: *\r\n"
        if hasBody {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var out = Data(head.utf8)
        if hasBody && !omitBody {
            out.append(body)
        }
        return out
    }
}
