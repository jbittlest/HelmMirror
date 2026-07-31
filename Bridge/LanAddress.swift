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

    /// This Mac's address on the local network, together with the interface's
    /// netmask so callers can describe the network correctly.
    struct Interface {
        let name: String
        let address: String
        /// Dotted netmask, e.g. "255.255.255.0" or Garmin's "255.240.0.0".
        let netmask: String?

        /// Prefix length in bits (24 for a normal home network, 12 for Garmin).
        var prefixLength: Int? {
            guard let netmask, let packed = LanAddress.packIPv4(netmask) else { return nil }
            return packed.nonzeroBitCount
        }

        /// Human description of which addresses share this network, e.g.
        /// "172.16.0.1 – 172.31.255.254" or "192.168.1.1 – 192.168.1.254".
        var networkRangeDescription: String? {
            guard let netmask,
                  let addr = LanAddress.packIPv4(address),
                  let mask = LanAddress.packIPv4(netmask),
                  mask != 0
            else { return nil }
            let network = addr & mask
            let broadcast = network | ~mask
            // Skip the all-zeros and all-ones addresses at the edges.
            return "\(LanAddress.unpackIPv4(network &+ 1)) – \(LanAddress.unpackIPv4(broadcast &- 1))"
        }

        /// The leading octets every address on this network shares, e.g. "192.168.1"
        /// for a /24 or "172.16" for Garmin's /12. Nil when the mask isn't octet-aligned.
        var sharedPrefix: String? {
            guard let bits = prefixLength else { return nil }
            let wholeOctets = bits / 8
            guard wholeOctets >= 1, wholeOctets <= 3, bits % 8 == 0 else { return nil }
            return address.split(separator: ".").prefix(wholeOctets).joined(separator: ".")
        }
    }

    /// The best non-loopback IPv4 interface of this machine, or `nil` if the Mac
    /// is not on any network.
    ///
    /// Preference order: `en0` (Wi-Fi on every current Mac), then `en1`, then any
    /// other Ethernet-style interface, then everything else.
    static func primaryInterface() -> Interface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: (rank: Int, interface: Interface)?

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

            let mask = interface.ifa_netmask.flatMap { numericHost($0) }

            let rank = rank(for: name)
            if rank < (best?.rank ?? Int.max) {
                best = (rank, Interface(name: name, address: address, netmask: mask))
            }
        }

        return best?.interface
    }

    /// Convenience: just the address, for callers that don't care about the mask.
    static func primaryIPv4() -> String? { primaryInterface()?.address }

    // MARK: IPv4 helpers

    static func packIPv4(_ dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            out = (out << 8) | UInt32(byte)
        }
        return out
    }

    static func unpackIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
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
