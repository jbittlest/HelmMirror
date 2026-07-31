//
//  PairingClient.swift
//  helmbridge
//
//  Spec item (3): one-shot HTTP pairing against the plotter's on-device nginx
//  (the `_garmin-bl-id._tcp` service, plain HTTP on port 80). Two sequential PUTs:
//
//    (a) PUT /garmin/bl-ids/<tag>           octet-stream MobileDeviceIdentity  -> 202
//    (b) PUT /garmin/bl-ids/<tag>/set-role  {"role":"owner"}                   -> 2xx
//
//  Pairing only makes the Mac visible to the plotter. The real gate is a human
//  approving it on the MFD itself:
//      Settings > Communications > Wi-Fi Network > Wi-Fi Devices > "View and Control"
//  so the caller treats any throw from here as non-fatal and carries on to the
//  Helm session.
//
//  Foundation only — no Network, no third-party packages.
//

import Foundation
import HelmProtocol

/// Registers this Mac with a Garmin chartplotter over HTTP.
///
/// Value type with no shared state: every `pair(...)` call owns its own
/// `URLSession`, so the client is safely `Sendable`.
struct PairingClient: Sendable {

    /// Plotter address: an IPv4 literal, a bracketed IPv6 literal, or a `.local` name.
    let host: String
    /// Pairing HTTP port (`_garmin-bl-id._tcp`), normally 80.
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Register this device with the plotter, then claim a role for it.
    ///
    /// - Parameters:
    ///   - deviceId: a STABLE UUID string. Reuse the same value on every run, or the
    ///     plotter creates a fresh ActiveCaptain user each time you connect.
    ///   - deviceName: the name shown on the plotter's Wi-Fi Devices list.
    ///   - role: `"owner"` | `"guest"` | `"dealer"`.
    func pair(deviceId: String, deviceName: String, role: String = "owner") async throws {
        // ONE 32-bit token feeds BOTH the URL <tag> (4 bytes little-endian, base64)
        // and protobuf field 2 (a varint); the plotter cross-checks the two, so both
        // PUTs must be built from the same value. `makePathSafeToken()` guarantees the
        // base64 contains no '+' or '/', so the tag drops into the path verbatim with
        // no percent-encoding.
        let token = Pairing.makePathSafeToken()
        let tag = Pairing.tag(for: token)

        let session = Self.makeSession()
        defer { session.finishTasksAndInvalidate() }

        // (a) Register. The plotter answers 202 Accepted and shows a new Wi-Fi device.
        let identity = Pairing.identityMessage(deviceId: deviceId,
                                               token: token,
                                               deviceName: deviceName)
        try await put(session,
                      path: "/garmin/bl-ids/\(tag)",
                      contentType: "application/octet-stream",
                      body: identity)

        // (b) Claim the role for the device just registered.
        let roleBody = try JSONEncoder().encode(RoleBody(role: role))
        try await put(session,
                      path: "/garmin/bl-ids/\(tag)/set-role",
                      contentType: "application/json",
                      body: roleBody)
    }

    // MARK: - Internals

    /// `{"role":"owner"}` — encoded with JSONEncoder so the value is escaped correctly.
    private struct RoleBody: Encodable { let role: String }

    /// Ephemeral, cookie-free session that fails fast instead of parking the whole
    /// startup sequence when the plotter is unreachable.
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.allowsCellularAccess = false          // the plotter is always on the local Wi-Fi
        return URLSession(configuration: cfg)
    }

    /// PUT `body` to `path`, succeeding on any 2xx.
    private func put(_ session: URLSession,
                     path: String,
                     contentType: String,
                     body: Data) async throws {
        let url = try makeURL(path: path)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("HelmMirror", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(host: host, port: port, reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.notHTTP(url: url.absoluteString)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.status(code: http.statusCode,
                                 path: path,
                                 detail: Self.bodySnippet(data))
        }
    }

    /// Build `http://<host>:<port><path>`. The tag is already path-safe, so it is
    /// assigned through `percentEncodedPath` and reaches the plotter byte-for-byte.
    private func makeURL(path: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = Self.normalizedHost(host)
        comps.port = port
        comps.percentEncodedPath = path
        guard let url = comps.url else {
            throw Failure.badAddress(host: host, port: port)
        }
        return url
    }

    /// URLComponents only accepts an IPv6 literal in bracketed form, and a `%zone`
    /// suffix has no meaning in a URL — strip it and add the brackets if missing.
    private static func normalizedHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(":") else { return trimmed }        // IPv4 or a hostname
        if trimmed.hasPrefix("[") { return trimmed }               // already bracketed
        let bare = trimmed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmed
        return "[\(bare)]"
    }

    /// First line or so of an error body, for the message the user sees.
    private static func bodySnippet(_ data: Data) -> String? {
        guard !data.isEmpty,
              let text = String(data: data.prefix(256), encoding: .utf8) else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Errors

extension PairingClient {
    /// Pairing failures are reported in plain English and say what to try next —
    /// the caller prints them as a warning and continues.
    enum Failure: Error, LocalizedError, Equatable {
        /// Could not reach the plotter's web server at all.
        case transport(host: String, port: Int, reason: String)
        /// The plotter answered, but not with HTTP.
        case notHTTP(url: String)
        /// The plotter answered with a non-2xx status.
        case status(code: Int, path: String, detail: String?)
        /// The host/port could not be turned into a URL.
        case badAddress(host: String, port: Int)

        var errorDescription: String? {
            switch self {
            case let .transport(host, port, reason):
                return """
                Could not reach the plotter at \(host):\(port) — \(reason). \
                Check that this Mac is joined to the plotter's Wi-Fi network and that \
                the plotter is switched on.
                """
            case let .notHTTP(url):
                return """
                \(url) answered with something that was not a web response. \
                Check that the address really is the chartplotter.
                """
            case let .status(code, path, detail):
                let tail = detail.map { " The plotter said: \($0)" } ?? ""
                return """
                The plotter refused pairing with HTTP \(code) on \(path).\(tail) \
                On the plotter go to Settings > Communications > Wi-Fi Network > \
                Wi-Fi Devices and allow "View and Control" for this Mac, then try again.
                """
            case let .badAddress(host, port):
                return """
                "\(host):\(port)" is not a usable address. \
                Pass a plain IP address, for example --host 172.16.6.0.
                """
            }
        }
    }
}
