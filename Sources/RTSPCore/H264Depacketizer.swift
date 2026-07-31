//
//  H264Depacketizer.swift
//  HelmMirror
//
//  RFC 6184 — RTP payload format for H.264 video.
//
//  FOUNDATION ONLY. No Network, no CoreMedia, no VideoToolbox, no AVFoundation,
//  no UIKit, and no logging: this file is pure value types and pure functions so
//  every byte of it can be pinned by `swift run helmverify` on a Mac that has
//  only the Command Line Tools. Callers log; this file returns events.
//
//  Responsibility: turn a stream of in-order RTP payloads into complete access
//  units in AVCC form (each NAL prefixed by its 4-byte big-endian length), and
//  latch the SPS/PPS parameter sets that arrive in band.
//

import Foundation

// MARK: - NAL helpers

/// Byte-level helpers for raw H.264 NAL units (no start code, no length prefix).
public enum H264NAL {
    public static let startCode4: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// NAL unit type: the low 5 bits of the header byte. 0 for an empty NAL.
    public static func type(of nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1F
    }

    /// SPS (7) or PPS (8).
    public static func isParameterSet(_ nal: Data) -> Bool {
        let t = type(of: nal)
        return t == 7 || t == 8
    }

    /// Coded slice of an IDR picture (5) — a keyframe.
    public static func isIDR(_ nal: Data) -> Bool {
        type(of: nal) == 5
    }

    /// AVCC / "avc1" sample form: each NAL prefixed by its 4-byte BIG-ENDIAN
    /// length, concatenated. This is what CMBlockBuffer wants when the format
    /// description was built with `nalUnitHeaderLength: 4`.
    public static func avccPrefixed(_ nals: [Data]) -> Data {
        var total = 0
        for nal in nals where !nal.isEmpty { total += 4 + nal.count }

        var out = Data()
        out.reserveCapacity(total)
        for nal in nals where !nal.isEmpty {
            let length = UInt32(nal.count)
            out.append(UInt8(truncatingIfNeeded: length >> 24))
            out.append(UInt8(truncatingIfNeeded: length >> 16))
            out.append(UInt8(truncatingIfNeeded: length >> 8))
            out.append(UInt8(truncatingIfNeeded: length))
            out.append(nal)
        }
        return out
    }

    /// Split an Annex-B buffer on 3- or 4-byte start codes. Empty NALs are dropped.
    ///
    /// A 4-byte start code is just a 3-byte one with an extra leading zero, so the
    /// scan matches `00 00 01` and then reaches one byte back: that trailing zero
    /// belongs to the start code, not to the NAL that precedes it.
    public static func annexBToNALs(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let count = bytes.count
        var nals: [Data] = []
        var nalStart = -1
        var i = 0

        while i + 2 < count {
            if bytes[i] == 0x00, bytes[i + 1] == 0x00, bytes[i + 2] == 0x01 {
                let codeStart = (i > 0 && bytes[i - 1] == 0x00) ? i - 1 : i
                if nalStart >= 0, codeStart > nalStart {
                    nals.append(Data(bytes[nalStart..<codeStart]))
                }
                i += 3
                nalStart = i
                continue
            }
            i += 1
        }

        if nalStart >= 0, nalStart < count {
            nals.append(Data(bytes[nalStart..<count]))
        }
        return nals
    }
}

// MARK: - RTP payload classification (RFC 6184 §5.4)

public enum H264RTPPayload {

    /// A fragmentation unit, FU-A (payload type 28).
    ///
    /// Wire layout: `[FU indicator][FU header][fragment...]`
    ///   FU indicator: `F(1) NRI(2) Type(5)` where Type == 28
    ///   FU header:    `S(1) E(1) R(1) Type(5)` where Type is the ORIGINAL NAL type
    public struct FUA: Equatable, Sendable {
        public let start: Bool
        public let end: Bool
        public let nalType: UInt8       // the ORIGINAL NAL type, 1..23
        public let nri: UInt8           // 0..3, taken from the FU indicator
        public let fragment: Data

        /// The NAL header byte to prepend when reassembling: (nri << 5) | nalType
        public var reconstructedHeader: UInt8 { (nri << 5) | nalType }

        public init(start: Bool, end: Bool, nalType: UInt8, nri: UInt8, fragment: Data) {
            self.start = start
            self.end = end
            self.nalType = nalType
            self.nri = nri
            self.fragment = fragment
        }
    }

    public enum Kind: Equatable, Sendable {
        case single(Data)          // types 1...23: the whole payload IS the NAL
        case stapA([Data])         // type 24
        case fuA(FUA)              // type 28
        case unsupported(UInt8)    // 0, 25, 26, 27, 29, 30, 31
    }

    /// nil when the payload is empty or structurally truncated.
    public static func classify(_ payload: Data) -> Kind? {
        guard let indicator = payload.first else { return nil }
        let type = indicator & 0x1F

        switch type {
        case 1...23:
            return .single(Data(payload))

        case 24:
            guard let nals = splitSTAPA(payload) else { return nil }
            return .stapA(nals)

        case 28:
            guard payload.count >= 2 else { return nil }
            let fuHeader = payload[payload.index(payload.startIndex, offsetBy: 1)]
            return .fuA(FUA(start: fuHeader & 0x80 != 0,
                            end: fuHeader & 0x40 != 0,
                            nalType: fuHeader & 0x1F,
                            nri: (indicator >> 5) & 0x03,
                            fragment: Data(payload.dropFirst(2))))

        default:
            return .unsupported(type)
        }
    }

    /// STAP-A (type 24). The argument is the FULL payload; the body after the
    /// 1-byte STAP-A header is repeated `[u16 BE size][size bytes]`.
    /// nil when any record is truncated or a size is 0.
    public static func splitSTAPA(_ payload: Data) -> [Data]? {
        let bytes = [UInt8](payload)
        guard !bytes.isEmpty else { return nil }

        var nals: [Data] = []
        var i = 1
        while i < bytes.count {
            guard i + 2 <= bytes.count else { return nil }
            let size = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            i += 2
            guard size > 0, i + size <= bytes.count else { return nil }
            nals.append(Data(bytes[i..<(i + size)]))
            i += size
        }
        return nals
    }
}

// MARK: - Depacketizer output types

public struct H264ParameterSets: Equatable, Sendable {
    public var sps: [Data]
    public var pps: [Data]

    public var isComplete: Bool { !sps.isEmpty && !pps.isEmpty }

    public init(sps: [Data] = [], pps: [Data] = []) {
        self.sps = sps
        self.pps = pps
    }
}

public struct H264AccessUnit: Equatable, Sendable {
    /// Length-prefixed (AVCC, 4-byte BE) VCL/SEI NALs. Parameter sets are NOT included.
    public let avcc: Data
    public let rtpTimestamp: UInt32
    public let isKeyframe: Bool     // contains a type-5 IDR NAL
    public let isCorrupt: Bool      // packet loss was detected while assembling it

    public init(avcc: Data, rtpTimestamp: UInt32, isKeyframe: Bool, isCorrupt: Bool) {
        self.avcc = avcc
        self.rtpTimestamp = rtpTimestamp
        self.isKeyframe = isKeyframe
        self.isCorrupt = isCorrupt
    }
}

// MARK: - Depacketizer

/// Feed it one in-order RTP packet at a time; it hands back complete access units.
///
/// AU boundaries are detected two ways — a timestamp change and the RTP marker
/// bit — and whichever fires first wins. The plotter is expected to set the
/// marker bit, which is the low-latency path (no need to wait for the next
/// picture's first packet before displaying this one).
public struct H264Depacketizer {

    public enum Event: Equatable, Sendable {
        case accessUnit(H264AccessUnit)
        /// Emitted whenever the stored SPS/PPS set changes (from in-band 7/8 NALs).
        case parameterSets(H264ParameterSets)
        case dropped(reason: String)
    }

    public private(set) var parameterSets: H264ParameterSets

    /// The access unit currently being assembled. nil until a VCL/SEI NAL arrives.
    private struct OpenAccessUnit {
        var timestamp: UInt32
        var nals: [Data] = []
        var isKeyframe = false
        var isCorrupt = false
    }

    private var open: OpenAccessUnit?
    /// In-progress FU-A reassembly buffer, already carrying its reconstructed
    /// NAL header byte. nil when no fragmented NAL is open.
    private var fragment: Data?
    /// Loss was reported while no access unit was open, so the gap lands on the
    /// head of the NEXT picture rather than the tail of the last one. Carry the
    /// corruption forward instead of dropping the signal: an access unit missing
    /// its leading slices decodes to a green smear, and `isCorrupt` is what tells
    /// the session's keyframe gate to throw it away.
    private var pendingCorrupt = false

    public init(initial: H264ParameterSets = H264ParameterSets()) {
        self.parameterSets = initial
    }

    /// Feed ONE in-order packet. `lostBefore` is `RTPReorderBuffer.Output.lost`.
    public mutating func push(_ packet: RTPPacket, lostBefore: Int = 0) -> [Event] {
        var events: [Event] = []

        // 1. Loss poisons whatever is currently being assembled: a partial NAL is
        //    unrecoverable, and the open AU is missing slices.
        if lostBefore > 0 {
            fragment = nil
            if open != nil { open?.isCorrupt = true } else { pendingCorrupt = true }
            events.append(.dropped(reason: "lost \(lostBefore) RTP packets"))
        }

        // 2. A timestamp change ends the previous picture.
        if let open, open.timestamp != packet.timestamp {
            closeAccessUnit(into: &events)
        }

        // 3. Depacketize. A single .parameterSets event is emitted per push (step
        //    4 may change SPS and PPS in one STAP-A), so snapshot the old value.
        let setsBefore = parameterSets

        switch H264RTPPayload.classify(packet.payload) {
        case .none:
            events.append(.dropped(reason: "malformed RTP payload"))

        case .single(let nal):
            append(nal, timestamp: packet.timestamp, into: &events)

        case .stapA(let nals):
            for nal in nals {
                append(nal, timestamp: packet.timestamp, into: &events)
            }

        case .fuA(let fu):
            if fu.start {
                if fragment != nil {
                    events.append(.dropped(reason: "FU-A restart"))
                }
                var buffer = Data()
                buffer.reserveCapacity(fu.fragment.count + 1)
                buffer.append(fu.reconstructedHeader)
                buffer.append(fu.fragment)
                fragment = buffer
            } else if fragment == nil {
                events.append(.dropped(reason: "FU-A without start"))
            } else {
                fragment?.append(fu.fragment)
            }

            if fu.end, let completed = fragment {
                append(completed, timestamp: packet.timestamp, into: &events)
                fragment = nil
            }

        case .unsupported(let type):
            events.append(.dropped(reason: "unsupported NAL \(type)"))
        }

        if parameterSets != setsBefore {
            events.append(.parameterSets(parameterSets))
        }

        // 5. The marker bit ends the picture — the low-latency boundary.
        if packet.hasMarker, let open, !open.nals.isEmpty {
            closeAccessUnit(into: &events)
        }

        return events
    }

    /// Emit any pending access unit. Call on stop.
    public mutating func flush() -> [Event] {
        var events: [Event] = []
        fragment = nil
        closeAccessUnit(into: &events)
        return events
    }

    /// Drop the pending AU and FU-A state. Keeps `parameterSets`.
    public mutating func reset() {
        open = nil
        fragment = nil
        pendingCorrupt = false
    }

    // MARK: Private

    /// Route one complete NAL: parameter sets are latched, AUD/filler discarded,
    /// everything else accumulates into the open access unit.
    private mutating func append(_ nal: Data, timestamp: UInt32, into events: inout [Event]) {
        switch H264NAL.type(of: nal) {
        case 7:
            // Parameter sets live in the format description, never in the AU.
            if parameterSets.sps.first != nal { parameterSets.sps = [nal] }

        case 8:
            if parameterSets.pps.first != nal { parameterSets.pps = [nal] }

        case 9, 12:
            break   // access unit delimiter / filler data — nothing to decode

        case let type:
            if open == nil {
                open = OpenAccessUnit(timestamp: timestamp, isCorrupt: pendingCorrupt)
                pendingCorrupt = false
            }
            open?.nals.append(nal)
            if type == 5 { open?.isKeyframe = true }
        }
    }

    /// Close the open AU and append it to `events`. An AU with zero NALs is
    /// never emitted.
    private mutating func closeAccessUnit(into events: inout [Event]) {
        guard let unit = open else { return }
        open = nil
        guard !unit.nals.isEmpty else { return }

        events.append(.accessUnit(H264AccessUnit(avcc: H264NAL.avccPrefixed(unit.nals),
                                                 rtpTimestamp: unit.timestamp,
                                                 isKeyframe: unit.isKeyframe,
                                                 isCorrupt: unit.isCorrupt)))
    }
}
