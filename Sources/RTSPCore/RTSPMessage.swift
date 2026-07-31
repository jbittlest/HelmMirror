//
//  RTSPMessage.swift
//  HelmMirror
//
//  RTSP 1.0 message syntax (RFC 2326) — the whole of it that this player needs:
//
//    · `RTSPRequest` / `RTSPRequestBuilder` — build the seven requests we send
//    · `RTSPResponse` / `RTSPServerRequest` — parse what comes back
//    · `RTSPWireDecoder`                    — pull messages AND `$`-interleaved
//                                             RTP frames out of one octet stream
//    · `RTSPTransportHeader`                — the one header with real structure
//
//  FOUNDATION ONLY. No Network, no CoreMedia, no AVFoundation, no UIKit, no
//  logging. Every byte produced or consumed here is pinned by vectors in
//  Verify/main.swift, which run with only the Command Line Tools installed.
//
//  Frozen interface and serialization rules: SPEC §4.1. The builders' header
//  order is load-bearing — the vectors compare whole requests byte for byte.
//

import Foundation

// MARK: - Requests

/// One outgoing RTSP request. `CSeq` and `User-Agent` are implicit (see
/// `serialized()`); `headers` carries everything in between, in order.
public struct RTSPRequest {
    public let method: String
    public let uri: String
    public let cseq: Int
    /// Ordered extra headers, emitted after CSeq and before User-Agent.
    public let headers: [(name: String, value: String)]
    public let body: Data?

    public init(method: String,
                uri: String,
                cseq: Int,
                headers: [(name: String, value: String)] = [],
                body: Data? = nil) {
        self.method = method
        self.uri = uri
        self.cseq = cseq
        self.headers = headers
        self.body = body
    }

    /// Every head line in wire order, without terminators. `serialized()` joins
    /// them with CRLF, `wireText` with LF — the two must never diverge.
    private var headLines: [String] {
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)"]
        for header in headers {
            lines.append("\(header.name): \(header.value)")
        }
        lines.append("User-Agent: \(RTSPRequestBuilder.userAgent)")
        if let body {
            // Immediately before the blank line, per SPEC §4.1.
            lines.append("Content-Length: \(body.count)")
        }
        return lines
    }

    /// The exact bytes to put on the wire. CRLF line endings, blank line terminator.
    public func serialized() -> Data {
        var text = ""
        for line in headLines {
            text += line
            text += "\r\n"
        }
        text += "\r\n"
        var out = Data(text.utf8)
        if let body { out.append(body) }
        return out
    }

    /// The same text, for MirrorDiagnostics. Real "\n" newlines, no trailing
    /// blank line — NSLog renders CRLF as literal `\r` noise otherwise.
    public var wireText: String {
        headLines.joined(separator: "\n")
    }
}

/// The seven requests this player ever sends. Header contents and their order
/// are frozen (SPEC §4.1) because the vectors compare whole requests.
public enum RTSPRequestBuilder {
    public static let userAgent = "HelmMirror/1.0"

    public static func options(uri: String, cseq: Int, session: String?) -> RTSPRequest {
        // Pre-SETUP there is no session; post-PLAY, OPTIONS doubles as the
        // keepalive and must carry the id or the server ignores it.
        let headers = session.map { [(name: "Session", value: $0)] } ?? []
        return RTSPRequest(method: "OPTIONS", uri: uri, cseq: cseq, headers: headers)
    }

    public static func describe(uri: String, cseq: Int) -> RTSPRequest {
        RTSPRequest(method: "DESCRIBE", uri: uri, cseq: cseq,
                    headers: [(name: "Accept", value: "application/sdp")])
    }

    /// `RTP/AVP` — not `RTP/AVP/UDP` — is the RFC 2326 spelling and the most
    /// widely accepted; some servers reject the longer form outright.
    public static func setupUDP(uri: String, cseq: Int, clientRTPPort: UInt16) -> RTSPRequest {
        let transport = "RTP/AVP;unicast;client_port=\(clientRTPPort)-\(clientRTPPort &+ 1)"
        return RTSPRequest(method: "SETUP", uri: uri, cseq: cseq,
                           headers: [(name: "Transport", value: transport)])
    }

    public static func setupTCP(uri: String,
                                cseq: Int,
                                rtpChannel: UInt8,
                                rtcpChannel: UInt8) -> RTSPRequest {
        let transport = "RTP/AVP/TCP;unicast;interleaved=\(rtpChannel)-\(rtcpChannel)"
        return RTSPRequest(method: "SETUP", uri: uri, cseq: cseq,
                           headers: [(name: "Transport", value: transport)])
    }

    public static func play(uri: String, cseq: Int, session: String) -> RTSPRequest {
        RTSPRequest(method: "PLAY", uri: uri, cseq: cseq,
                    headers: [(name: "Session", value: session),
                              (name: "Range", value: "npt=0.000-")])
    }

    public static func getParameter(uri: String, cseq: Int, session: String) -> RTSPRequest {
        // Body-less GET_PARAMETER is the RFC 2326 §10.8 keepalive.
        RTSPRequest(method: "GET_PARAMETER", uri: uri, cseq: cseq,
                    headers: [(name: "Session", value: session)])
    }

    public static func teardown(uri: String, cseq: Int, session: String) -> RTSPRequest {
        RTSPRequest(method: "TEARDOWN", uri: uri, cseq: cseq,
                    headers: [(name: "Session", value: session)])
    }
}

// MARK: - Responses

public enum RTSPParseError: Error, Equatable {
    case malformedStatusLine
    case malformedRequestLine
    case badContentLength
    case headerSectionTooLarge      // > 64 KiB before a blank line
}

public struct RTSPResponse: Equatable {
    public let statusCode: Int
    public let reasonPhrase: String
    /// Keys lowercased and trimmed; on a repeat the LAST occurrence wins.
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, reasonPhrase: String, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var isSuccess: Bool { (200 ..< 300).contains(statusCode) }

    public var cseq: Int? {
        header("cseq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 0 when absent or unparseable — the decoder has already rejected the
    /// genuinely malformed case, so this only ever softens a missing header.
    public var contentLength: Int {
        guard let raw = header("content-length"),
              let value = Int(raw.trimmingCharacters(in: .whitespaces)),
              value >= 0 else { return 0 }
        return value
    }

    /// "Session: 8FE3A1B2;timeout=60" -> "8FE3A1B2"
    public var sessionId: String? {
        guard let raw = header("session") else { return nil }
        let id = raw.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return id.isEmpty ? nil : id
    }

    /// "Session: 8FE3A1B2;timeout=60" -> 60
    public var sessionTimeout: Int? {
        guard let raw = header("session") else { return nil }
        for piece in raw.split(separator: ";").dropFirst() {
            let part = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex ..< eq]).trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare("timeout") == .orderedSame else { continue }
            return Int(String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "RTSP/1.0 200 OK"
    public var statusLine: String {
        reasonPhrase.isEmpty ? "RTSP/1.0 \(statusCode)" : "RTSP/1.0 \(statusCode) \(reasonPhrase)"
    }

    /// Status line plus every header, one per line, for MirrorDiagnostics.
    /// Sorted by name so the same response always logs identically (a Dictionary
    /// has no stable order and an unstable log is unreadable).
    public var headText: String {
        ([statusLine] + headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" })
            .joined(separator: "\n")
    }
}

/// A request the *server* sent us (some poll with OPTIONS, some push ANNOUNCE).
public struct RTSPServerRequest: Equatable {
    public let method: String
    public let uri: String
    public let cseq: Int?
    public let headers: [String: String]

    public init(method: String, uri: String, cseq: Int?, headers: [String: String]) {
        self.method = method
        self.uri = uri
        self.cseq = cseq
        self.headers = headers
    }
}

/// One `$`-interleaved binary frame (RFC 2326 §10.12).
public struct RTSPInterleavedFrame: Equatable {
    public let channel: UInt8
    public let payload: Data

    public init(channel: UInt8, payload: Data) {
        self.channel = channel
        self.payload = payload
    }
}

public enum RTSPStreamItem: Equatable {
    case response(RTSPResponse)
    case request(RTSPServerRequest)          // server-initiated (OPTIONS, ANNOUNCE, ...)
    case interleaved(RTSPInterleavedFrame)
}

// MARK: - Wire decoder

/// Pulls one item at a time out of the RTSP TCP octet stream. Text messages and
/// binary `$` frames share that stream, which is why they share a decoder.
public enum RTSPWireDecoder {

    /// A header section larger than this is a broken peer, not a big message.
    private static let maxHeadBytes = 65536

    /// Decode exactly one item from `bytes[start...]`.
    /// Returns nil when more bytes are needed. Throws only on malformed framing.
    public static func decode(_ bytes: [UInt8], from start: Int = 0)
        throws -> (item: RTSPStreamItem, consumed: Int)? {

        guard start < bytes.count else { return nil }

        // 1. `$` — a binary frame: [0x24][channel][u16 BE length][payload]
        if bytes[start] == 0x24 {
            guard bytes.count - start >= 4 else { return nil }
            let channel = bytes[start + 1]
            let length = Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
            guard bytes.count - start >= 4 + length else { return nil }
            let payload = Data(bytes[(start + 4) ..< (start + 4 + length)])
            return (.interleaved(RTSPInterleavedFrame(channel: channel, payload: payload)),
                    4 + length)
        }

        // 2. Otherwise a text message. Find the head terminator.
        guard let (headEnd, terminatorStart) = findHeadTerminator(bytes, from: start) else {
            if bytes.count - start > maxHeadBytes { throw RTSPParseError.headerSectionTooLarge }
            return nil
        }

        let head = String(decoding: bytes[start ..< terminatorStart], as: UTF8.self)
        let lines = foldedLines(of: head)
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            throw RTSPParseError.malformedStatusLine
        }
        let headers = parseHeaders(lines.dropFirst())

        // 3. A response's head is followed by Content-Length bytes of body.
        if firstLine.uppercased().hasPrefix("RTSP/") {
            let (code, reason) = try parseStatusLine(firstLine)

            var bodyLength = 0
            if let raw = headers["content-length"] {
                guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                    throw RTSPParseError.badContentLength
                }
                bodyLength = value
            }
            let consumed = (headEnd - start) + bodyLength
            guard bytes.count - start >= consumed else { return nil }

            let bodyStart = headEnd
            let body = bodyLength > 0 ? Data(bytes[bodyStart ..< (bodyStart + bodyLength)]) : Data()
            let response = RTSPResponse(statusCode: code,
                                        reasonPhrase: reason,
                                        headers: headers,
                                        body: body)
            return (.response(response), consumed)
        }

        // 4. Server-initiated request. Assumed body-less (SPEC §4.1 rule 7).
        let tokens = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // The guard rail: without checking the version token an "HTTP/1.1 200 OK"
        // status line would silently decode as a request for method "HTTP/1.1".
        guard tokens.count >= 3, tokens[2].uppercased().hasPrefix("RTSP/") else {
            throw RTSPParseError.malformedRequestLine
        }
        let cseq = headers["cseq"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let request = RTSPServerRequest(method: tokens[0],
                                        uri: tokens[1],
                                        cseq: cseq,
                                        headers: headers)
        return (.request(request), headEnd - start)
    }

    /// The first `\r\n\r\n` or `\n\n`, whichever starts earlier.
    /// Returns (index just past the terminator, index of its first byte).
    private static func findHeadTerminator(_ bytes: [UInt8], from start: Int)
        -> (headEnd: Int, terminatorStart: Int)? {

        var i = start
        while i < bytes.count {
            if bytes[i] == 0x0A {
                // "\n\n"
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    return (i + 2, i)
                }
                // "\r\n\r\n" — this LF is the second byte of the first CRLF.
                if i >= start + 1, bytes[i - 1] == 0x0D,
                   i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    return (i + 3, i - 1)
                }
            }
            i += 1
        }
        return nil
    }

    /// Split on CRLF or bare LF, then fold continuation lines (RFC 2326 §12):
    /// a line beginning with SP or HT continues the previous one.
    private static func foldedLines(of head: String) -> [String] {
        var out: [String] = []
        for raw in head.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                out.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
            }
        }
        return out
    }

    /// "RTSP/1.0 200 OK" -> (200, "OK"). A non-integer code is fatal.
    private static func parseStatusLine(_ line: String) throws -> (code: Int, reason: String) {
        let tokens = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard tokens.count >= 2, let code = Int(tokens[1].trimmingCharacters(in: .whitespaces)) else {
            throw RTSPParseError.malformedStatusLine
        }
        let reason = tokens.count >= 3 ? tokens[2].trimmingCharacters(in: .whitespaces) : ""
        return (code, reason)
    }

    /// Name lowercased and trimmed, value trimmed. A line with no ':' is ignored.
    /// On a repeated name the LAST occurrence wins.
    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex ..< colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            headers[name] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        return headers
    }
}

// MARK: - Transport header

/// The `Transport:` header, which is the only RTSP header with real structure —
/// and the one that decides whether RTP arrives on a UDP socket or `$`-framed on
/// the RTSP connection itself.
public struct RTSPTransportHeader: Equatable {
    public let raw: String
    public let isTCPInterleaved: Bool
    public let rtpChannel: UInt8?
    public let rtcpChannel: UInt8?
    public let clientRTPPort: UInt16?
    public let clientRTCPPort: UInt16?
    public let serverRTPPort: UInt16?
    public let serverRTCPPort: UInt16?
    public let source: String?
    public let ssrc: UInt32?

    public init(raw: String,
                isTCPInterleaved: Bool,
                rtpChannel: UInt8?,
                rtcpChannel: UInt8?,
                clientRTPPort: UInt16?,
                clientRTCPPort: UInt16?,
                serverRTPPort: UInt16?,
                serverRTCPPort: UInt16?,
                source: String?,
                ssrc: UInt32?) {
        self.raw = raw
        self.isTCPInterleaved = isTCPInterleaved
        self.rtpChannel = rtpChannel
        self.rtcpChannel = rtcpChannel
        self.clientRTPPort = clientRTPPort
        self.clientRTCPPort = clientRTCPPort
        self.serverRTPPort = serverRTPPort
        self.serverRTCPPort = serverRTCPPort
        self.source = source
        self.ssrc = ssrc
    }

    /// Parses the FIRST transport-spec if several are comma-separated. Never
    /// throws and never crashes: an unrecognised header yields all-nil.
    public static func parse(_ value: String) -> RTSPTransportHeader {
        let spec = String(value.split(separator: ",", maxSplits: 1,
                                      omittingEmptySubsequences: false).first ?? "")
        let parts = spec.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let proto = parts.first ?? ""
        let isTCP = proto.uppercased().contains("/TCP")

        var interleaved: (UInt16, UInt16)?
        var clientPorts: (UInt16, UInt16)?
        var serverPorts: (UInt16, UInt16)?
        var source: String?
        var ssrc: UInt32?

        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex ..< eq])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "interleaved": interleaved = pair(value)
            case "client_port": clientPorts = pair(value)
            case "server_port": serverPorts = pair(value)
            case "source":      source = value.isEmpty ? nil : value
            case "ssrc":        ssrc = UInt32(value, radix: 16)
            default:            break
            }
        }

        return RTSPTransportHeader(
            raw: value,
            isTCPInterleaved: isTCP,
            rtpChannel: interleaved.map { UInt8(truncatingIfNeeded: $0.0) },
            rtcpChannel: interleaved.map { UInt8(truncatingIfNeeded: $0.1) },
            clientRTPPort: clientPorts?.0,
            clientRTCPPort: clientPorts?.1,
            serverRTPPort: serverPorts?.0,
            serverRTCPPort: serverPorts?.1,
            source: source,
            ssrc: ssrc)
    }

    /// "6970-6971" -> (6970, 6971); "9244" -> (9244, 9245). nil when unparseable.
    private static func pair(_ value: String) -> (UInt16, UInt16)? {
        let halves = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = halves.first.flatMap({ UInt16($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        if halves.count >= 2,
           let second = UInt16(halves[1].trimmingCharacters(in: .whitespaces)) {
            return (first, second)
        }
        return (first, first &+ 1)
    }
}
