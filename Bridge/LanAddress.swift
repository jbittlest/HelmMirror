import Foundation

/// Finds the address of this Mac on the local network, so the phone can be told
/// which URL to open. On a Garmin plotter's Wi-Fi that is typically 172.16.6.x.
enum LanAddress {

    /// Interface-name prefixes that never carry an address the phone can reach:
    /// loopback, VPN tunnels, Apple Wireless Direct Link / low-latency WLAN
    /// (peer-to-peer AirDrop links), IPsec, dial-up and 6-to-4 pseudo-interfaces.
    private static let excludedPrefixes = [
        "lo", "utun", "awdl", "llw", "ipsec", "ppp", "gif", "stf", "anpi",
    ]

    /// The best non-loopback IPv4 address of this machine, or `nil` if the Mac
    /// is not on any network.
    ///
    /// Preference order: `en0` (Wi-Fi on every current Mac), then `en1`, then any
    /// other Ethernet-style interface, then everything else.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: (rank: Int, address: String)?

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee

            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            let flags = Int32(bitPattern: interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0
            else { continue }

            let name = String(cString: interface.ifa_name)
            guard !excludedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }

            guard let address = numericHost(socketAddress) else { continue }

            // 169.254.x.x is a self-assigned address handed out when DHCP failed;
            // nothing else on the network can be relied on to reach it.
            guard !address.hasPrefix("169.254.") else { continue }

            let rank = rank(for: name)
            if rank < (best?.rank ?? Int.max) {
                best = (rank, address)
            }
        }

        return best?.address
    }

    private static func rank(for interfaceName: String) -> Int {
        switch interfaceName {
        case "en0": return 0
        case "en1": return 1
        default: return interfaceName.hasPrefix("en") ? 2 : 3
        }
    }

    /// Formats a `sockaddr` as a numeric host string (e.g. "172.16.6.12").
    private static func numericHost(_ socketAddress: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            socketAddress,
            socklen_t(socketAddress.pointee.sa_len),
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { raw in
            raw.baseAddress.map { String(cString: $0) }
        }
    }
}
