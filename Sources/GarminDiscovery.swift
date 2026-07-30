//
//  GarminDiscovery.swift
//  HelmMirror
//
//  NWBrowser-based Bonjour discovery of Garmin chartplotters.
//
//  Browses two service types the MFD advertises on its own Wi-Fi AP:
//    _garmin-helm._tcp  (port 51200) — the Helm session (TCP)
//    _garmin-bl-id._tcp (port 80)    — pairing/identity HTTP (nginx), TXT: tag/hasDisplay/version
//
//  The two services are advertised under the SAME Bonjour instance name for one
//  physical plotter (verified against the reference client, which matches by
//  instance name). We merge them into a single DiscoveredPlotter keyed by that name.
//
//  Depends only on the public API + shared model types of HelmProtocol.swift.
//  No NWEndpoint ever leaks into the shared model — endpoints are kept in a private
//  map and resolved down to a plain host String before publishing.
//

import Foundation
import Network
import Combine

@MainActor
public final class GarminDiscovery: ObservableObject {

    // MARK: Published state

    /// One entry per physical plotter, merged from both service types.
    @Published public private(set) var plotters: [DiscoveredPlotter] = []

    /// Set once we can infer Local Network access was denied: an explicit browser
    /// failure, or the grace window elapsing with the browsers running but no results.
    /// Denial is silent on iOS, so this is necessarily a heuristic — it drives the
    /// "enable Local Network in Settings" UI. Cleared as soon as any plotter appears.
    @Published public private(set) var permissionLikelyDenied: Bool = false

    // MARK: Constants

    private static let helmType  = "_garmin-helm._tcp"
    private static let blidType  = "_garmin-bl-id._tcp"
    private static let domain    = "local."

    /// How long a `resolve` connection may take before we give up.
    private static let resolveTimeout: TimeInterval = 5.0
    /// Grace window after `start()` before empty results are read as "permission denied".
    private static let permissionGraceInterval: UInt64 = 4_000_000_000  // 4 s

    // MARK: Private state (never published)

    /// Serial queue backing both browsers and any throwaway resolve connections.
    private let queue = DispatchQueue(label: "com.jimmy.helmmirror.discovery")

    private var helmBrowser: NWBrowser?
    private var blidBrowser: NWBrowser?

    /// Latest raw result sets from each browser; the merged `plotters` list is
    /// rebuilt from these whenever either changes.
    private var helmResults: Set<NWBrowser.Result> = []
    private var blidResults: Set<NWBrowser.Result> = []

    /// plotter.id (instance name) → its helm service endpoint. Kept out of the public
    /// model; used only to hand a concrete endpoint to `resolve` / the session layer.
    private var helmEndpoints: [String: NWEndpoint] = [:]

    private var permissionCheckTask: Task<Void, Never>?

    public init() {}

    // MARK: Lifecycle

    /// Start NWBrowsers for both Garmin service types in the "local." domain and begin
    /// publishing merged results. Idempotent: a running discovery is torn down first.
    public func start() {
        stop()

        permissionLikelyDenied = false
        helmResults = []
        blidResults = []
        helmEndpoints = [:]
        plotters = []

        helmBrowser = makeBrowser(type: Self.helmType)
        blidBrowser = makeBrowser(type: Self.blidType)
        helmBrowser?.start(queue: queue)
        blidBrowser?.start(queue: queue)

        // Heuristic denial check: if nothing has resolved by the grace window, the most
        // likely cause on a real device is that Local Network access was declined.
        permissionCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.permissionGraceInterval)
            guard let self, !Task.isCancelled else { return }
            if self.plotters.isEmpty {
                self.permissionLikelyDenied = true
            }
        }
    }

    /// Cancel both browsers and the pending permission check. Leaves the last-known
    /// `plotters` in place so the UI can keep showing them; a subsequent `start()` resets.
    public func stop() {
        permissionCheckTask?.cancel()
        permissionCheckTask = nil
        helmBrowser?.cancel()
        helmBrowser = nil
        blidBrowser?.cancel()
        blidBrowser = nil
    }

    // MARK: Browser wiring

    private func makeBrowser(type: String) -> NWBrowser {
        let params = NWParameters()
        params.includePeerToPeer = false   // the MFD is an AP, not an AWDL peer

        // `bonjourWithTXTRecord` so TXT keys (tag/hasDisplay/version) ride along in
        // each result's metadata — plain `.bonjour` would omit them.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: Self.domain)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.permissionLikelyDenied = true }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Process the full result set each change (simplest + idempotent).
            Task { @MainActor in self?.ingest(results, forType: type) }
        }

        return browser
    }

    private func ingest(_ results: Set<NWBrowser.Result>, forType type: String) {
        switch type {
        case Self.helmType: helmResults = results
        case Self.blidType: blidResults = results
        default: return
        }
        rebuild()
    }

    /// Merge both result sets into one plotter per Bonjour instance name.
    private func rebuild() {
        var byId: [String: DiscoveredPlotter] = [:]
        var endpoints: [String: NWEndpoint] = [:]

        // Helm services own the helm endpoint (for resolve/session) and the helm port.
        for result in helmResults {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var plotter = byId[name] ?? DiscoveredPlotter(id: name, name: name)
            plotter.helmPort = 51200
            merge(txtRecord(from: result.metadata), into: &plotter.txt)
            byId[name] = plotter
            endpoints[name] = result.endpoint
        }

        // bl-id services contribute the pairing port and the richer TXT (tag/hasDisplay/version).
        for result in blidResults {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var plotter = byId[name] ?? DiscoveredPlotter(id: name, name: name)
            plotter.pairingPort = 80
            merge(txtRecord(from: result.metadata), into: &plotter.txt)
            byId[name] = plotter
        }

        helmEndpoints = endpoints
        plotters = byId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if !plotters.isEmpty {
            permissionLikelyDenied = false
        }
    }

    // MARK: Resolution

    /// Resolve a plotter's concrete host by opening a throwaway NWConnection to its helm
    /// endpoint and reading `currentPath.remoteEndpoint` once ready. Returns a copy with
    /// `host` set, or nil on timeout/failure. Prefers a ".local" hostname over a raw IP
    /// when the resolved endpoint exposes one.
    public func resolve(_ plotter: DiscoveredPlotter) async -> DiscoveredPlotter? {
        // Prefer the tracked helm endpoint; fall back to reconstructing one from the
        // instance name if discovery is no longer running.
        let endpoint: NWEndpoint = helmEndpoints[plotter.id]
            ?? .service(name: plotter.id, type: Self.helmType, domain: Self.domain, interface: nil)

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let connection = NWConnection(to: endpoint, using: params)
        let q = queue

        let host: String? = await withCheckedContinuation { continuation in
            let gate = ResolveGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.finish(Self.hostString(from: connection.currentPath?.remoteEndpoint))
                case .failed, .cancelled:
                    gate.finish(nil)
                default:
                    break   // .waiting can be transient; let the timeout below decide
                }
            }
            q.asyncAfter(deadline: .now() + Self.resolveTimeout) {
                gate.finish(nil)
            }
            connection.start(queue: q)
        }

        connection.cancel()

        guard let host, !host.isEmpty else { return nil }
        var resolved = plotter
        resolved.host = host
        return resolved
    }

    // MARK: Helpers

    /// One-shot bridge from the connection's callback queue to the async continuation.
    /// `NSLock`-guarded so the state handler and the timeout can race without
    /// double-resuming. Marked `@unchecked Sendable`: the lock provides the safety.
    private final class ResolveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String?, Never>

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: String?) {
            lock.lock()
            let shouldResume = !done
            done = true
            lock.unlock()
            if shouldResume { continuation.resume(returning: value) }
        }
    }

    /// Extract a usable host string from a resolved endpoint, preferring a hostname
    /// (e.g. a ".local" name) over a raw IP literal when one is present.
    private nonisolated static func hostString(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .name(let name, _): return name
            case .ipv4(let addr):    return addr.debugDescription
            case .ipv6(let addr):
                // debugDescription can carry a "%en0" zone id, and a bare IPv6
                // literal breaks URLComponents. Strip the zone and bracket it so
                // it composes correctly into http:// pairing and rtsp:// URLs.
                let raw = addr.debugDescription
                let bare = raw.split(separator: "%").first.map(String.init) ?? raw
                return "[\(bare)]"
            @unknown default:        return nil
            }
        case .service(let name, _, _, _):
            return name   // unresolved fallback (unlikely once .ready)
        default:
            return nil
        }
    }

    private func txtRecord(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else { return [:] }
        var out: [String: String] = [:]
        for (key, entry) in record {
            switch entry {
            case .string(let value): out[key] = value
            case .data(let data):    out[key] = String(data: data, encoding: .utf8) ?? ""
            case .empty:             out[key] = ""
            case .none:              break
            @unknown default:        break
            }
        }
        return out
    }

    private func merge(_ src: [String: String], into dst: inout [String: String]) {
        for (key, value) in src { dst[key] = value }
    }
}
