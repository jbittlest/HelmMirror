//
//  BonjourFinder.swift
//  helmbridge
//
//  Finds the Garmin chartplotter on the local Wi-Fi and resolves it to a concrete
//  address we can actually open sockets to.
//
//  The MFD advertises two Bonjour services, both under the same instance name:
//    _garmin-helm._tcp   port 51200 — the proprietary Helm session
//    _garmin-bl-id._tcp  port 80    — the pairing/identity HTTP endpoint (nginx)
//
//  NWBrowser hands back `.service` endpoints, never addresses. The supported way to
//  turn one into an address is to open a throwaway NWConnection and read the ready
//  path's remote endpoint, so that is what `resolve` does. Results from the two
//  browsers are merged by resolved host, which is what identifies one physical
//  plotter regardless of which service answered first.
//

import Foundation
import Network

/// A chartplotter that has been discovered *and* resolved to a usable address.
/// `host` is either a hostname, a plain IPv4 literal, or a bracketed IPv6 literal
/// (e.g. "[fe80::1]") so it can be pasted straight into an http:// or rtsp:// URL.
struct FoundPlotter: Sendable {
    let name: String
    let host: String
    let helmPort: Int
    let pairingPort: Int
}

enum BonjourFinder {

    // MARK: Constants

    private static let helmType    = "_garmin-helm._tcp"
    private static let pairingType = "_garmin-bl-id._tcp"
    private static let domain      = "local."

    private static let defaultHelmPort    = 51200
    private static let defaultPairingPort = 80

    /// How long one throwaway resolve connection may take before we give up on it.
    private static let resolveTimeout: TimeInterval = 3.0

    /// Once one service of a plotter has resolved, how long to keep listening for its
    /// sibling service before answering with the default port filled in.
    private static let settleInterval: TimeInterval = 1.5

    private enum ServiceKind: String, Sendable {
        case helm
        case pairing
    }

    // MARK: API

    /// Browse both Garmin service types and return the first plotter that resolves.
    /// Returns as soon as one host has answered on both services, or `settleInterval`
    /// after the first service resolves, whichever comes first. Returns nil if nothing
    /// is found within `timeout`.
    static func findFirst(timeout: TimeInterval) async -> FoundPlotter? {
        let merger = Merger(settle: settleInterval)
        let queue = DispatchQueue(label: "com.jimmy.helmbridge.bonjour")

        let helmBrowser = makeBrowser(type: helmType, queue: queue) { endpoint, name in
            Task { await merger.resolveIfNew(endpoint: endpoint, name: name, kind: .helm, queue: queue) }
        }
        let pairingBrowser = makeBrowser(type: pairingType, queue: queue) { endpoint, name in
            Task { await merger.resolveIfNew(endpoint: endpoint, name: name, kind: .pairing, queue: queue) }
        }
        defer {
            helmBrowser.cancel()
            pairingBrowser.cancel()
        }

        // `wait` only returns once the merger has finished, and finishing cancels every
        // in-flight resolve, so no connection outlives this call.
        return await merger.wait(timeout: timeout)
    }

    // MARK: Browsing

    private static func makeBrowser(type: String,
                                    queue: DispatchQueue,
                                    onService: @escaping @Sendable (NWEndpoint, String) -> Void) -> NWBrowser {
        let params = NWParameters()
        params.includePeerToPeer = false   // the plotter is a Wi-Fi AP, not an AWDL peer

        let browser = NWBrowser(for: .bonjour(type: type, domain: domain), using: params)

        browser.browseResultsChangedHandler = { results, _ in
            // The handler always delivers the complete result set; the merger dedupes.
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                onService(result.endpoint, name)
            }
        }

        browser.start(queue: queue)
        return browser
    }

    // MARK: Resolution

    /// Turn a Bonjour `.service` endpoint into a host/port pair by connecting to it and
    /// reading the established path's remote endpoint. Returns nil on failure, timeout,
    /// or task cancellation.
    private static func resolve(_ endpoint: NWEndpoint,
                                queue: DispatchQueue) async -> (host: String, port: Int)? {
        // Ask for IPv4 first. The plotter's own Wi-Fi network is IPv4 (172.16.6.x), and an
        // IPv6 link-local answer would lose its scope id below, leaving an address that
        // neither URLSession nor ffmpeg can use. Fall back to whatever the plotter offers.
        if let viaIPv4 = await connect(to: endpoint, queue: queue, ipVersion: .v4) { return viaIPv4 }
        guard !Task.isCancelled else { return nil }
        return await connect(to: endpoint, queue: queue, ipVersion: .any)
    }

    private static func connect(to endpoint: NWEndpoint,
                                queue: DispatchQueue,
                                ipVersion: NWProtocolIP.Options.Version) async -> (host: String, port: Int)? {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = ipVersion
        }

        let connection = NWConnection(to: endpoint, using: params)
        let gate = ResolveGate()

        let resolved = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(host: String, port: Int)?, Never>) in
                gate.arm(continuation)

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.finish(hostPort(from: connection.currentPath?.remoteEndpoint))
                    case .failed, .cancelled:
                        gate.finish(nil)
                    default:
                        break   // .waiting can be transient; the timeout below decides
                    }
                }

                queue.asyncAfter(deadline: .now() + resolveTimeout) { gate.finish(nil) }
                connection.start(queue: queue)
            }
        } onCancel: {
            gate.finish(nil)
            connection.cancel()
        }

        connection.cancel()
        return resolved
    }

    private static func hostPort(from endpoint: NWEndpoint?) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port)? = endpoint,
              let hostText = hostString(host) else { return nil }
        return (hostText, Int(port.rawValue))
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case let .name(name, _):
            let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
            return trimmed.isEmpty ? nil : trimmed

        case let .ipv4(address):
            let literal = withoutZone(address.debugDescription)
            return literal.isEmpty ? nil : literal

        case let .ipv6(address):
            // Hand back the IPv4 form of a v4-mapped address; callers want to build URLs.
            if let mapped = address.asIPv4 {
                let literal = withoutZone(mapped.debugDescription)
                return literal.isEmpty ? nil : literal
            }
            // A bare IPv6 literal breaks URL parsing (and ffmpeg's -i argument), and the
            // "%en0" scope id link-local addresses carry breaks it further, so strip the
            // zone and bracket what is left.
            let literal = withoutZone(address.debugDescription)
            return literal.isEmpty ? nil : "[\(literal)]"

        @unknown default:
            return nil
        }
    }

    private static func withoutZone(_ description: String) -> String {
        description.split(separator: "%").first.map(String.init) ?? description
    }

    /// One-shot bridge from Network.framework's callback queue to a continuation.
    /// Lock-guarded so the state handler, the timeout and task cancellation can race
    /// without ever double-resuming, and so a cancellation that lands before the
    /// continuation is armed is still delivered.
    private final class ResolveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(host: String, port: Int)?, Never>?
        private var result: (host: String, port: Int)?
        private var isFinished = false

        func arm(_ continuation: CheckedContinuation<(host: String, port: Int)?, Never>) {
            lock.lock()
            if isFinished {
                let value = result
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ value: (host: String, port: Int)?) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            result = value
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }

    // MARK: Merging

    /// Collects resolved services, merges them by host, and answers the single waiter.
    private actor Merger {

        private struct Partial {
            var name: String
            var helmPort: Int?
            var pairingPort: Int?
            var isComplete: Bool { helmPort != nil && pairingPort != nil }
        }

        private let settle: TimeInterval
        private var byHost: [String: Partial] = [:]
        private var claimed: Set<String> = []
        private var resolvers: [Task<Void, Never>] = []
        private var settleTask: Task<Void, Never>?
        private var waiter: CheckedContinuation<FoundPlotter?, Never>?
        private var isFinished = false
        private var answer: FoundPlotter?

        init(settle: TimeInterval) {
            self.settle = settle
        }

        /// Wait for a merged result. Call once.
        func wait(timeout: TimeInterval) async -> FoundPlotter? {
            if isFinished { return answer }

            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                } catch {
                    return   // cancelled because we already have an answer
                }
                await self?.finish()
            }
            defer { timeoutTask.cancel() }

            return await withCheckedContinuation { (continuation: CheckedContinuation<FoundPlotter?, Never>) in
                if isFinished {
                    continuation.resume(returning: answer)
                } else {
                    waiter = continuation
                }
            }
        }

        /// Resolve a freshly browsed endpoint unless this service was already seen.
        func resolveIfNew(endpoint: NWEndpoint, name: String, kind: ServiceKind, queue: DispatchQueue) {
            guard !isFinished, claimed.insert("\(kind.rawValue)|\(name)").inserted else { return }

            let task = Task { [weak self] in
                guard let resolved = await BonjourFinder.resolve(endpoint, queue: queue) else { return }
                await self?.record(host: resolved.host, port: resolved.port, name: name, kind: kind)
            }
            resolvers.append(task)
        }

        private func record(host: String, port: Int, name: String, kind: ServiceKind) {
            guard !isFinished else { return }

            var partial = byHost[host] ?? Partial(name: name)
            if partial.name.isEmpty { partial.name = name }
            switch kind {
            case .helm:
                partial.helmPort = port > 0 ? port : BonjourFinder.defaultHelmPort
            case .pairing:
                partial.pairingPort = port > 0 ? port : BonjourFinder.defaultPairingPort
            }
            byHost[host] = partial

            if partial.isComplete {
                finish()   // both services on one host: nothing better is coming
            } else {
                startSettleTimer()
            }
        }

        private func startSettleTimer() {
            guard settleTask == nil else { return }
            settleTask = Task { [weak self, settle] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, settle) * 1_000_000_000))
                } catch {
                    return
                }
                await self?.finish()
            }
        }

        private func finish() {
            guard !isFinished else { return }
            isFinished = true
            answer = best()

            settleTask?.cancel()
            settleTask = nil
            for resolver in resolvers { resolver.cancel() }
            resolvers.removeAll()

            if let waiter {
                self.waiter = nil
                waiter.resume(returning: answer)
            }
        }

        private func best() -> FoundPlotter? {
            let ranked = byHost
                .map { (host: $0.key, partial: $0.value) }
                .sorted { a, b in
                    let scoreA = Merger.score(a.partial, host: a.host)
                    let scoreB = Merger.score(b.partial, host: b.host)
                    return scoreA == scoreB ? a.host < b.host : scoreA > scoreB
                }

            guard let winner = ranked.first else { return nil }
            return FoundPlotter(name: winner.partial.name,
                                host: winner.host,
                                helmPort: winner.partial.helmPort ?? BonjourFinder.defaultHelmPort,
                                pairingPort: winner.partial.pairingPort ?? BonjourFinder.defaultPairingPort)
        }

        /// Prefer a host that answered on the Helm port (that is the service we must
        /// actually talk to), then one that also answered on the pairing port, then a
        /// plain IPv4 literal over a bracketed IPv6 one.
        private static func score(_ partial: Partial, host: String) -> Int {
            var score = 0
            if partial.helmPort != nil { score += 4 }
            if partial.pairingPort != nil { score += 2 }
            if !host.hasPrefix("[") { score += 1 }
            return score
        }
    }
}
