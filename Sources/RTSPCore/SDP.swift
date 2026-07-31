//
//  SDP.swift
//  HelmMirror
//
//  FOUNDATION ONLY. No Network, no CoreMedia, no AVFoundation, no UIKit, no
//  VideoToolbox, no MirrorDiagnostics. Pure value types and pure functions:
//  this file returns results, callers log them. It must compile unchanged into
//  the Foundation-only SwiftPM `HelmProtocol` target so `swift run helmverify`
//  keeps working on a Mac with only the Command Line Tools.
//
//  Responsibility (frozen spec §4.2):
//    * parse an SDP session/media description (RFC 4566 subset)
//    * find the H.264 video track, its payload type, clock rate and fmtp params
//    * decode `sprop-parameter-sets` base64 into raw SPS/PPS NAL bytes
//    * resolve `a=control` against the aggregate base URL (RFC 2326 §C.1.1)
//

import Foundation

// MARK: - Session description

/// One `a=` line. `value` is "" for a valueless attribute such as `a=recvonly`.
public struct SDPAttribute: Equatable {
    public let name: String     // "rtpmap", "fmtp", "control", ...
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One `m=` section plus every media-level line that follows it.
public struct SDPMediaDescription: Equatable {
    public let mediaType: String            // "video", "audio", ...
    public let port: Int
    public let proto: String                // "RTP/AVP"
    public let formats: [Int]               // payload types from the m= line
    public let attributes: [SDPAttribute]   // media-level a= lines, in order

    public init(mediaType: String,
                port: Int,
                proto: String,
                formats: [Int],
                attributes: [SDPAttribute]) {
        self.mediaType = mediaType
        self.port = port
        self.proto = proto
        self.formats = formats
        self.attributes = attributes
    }

    /// The `a=control:` value for this track, if any.
    public var control: String? {
        attribute(named: "control")
    }

    /// `a=rtpmap:96 H264/90000` -> "H264/90000" for payload type 96.
    public func rtpmap(for payloadType: Int) -> String? {
        payloadScopedAttribute(named: "rtpmap", payloadType: payloadType)
    }

    /// `a=fmtp:96 packetization-mode=1;...` -> "packetization-mode=1;..." for 96.
    public func fmtp(for payloadType: Int) -> String? {
        payloadScopedAttribute(named: "fmtp", payloadType: payloadType)
    }

    /// First attribute with this name (case-insensitive).
    private func attribute(named name: String) -> String? {
        for attr in attributes where attr.name.caseInsensitiveCompare(name) == .orderedSame {
            return attr.value
        }
        return nil
    }

    /// True when this section carries at least one `a=rtpmap:` line.
    fileprivate var hasAnyRTPMap: Bool {
        attributes.contains { $0.name.caseInsensitiveCompare("rtpmap") == .orderedSame }
    }

    /// `rtpmap`/`fmtp` values are "<pt> <rest>"; match `<pt>` and return `<rest>`.
    private func payloadScopedAttribute(named name: String, payloadType: Int) -> String? {
        for attr in attributes where attr.name.caseInsensitiveCompare(name) == .orderedSame {
            guard let (pt, rest) = SDPScan.leadingInt(attr.value), pt == payloadType else { continue }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// A whole SDP body. Session-level attributes plus the ordered media sections.
public struct SessionDescription: Equatable {
    public let sessionAttributes: [SDPAttribute]
    public let media: [SDPMediaDescription]

    public init(sessionAttributes: [SDPAttribute], media: [SDPMediaDescription]) {
        self.sessionAttributes = sessionAttributes
        self.media = media
    }

    /// Session-level `a=control:` — commonly "*" (meaning "the request URI").
    public var sessionControl: String? {
        for attr in sessionAttributes where attr.name.caseInsensitiveCompare("control") == .orderedSame {
            return attr.value
        }
        return nil
    }

    /// Never throws. Unknown or malformed lines are skipped.
    public static func parse(_ text: String) -> SessionDescription {
        var sessionAttributes: [SDPAttribute] = []
        var media: [SDPMediaDescription] = []

        // Pending media section under construction; flushed by the next m= or EOF.
        var openMedia: (type: String, port: Int, proto: String, formats: [Int])?
        var openAttributes: [SDPAttribute] = []

        func flushMedia() {
            guard let m = openMedia else { return }
            media.append(SDPMediaDescription(mediaType: m.type,
                                             port: m.port,
                                             proto: m.proto,
                                             formats: m.formats,
                                             attributes: openAttributes))
            openMedia = nil
            openAttributes = []
        }

        // Lines are separated by CRLF or bare LF; empty lines carry no meaning.
        // NOTE: "\r\n" is a SINGLE Swift Character (one grapheme cluster), so it must
        // be matched explicitly — testing only for "\r" and "\n" never splits real,
        // CRLF-terminated SDP and yields zero media sections.
        for rawLine in text.split(whereSeparator: { $0 == "\r\n" || $0 == "\r" || $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Every SDP line is "<single-char key>=<value>".
            guard line.count >= 2 else { continue }
            let key = line[line.startIndex]
            guard line[line.index(after: line.startIndex)] == "=" else { continue }
            let value = String(line[line.index(line.startIndex, offsetBy: 2)...])

            switch key {
            case "m":
                flushMedia()
                openMedia = parseMediaLine(value)
            case "a":
                let attr = parseAttributeLine(value)
                if openMedia != nil {
                    openAttributes.append(attr)
                } else {
                    sessionAttributes.append(attr)
                }
            default:
                // b=, c=, i=, k=, v=, o=, s=, t=, ... are section-scoped but
                // carry nothing this player needs. Skipped deliberately.
                continue
            }
        }
        flushMedia()

        return SessionDescription(sessionAttributes: sessionAttributes, media: media)
    }

    /// UTF-8, lossy: an SDP body with a stray non-UTF-8 byte still parses.
    public static func parse(_ data: Data) -> SessionDescription {
        parse(String(decoding: data, as: UTF8.self))
    }

    /// "video 0 RTP/AVP 96 97" -> ("video", 0, "RTP/AVP", [96, 97]).
    private static func parseMediaLine(_ value: String) -> (type: String, port: Int, proto: String, formats: [Int])? {
        let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 3 else { return nil }
        // The port field may be "<port>/<count>" (RFC 4566); only the port matters.
        let portToken = tokens[1].split(separator: "/", maxSplits: 1).first.map(String.init) ?? tokens[1]
        let port = Int(portToken) ?? 0
        let formats = tokens.dropFirst(3).compactMap { Int($0) }
        return (tokens[0], port, tokens[2], formats)
    }

    /// "rtpmap:96 H264/90000" -> ("rtpmap", "96 H264/90000"); "recvonly" -> ("recvonly", "").
    private static func parseAttributeLine(_ value: String) -> SDPAttribute {
        guard let colon = value.firstIndex(of: ":") else {
            return SDPAttribute(name: value.trimmingCharacters(in: .whitespaces), value: "")
        }
        let name = String(value[value.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return SDPAttribute(name: name, value: rest)
    }
}

// MARK: - H.264 track

/// Everything the RTP/H.264 pipeline needs, extracted from one `m=video` section.
public struct H264TrackDescription: Equatable {
    public let mediaIndex: Int
    public let payloadType: UInt8
    public let clockRate: Int           // from rtpmap; 90000 when absent
    public let packetizationMode: Int   // from fmtp; 0 when absent (RFC 6184 default)
    public let profileLevelId: String?  // "42E01E"
    public let sps: [Data]              // raw NAL bytes, no start code, no length prefix
    public let pps: [Data]
    public let control: String?         // the a=control value verbatim

    public init(mediaIndex: Int,
                payloadType: UInt8,
                clockRate: Int,
                packetizationMode: Int,
                profileLevelId: String?,
                sps: [Data],
                pps: [Data],
                control: String?) {
        self.mediaIndex = mediaIndex
        self.payloadType = payloadType
        self.clockRate = clockRate
        self.packetizationMode = packetizationMode
        self.profileLevelId = profileLevelId
        self.sps = sps
        self.pps = pps
        self.control = control
    }
}

public enum SDPH264 {

    /// First `m=video` section whose rtpmap encoding name is "H264"
    /// (case-insensitive). If that section declares no rtpmap at all, fall back to
    /// the first `m=video` whose first format is the de-facto dynamic type 96.
    public static func h264Track(in sdp: SessionDescription) -> H264TrackDescription? {
        // Pass 1: an explicit rtpmap naming H264.
        for (index, media) in sdp.media.enumerated() where media.mediaType.caseInsensitiveCompare("video") == .orderedSame {
            for pt in media.formats {
                guard let map = media.rtpmap(for: pt),
                      encodingName(of: map).caseInsensitiveCompare("H264") == .orderedSame else { continue }
                return track(media: media, mediaIndex: index, payloadType: pt, rtpmap: map)
            }
        }
        // Pass 2: no rtpmap in the section at all — accept payload type 96.
        for (index, media) in sdp.media.enumerated() where media.mediaType.caseInsensitiveCompare("video") == .orderedSame {
            guard !media.hasAnyRTPMap, media.formats.first == 96 else { continue }
            return track(media: media, mediaIndex: index, payloadType: 96, rtpmap: nil)
        }
        return nil
    }

    private static func track(media: SDPMediaDescription,
                              mediaIndex: Int,
                              payloadType: Int,
                              rtpmap: String?) -> H264TrackDescription? {
        // The wire payload type is 7 bits.
        guard payloadType >= 0, payloadType <= 127 else { return nil }

        let fmtp = media.fmtp(for: payloadType) ?? ""
        let sprop = fmtpValue("sprop-parameter-sets", in: fmtp) ?? ""
        let sets = parseSpropParameterSets(sprop)

        return H264TrackDescription(
            mediaIndex: mediaIndex,
            payloadType: UInt8(payloadType),
            clockRate: rtpmap.flatMap(clockRate(of:)) ?? 90000,
            packetizationMode: fmtpValue("packetization-mode", in: fmtp).flatMap { Int($0) } ?? 0,
            profileLevelId: fmtpValue("profile-level-id", in: fmtp),
            sps: sets.sps,
            pps: sets.pps,
            control: media.control
        )
    }

    /// "H264/90000" -> "H264"; "H264/90000/1" -> "H264".
    private static func encodingName(of rtpmap: String) -> String {
        String(rtpmap.split(separator: "/", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "H264/90000" -> 90000. nil when the field is missing or not a number.
    private static func clockRate(of rtpmap: String) -> Int? {
        let parts = rtpmap.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// "Z0Lg...==,aM48gA==" -> SPS list and PPS list, split by NAL type (7 / 8).
    /// Base64 that fails to decode is skipped. Unknown NAL types are dropped.
    public static func parseSpropParameterSets(_ value: String) -> (sps: [Data], pps: [Data]) {
        var sps: [Data] = []
        var pps: [Data] = []
        for piece in value.split(separator: ",", omittingEmptySubsequences: true) {
            guard let nal = decodeParameterSet(String(piece)), let header = nal.first else { continue }
            switch header & 0x1F {          // low 5 bits of the NAL header byte
            case 7: sps.append(nal)
            case 8: pps.append(nal)
            default: break
            }
        }
        return (sps, pps)
    }

    /// One parameter out of "packetization-mode=1;profile-level-id=42E01E;sprop-...=..".
    /// Name match is case-insensitive. Separator is ';'. Value is trimmed; surrounding
    /// double quotes are stripped. Returns nil when absent.
    public static func fmtpValue(_ name: String, in fmtp: String) -> String? {
        for piece in fmtp.split(separator: ";", omittingEmptySubsequences: true) {
            let part = piece.trimmingCharacters(in: .whitespaces)
            // Split at the FIRST '=' only: base64 values carry '=' padding.
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            var value = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    /// Decode one base64 parameter set. Tolerates missing `=` padding and the
    /// URL-safe alphabet, both of which appear in real `sprop-parameter-sets`.
    private static func decodeParameterSet(_ raw: String) -> Data? {
        var normalized = ""
        normalized.reserveCapacity(raw.count + 2)
        for ch in raw {
            switch ch {
            case "-": normalized.append("+")        // URL-safe alphabet
            case "_": normalized.append("/")
            case " ", "\t", "\r", "\n": continue    // some servers wrap long lists
            default: normalized.append(ch)
            }
        }
        while normalized.hasSuffix("=") { normalized.removeLast() }
        guard !normalized.isEmpty else { return nil }

        let remainder = normalized.count % 4
        if remainder == 1 { return nil }            // never a valid base64 length
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }

        if let data = Data(base64Encoded: normalized), !data.isEmpty { return data }
        if let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]),
           !data.isEmpty { return data }
        return nil
    }
}

// MARK: - Control URL resolution

public enum RTSPURL {

    /// RFC 2326 aggregate-control resolution.
    ///   control nil / "" / "*"        -> base unchanged
    ///   control starts "rtsp://" or "rtsps://" (case-insensitive) -> control
    ///   control starts "/"            -> base's scheme + authority + control
    ///   otherwise                     -> base + ("/" unless base already ends with "/")
    ///                                    + control
    public static func resolve(control: String?, base: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = control else { return base }
        let control = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if control.isEmpty || control == "*" { return base }

        if hasRTSPScheme(control) { return control }

        if control.hasPrefix("/") { return schemeAndAuthority(of: base) + control }

        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    /// The base URL for control resolution: Content-Base, else Content-Location,
    /// else the URI the request was sent to. Whitespace-trimmed.
    public static func effectiveBase(requestURI: String, response: RTSPResponse) -> String {
        for name in ["content-base", "content-location"] {
            guard let value = response.header(name)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            return value
        }
        return requestURI.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasRTSPScheme(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("rtsp://") || lower.hasPrefix("rtsps://")
    }

    /// "rtsp://h:554/s.h264/track1" -> "rtsp://h:554". Returns `base` unchanged
    /// when there is no "://" or no path component to strip.
    private static func schemeAndAuthority(of base: String) -> String {
        guard let separator = base.range(of: "://") else { return base }
        guard let slash = base.range(of: "/", range: separator.upperBound..<base.endIndex) else {
            return base
        }
        return String(base[base.startIndex..<slash.lowerBound])
    }
}

// MARK: - Scanning helpers

private enum SDPScan {
    /// "96 H264/90000" -> (96, " H264/90000"). nil when there is no leading integer.
    static func leadingInt(_ s: String) -> (value: Int, rest: String)? {
        var digits = ""
        var index = s.startIndex
        while index < s.endIndex, s[index].isASCII, s[index].isNumber {
            digits.append(s[index])
            index = s.index(after: index)
        }
        guard let value = Int(digits) else { return nil }
        return (value, String(s[index...]))
    }
}
