import Foundation

/// Things that can go wrong while turning the plotter's video into something a
/// phone browser can play. Every message says what the person should DO next.
enum HLSPipelineError: Error, LocalizedError {

    /// ffmpeg or ffplay is not installed anywhere we look.
    case toolNotFound(String)

    /// `start()` was called while a previous ffmpeg is still alive.
    case alreadyRunning

    /// The pipeline was built without a usable RTSP address.
    case missingStreamURL

    /// The child process refused to launch.
    case launchFailed(tool: String, reason: String)

    /// The folder the HLS segments are written into is not usable.
    case outputUnavailable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return """
                Could not find \(tool) on this Mac.
                Install it by running this in Terminal:  brew install ffmpeg
                """
        case .alreadyRunning:
            return "The video is already running, so there is nothing to start."
        case .missingStreamURL:
            return """
                The chartplotter did not give us a video address.
                On the plotter go to Settings > Communications > Wi-Fi Network > Wi-Fi \
                Devices, choose this Mac, and turn on "View and Control". Then run \
                helmbridge again.
                """
        case .launchFailed(let tool, let reason):
            return """
                Could not start \(tool): \(reason)
                Check that it is installed (brew install ffmpeg) and try again.
                """
        case .outputUnavailable(let path, let reason):
            return """
                Could not use the video folder at \(path): \(reason)
                Free up some disk space, or move helmbridge somewhere you can write to, \
                and try again.
                """
        }
    }
}

/// Runs ffmpeg so the plotter's RTSP video comes out the other side as low-latency
/// HLS (a playlist plus a rolling handful of one-second segments) that any phone
/// browser can play with no app and no plug-ins.
///
/// One instance owns exactly one ffmpeg child process. Everything that touches
/// that child is isolated on this actor.
actor HLSPipeline {

    /// Where the pictures come from.
    private enum Source {
        /// Live H.264 from the chartplotter — remuxed, never re-encoded.
        case rtsp(String)
        /// A synthetic test pattern generated locally, so the phone side can be
        /// tried out with no boat, no plotter and no Wi-Fi.
        case demo
    }

    private let source: Source
    private let outputDir: URL
    private let playlistURL: URL
    private let logURL: URL

    private var process: Process?
    private var logHandle: FileHandle?
    private var monitorTask: Task<Void, Never>?

    /// Set by `stop()` so a deliberate shutdown is not reported as a crash.
    private var isStopping = false

    // MARK: - Creating

    init(rtspURL: String, outputDir: URL) {
        self.source = .rtsp(rtspURL)
        self.outputDir = outputDir
        self.playlistURL = outputDir.appendingPathComponent("stream.m3u8")
        self.logURL = outputDir.appendingPathComponent("ffmpeg.log")
    }

    private init(demoWritingTo outputDir: URL) {
        self.source = .demo
        self.outputDir = outputDir
        self.playlistURL = outputDir.appendingPathComponent("stream.m3u8")
        self.logURL = outputDir.appendingPathComponent("ffmpeg.log")
    }

    /// A pipeline that needs no chartplotter: ffmpeg generates a moving test
    /// pattern locally and publishes it as HLS exactly like the real stream.
    static func demo(outputDir: URL) -> HLSPipeline {
        HLSPipeline(demoWritingTo: outputDir)
    }

    // MARK: - Running

    /// `true` while the ffmpeg child is alive and writing segments.
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Launches ffmpeg. Returns as soon as the child is running; the first
    /// segments appear on disk a second or two later.
    func start() throws {
        guard !(process?.isRunning ?? false) else { throw HLSPipelineError.alreadyRunning }

        if case .rtsp(let url) = source,
           url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HLSPipelineError.missingStreamURL
        }

        isStopping = false
        try prepareOutputDirectory()

        guard let ffmpeg = Self.locate("ffmpeg") else {
            throw HLSPipelineError.toolNotFound("ffmpeg")
        }

        let handle = try openLog()
        let child = Process()
        child.executableURL = ffmpeg
        child.arguments = ffmpegArguments()
        // ffmpeg is told -nostdin as well; detaching the handles means it can
        // never grab the terminal helmbridge is printing to.
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = handle

        do {
            try child.run()
        } catch {
            try? handle.close()
            throw HLSPipelineError.launchFailed(
                tool: "ffmpeg",
                reason: (error as NSError).localizedDescription
            )
        }

        process = child
        logHandle = handle
        startMonitoring()
    }

    /// Stops ffmpeg and tidies up. Safe to call when nothing is running.
    func stop() {
        isStopping = true
        monitorTask?.cancel()
        monitorTask = nil

        if let child = process {
            if child.isRunning {
                // SIGTERM lets ffmpeg close the current segment cleanly.
                child.terminate()
                let deadline = Date().addingTimeInterval(2.0)
                while child.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                }
            }
            process = nil
        }

        closeLog()
    }

    // MARK: - The ffmpeg command lines

    private func ffmpegArguments() -> [String] {
        // ffmpeg expands the segment counter itself, so argv carries a single
        // "%05d" — seg00000.ts, seg00001.ts, ... which is what the web server
        // serves as /seg*.ts.
        let segmentPattern = outputDir.appendingPathComponent("seg%05d.ts").path

        // Short segments and a short window are what keep the phone within about
        // two seconds of the plotter; omit_endlist keeps the playlist "live" and
        // delete_segments stops the folder growing for ever.
        let hlsOutput = [
            "-f", "hls",
            "-hls_time", "1",
            "-hls_list_size", "4",
            "-hls_flags", "delete_segments+append_list+omit_endlist+independent_segments",
            "-hls_segment_filename", segmentPattern,
            playlistURL.path,
        ]

        switch source {
        case .rtsp(let url):
            return [
                "-nostdin",
                "-loglevel", "warning",
                // Hand frames on the moment they arrive instead of filling a buffer.
                "-fflags", "nobuffer",
                "-flags", "low_delay",
                // The plotter answers 461 to interleaved RTP, so RTP must go over UDP.
                "-rtsp_transport", "udp",
                "-i", url,
                // The plotter already sends H.264: copy the bitstream, never re-encode.
                "-c:v", "copy",
                "-an",
            ] + hlsOutput

        case .demo:
            return [
                "-nostdin",
                "-loglevel", "warning",
                // Without -re, lavfi generates frames as fast as the CPU allows
                // (measured at ~65x realtime), so the live playlist races away
                // from the phone and segments are deleted before it fetches them.
                "-re",
                // testsrc draws a moving bar and a running timestamp, so it is
                // obvious at a glance whether the phone is seeing live frames.
                "-f", "lavfi",
                "-i", "testsrc=size=1280x720:rate=15",
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-tune", "zerolatency",
                "-pix_fmt", "yuv420p",
                // One keyframe per second, matching -hls_time, so every segment
                // can be started independently.
                "-g", "15",
                "-an",
            ] + hlsOutput
        }
    }

    // MARK: - Watching the child

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self else { return }
                if await self.reapIfExited() { return }
            }
        }
    }

    /// Returns `true` once the child is gone and has been cleaned up.
    private func reapIfExited() async -> Bool {
        guard let child = process else { return true }
        guard !child.isRunning else { return false }

        let status = child.terminationStatus
        process = nil
        closeLog()

        if !isStopping && status != 0 {
            reportUnexpectedExit(status: status)
        }
        return true
    }

    private func reportUnexpectedExit(status: Int32) {
        var message = "\nThe video stopped: ffmpeg quit unexpectedly (code \(status)).\n"

        let lastLines = Self.tail(of: logURL, lines: 10)
        if !lastLines.isEmpty {
            message += "Last messages from ffmpeg:\n"
            for line in lastLines {
                message += "   \(line)\n"
            }
        }

        switch source {
        case .rtsp:
            message += """
                What to try: check the plotter is still switched on and this Mac is still \
                joined to its Wi-Fi network, then start helmbridge again.

                """
        case .demo:
            message += """
                What to try: start helmbridge again. If it keeps happening, reinstall \
                ffmpeg with:  brew reinstall ffmpeg

                """
        }

        FileHandle.standardError.write(Data(message.utf8))
    }

    // MARK: - Files

    private func prepareOutputDirectory() throws {
        let files = FileManager.default
        do {
            try files.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            throw HLSPipelineError.outputUnavailable(
                path: outputDir.path,
                reason: (error as NSError).localizedDescription
            )
        }

        // Segments left over from a previous run would be handed to the phone
        // before the new ones appear, showing stale pictures.
        let existing = (try? files.contentsOfDirectory(atPath: outputDir.path)) ?? []
        for name in existing
        where name == "stream.m3u8" || (name.hasPrefix("seg") && name.hasSuffix(".ts")) {
            try? files.removeItem(at: outputDir.appendingPathComponent(name))
        }
    }

    /// Opens (and truncates) the file ffmpeg's diagnostics are written to.
    private func openLog() throws -> FileHandle {
        let files = FileManager.default
        guard files.createFile(atPath: logURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: logURL)
        else {
            throw HLSPipelineError.outputUnavailable(
                path: logURL.path,
                reason: "the ffmpeg log file could not be written"
            )
        }
        return handle
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private static func tail(of url: URL, lines: Int) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let cleaned = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return Array(cleaned.suffix(lines))
    }

    // MARK: - Playing on this Mac instead of a phone

    /// Keeps the ffplay child alive for the lifetime of helmbridge. Written once,
    /// from `play(rtspURL:)`, which the command line calls a single time.
    private nonisolated(unsafe) static var player: Process?

    /// Opens the plotter's stream in an ffplay window on this Mac — the `--play`
    /// fallback, used to prove the video works before involving a phone.
    static func play(rtspURL: String) throws {
        guard !rtspURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HLSPipelineError.missingStreamURL
        }
        guard let ffplay = locate("ffplay") else {
            throw HLSPipelineError.toolNotFound("ffplay")
        }

        let child = Process()
        child.executableURL = ffplay
        child.arguments = [
            "-loglevel", "warning",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            // Drop late frames rather than drifting further and further behind.
            "-framedrop",
            "-rtsp_transport", "udp",
            "-window_title", "HelmMirror",
            "-i", rtspURL,
        ]
        child.standardInput = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw HLSPipelineError.launchFailed(
                tool: "ffplay",
                reason: (error as NSError).localizedDescription
            )
        }

        player = child
    }

    // MARK: - Finding the tools

    /// Homebrew on Apple silicon, then Homebrew on Intel.
    private static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Full path to `ffmpeg`/`ffplay`, or `nil` if this Mac has neither.
    private static func locate(_ tool: String) -> URL? {
        let files = FileManager.default

        for directory in toolDirectories {
            let candidate = "\(directory)/\(tool)"
            if files.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                let candidate = "\(directory)/\(tool)"
                if files.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        return resolveViaEnv(tool)
    }

    /// Last resort: let `/usr/bin/env` search the PATH a login shell would use,
    /// which catches installs this process did not inherit a PATH entry for.
    private static func resolveViaEnv(_ tool: String) -> URL? {
        // The names are compiled in, but keep the shell word trivially safe anyway.
        guard tool.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/env")
        else { return nil }

        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        lookup.arguments = ["sh", "-c", "command -v \(tool)"]
        let output = Pipe()
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        lookup.standardInput = FileHandle.nullDevice

        guard (try? lookup.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()

        guard lookup.terminationStatus == 0,
              let found = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !found.isEmpty,
              FileManager.default.isExecutableFile(atPath: found)
        else { return nil }

        return URL(fileURLWithPath: found)
    }
}
