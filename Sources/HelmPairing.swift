//
//  HelmPairing.swift
//  HelmMirror
//
//  One-time HTTP pairing against the plotter's on-device nginx (the
//  `_garmin-bl-id._tcp` service, port 80). Two sequential PUTs:
//    (a) register a MobileDeviceIdentity protobuf  -> expect HTTP 202
//    (b) set the client's role                     -> expect any 2xx
//  After (a) the MFD shows "a new ActiveCaptain user was added"; the user must
//  still approve "View and Control" once on the plotter itself (see SPEC §4.10c).
//
//  Foundation-only. Depends solely on the frozen public API of HelmProtocol
//  (`Pairing.makePathSafeToken()` / `Pairing.tag(for:)` / `Pairing.identityMessage(...)`
//  and the shared `HelmError`). No Network, UIKit, or VLC.
//

import Foundation

public struct HelmPairing {
    /// Resolved plotter host — a concrete IPv4 literal or a ".local" hostname.
    /// Prefer the ".local" name when the caller has it: that is the unambiguous
    /// local-networking case for ATS (see SPEC §9, `NSAllowsLocalNetworking`).
    public let host: String
    /// Pairing HTTP port (`_garmin-bl-id._tcp`). Default 80.
    public let port: Int

    public init(host: String, port: Int = 80) {
        self.host = host
        self.port = port
    }

    /// Register this device with the plotter, then set its role.
    ///
    /// - Parameters:
    ///   - deviceId: a STABLE app UUID. Persist it and pass the same value on every
    ///     run so the plotter does not spawn a fresh ActiveCaptain user each time.
    ///   - deviceName: human-readable name shown on the MFD (e.g. the device name).
    ///   - role: "guest" | "owner" | "dealer". v1 default "owner".
    ///
    /// Throws `HelmError.http(code)` on any non-2xx response, `HelmError.pairingRejected`
    /// if the response is not HTTP, or `HelmError.connectionFailed(_)` on transport failure.
    public func pair(deviceId: String, deviceName: String, role: String = "owner") async throws {
        // One token feeds BOTH the URL <tag> (4 bytes LE) and the protobuf field 2
        // (as a varint); the plotter cross-checks them, so they must derive from the
        // same value. `makePathSafeToken()` guarantees the tag has no '+' or '/', so it
        // drops into the URL path verbatim (no percent-encoding — SPEC §4.9).
        let token = Pairing.makePathSafeToken()
        let tag = Pairing.tag(for: token)

        // (a) Register / pair: PUT /garmin/bl-ids/<tag>  (octet-stream protobuf body).
        let identity = Pairing.identityMessage(deviceId: deviceId,
                                               token: token,
                                               deviceName: deviceName)
        let registerURL = try makeURL(path: "/garmin/bl-ids/\(tag)")
        let registerReq = makeRequest(url: registerURL,
                                      contentType: "application/octet-stream",
                                      body: identity)
        try await performExpecting2xx(registerReq)

        // (b) Set role: PUT /garmin/bl-ids/<tag>/set-role  (JSON body).
        let roleBody = try JSONEncoder().encode(RoleBody(role: role))
        let roleURL = try makeURL(path: "/garmin/bl-ids/\(tag)/set-role")
        let roleReq = makeRequest(url: roleURL,
                                  contentType: "application/json",
                                  body: roleBody)
        try await performExpecting2xx(roleReq)
    }

    // MARK: - Internals

    /// `{"role":"owner"}` — encoded via JSONEncoder for correct escaping.
    private struct RoleBody: Encodable { let role: String }

    /// One-shot ephemeral session: no cookies, no cache, bounded timeout.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpShouldSetCookies = false
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Build `http://<host>:<port><path>`. The tag in `path` is already path-safe,
    /// so it is assigned via `percentEncodedPath` without further escaping.
    private func makeURL(path: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        comps.percentEncodedPath = path
        guard let url = comps.url else {
            throw HelmError.connectionFailed("invalid pairing URL for host \(host):\(port)")
        }
        return url
    }

    private func makeRequest(url: URL, contentType: String, body: Data) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        // Base headers on every pairing request (SPEC §4.10).
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("HelmMirror-iOS", forHTTPHeaderField: "User-Agent")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    /// Perform the request; succeed on any 2xx, otherwise throw a typed `HelmError`.
    private func performExpecting2xx(_ request: URLRequest) async throws {
        let response: URLResponse
        do {
            (_, response) = try await Self.session.data(for: request)
        } catch let error as HelmError {
            throw error
        } catch {
            throw HelmError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HelmError.pairingRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HelmError.http(http.statusCode)
        }
    }
}
