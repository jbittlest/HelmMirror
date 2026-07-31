//
//  main.swift
//  helmbridge
//
//  Command-line bridge: finds a Garmin chartplotter on the Wi-Fi, opens the Helm
//  session, has ffmpeg remux the plotter's RTSP video into low-latency HLS, and
//  serves a small web page to the user's phone. Touches on the phone are sent
//  back to the plotter.
//
//  Everything printed here is read by people who are standing on a boat, so it
//  is plain English and always says what to DO next.
//

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Command line options

struct Options: Sendable {
    var demo = false
    var play = false
    var port: UInt16 = 8080
    var host: String?
}

enum OptionsError: Error {
    case usage(String)
    case helpRequested
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let argument = arguments[index]
        var flag = argument
        var inlineValue: String?

        // Accept both "--port 8080" and "--port=8080".
        if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
            flag = String(argument[argument.startIndex..<equals])
            inlineValue = String(argument[argument.index(after: equals)...])
        }

        func nextValue(for name: String, example: String) throws -> String {
            if let inlineValue { return inlineValue }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                throw OptionsError.usage("\(name) needs a value, for example: \(name) \(example)")
            }
            index = next
            return arguments[next]
        }

        switch flag {
        case "--demo":
            options.demo = true
        case "--play":
            options.play = true
        case "--port":
            let text = try nextValue(for: "--port", example: "8080")
            guard let number = UInt16(text), number >= 1024 else {
                throw OptionsError.usage(
                    "--port needs a whole number between 1024 and 65535. You typed \"\(text)\".")
            }
            options.port = number
        case "--host":
            let text = try nextValue(for: "--host", example: "172.16.6.0")
            guard !text.isEmpty else {
                throw OptionsError.usage("--host needs the plotter's address, for example: --host 172.16.6.0")
            }
            options.host = text
        case "--help", "-h":
            throw OptionsError.helpRequested
        default:
            throw OptionsError.usage(
                "I do not understand \"\(argument)\". Run  helmbridge --help  to see the options.")
        }

        index = arguments.index(after: index)
    }

    if options.demo && options.play {
        throw OptionsError.usage("--demo and --play cannot be used at the same time. Pick one.")
    }
    return options
}

let usageText = """
helmbridge — shows your Garmin chartplotter screen on your phone.

Usage:  helmbridge [options]

Options:
  --demo         Skip the plotter completely and serve a test picture, so you
                 can check that the phone side works.
  --play         Show the plotter's video on this Mac instead of serving it to
                 a phone.
  --port <n>     Port for the phone web page. Default 8080.
  --host <ip>    Use this plotter address instead of searching the network.
  --help         Show this message.

Before you start:
  1. Put this Mac on the same Wi-Fi network as the plotter (usually the
     plotter's own network).
  2. On the plotter, open
        Settings > Communications > Wi-Fi Network > Wi-Fi Devices
     and when "HelmMirror" appears, choose "View and Control".
"""

// MARK: - Output helpers

func say(_ text: String = "") {
    print(text)
}

func complain(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func printBanner(_ options: Options) {
    say()
    say("helmbridge — Garmin chartplotter on your phone")
    if options.demo {
        say("Demo mode: no plotter needed.")
    }
    say()
}

/// The one thing the user actually has to act on, printed so it cannot be missed.
func printPhoneInstructions(port: UInt16) {
    let rule = String(repeating: "=", count: 64)
    say()
    say(rule)
    say()
    if let ip = LanAddress.primaryIPv4() {
        say("   Open this on your phone:")
        say()
        say("       http://\(ip):\(port)")
        say()
        say("   Type that into Safari's address bar. Do NOT use a home-screen")
        say("   icon saved from github.io — that one needs the internet, which")
        say("   the plotter's Wi-Fi does not have.")
        say()
        // The single most common failure is the phone being on a different
        // network. Show the subnet explicitly so it can be checked offline.
        let parts = ip.split(separator: ".")
        if parts.count == 4 {
            let subnet = parts.prefix(3).joined(separator: ".")
            say("   CHECK THIS FIRST if the page will not load:")
            say("     On the phone: Settings > Wi-Fi > tap the (i) by the network,")
            say("     and look at IP Address. It MUST start with  \(subnet).")
            say("       \(subnet).x        -> same network, good")
            say("       169.254.x.x   -> the phone did not really join")
            say("       anything else -> the phone is on a different network")
        }
        say()
        say("   Your phone must be on the same Wi-Fi network as this Mac.")
    } else {
        say("   Could not work out this Mac's Wi-Fi address.")
        say()
        say("   Open  System Settings > Network  to find this Mac's IP address,")
        say("   then on your phone go to  http://THAT-ADDRESS:\(port)")
        say()
        say("   Your phone must be on the same Wi-Fi network as this Mac.")
    }
    say("   In Safari, tap Share, then \"Add to Home Screen\", to run it full")
    say("   screen like an app.")
    say()
    say("   Leave this window open. Press Control-C here to stop.")
    say()
    say(rule)
    say()
}

// MARK: - Small helpers

/// A stable identity for this Mac, so the plotter remembers the approval between runs.
func stableDeviceID() -> String {
    let fileManager = FileManager.default
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
    let directory = base.appendingPathComponent("HelmMirror", isDirectory: true)
    let file = directory.appendingPathComponent("device-id.txt")

    if let stored = try? String(contentsOf: file, encoding: .utf8) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }

    let fresh = UUID().uuidString
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fresh.write(to: file, atomically: true, encoding: .utf8)
    return fresh
}

/// IPv6 literals need square brackets inside a URL.
func urlHost(_ host: String) -> String {
    if host.contains(":") && !host.hasPrefix("[") { return "[\(host)]" }
    return host
}

func freshHLSDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("helmbridge-hls", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Where the plotter is, however we found it.
struct Target: Sendable {
    var name: String
    var host: String
    var helmPort: Int
    var pairingPort: Int
}

// MARK: - Lifecycle (owns everything that must be shut down)

actor Lifecycle {
    private var link: HelmLink?
    private var pipeline: HLSPipeline?
    private var server: WebServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var stopping = false

    func adopt(link: HelmLink) { self.link = link }
    func adopt(pipeline: HLSPipeline) { self.pipeline = pipeline }
    func adopt(server: WebServer) { self.server = server }
    /// Drop a server that failed to bind, so the next port attempt starts clean.
    func discardServer() { self.server = nil }

    func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            // The default action would kill us before ffmpeg is cleaned up, so ignore
            // it and let the dispatch source below do an orderly shutdown instead.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task { await self.handleSignal() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func handleSignal() async {
        if stopping {
            exit(0)  // second Control-C: go now
        }
        say("")
        say("Stopping...")
        // Never let a wedged child process keep the terminal hostage.
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { exit(0) }
        await shutdown()
        exit(0)
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        await server?.stop()
        await pipeline?.stop()
        await link?.stop()
    }
}

func stopAndExit(_ lifecycle: Lifecycle, _ message: String) async -> Never {
    complain("")
    complain(message)
    await lifecycle.shutdown()
    exit(1)
}

// MARK: - Startup steps

func locatePlotter(_ options: Options, lifecycle: Lifecycle) async -> Target {
    if let host = options.host {
        say("Using the plotter address you gave: \(host)")
        return Target(name: "the plotter at \(host)", host: host, helmPort: 51200, pairingPort: 80)
    }

    say("Looking for your Garmin chartplotter on the Wi-Fi network...")
    guard let found = await BonjourFinder.findFirst(timeout: 10) else {
        await stopAndExit(lifecycle, """
            I could not find a Garmin chartplotter on this network.

            What to do:
              1. On this Mac, join the plotter's Wi-Fi network (the plotter shows its
                 network name under Settings > Communications > Wi-Fi Network).
              2. Make sure the plotter is switched on and awake.
              3. Run  helmbridge  again.

            If you already know the plotter's address you can skip the search:
                helmbridge --host 172.16.6.0

            To check that the phone side works without a plotter:
                helmbridge --demo
            """)
    }

    say("Found \(found.name) at \(found.host).")
    return Target(name: found.name,
                  host: found.host,
                  helmPort: found.helmPort,
                  pairingPort: found.pairingPort)
}

func requestPairing(with target: Target) async {
    say("Asking the plotter to pair with this Mac...")
    let client = PairingClient(host: target.host, port: target.pairingPort)
    do {
        try await client.pair(deviceId: stableDeviceID(), deviceName: "HelmMirror", role: "owner")
        say("Pairing request sent.")
    } catch {
        // The plotter often answers oddly here, or has us paired already. The approval
        // on the plotter's own screen is what really matters, so this never stops us.
        say("The pairing request did not go through (\(error.localizedDescription)).")
        say("That is usually fine — carrying on.")
    }
    say()
    say("Now look at the plotter and approve this Mac:")
    say("    Settings > Communications > Wi-Fi Network > Wi-Fi Devices")
    say("    choose \"HelmMirror\", then \"View and Control\".")
    say()
}

func openSession(with target: Target, lifecycle: Lifecycle) async -> HelmLink {
    let link = HelmLink(host: target.host, port: target.helmPort)
    await lifecycle.adopt(link: link)

    // If the plotter is slow to answer it is nearly always because nobody has
    // pressed "View and Control" yet, so nudge them after a few seconds.
    let nudge = Task {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        say("Still waiting for the plotter. It is waiting for you to choose")
        say("\"View and Control\" for HelmMirror on the plotter's screen.")
    }

    say("Connecting to the plotter...")
    do {
        try await link.start()
        nudge.cancel()
    } catch {
        nudge.cancel()
        await stopAndExit(lifecycle, """
            I reached the plotter but it did not start a session (\(error.localizedDescription)).

            What to do:
              1. On the plotter, open
                    Settings > Communications > Wi-Fi Network > Wi-Fi Devices
                 select "HelmMirror" and choose "View and Control".
              2. Check this Mac is still on the plotter's Wi-Fi network.
              3. Run  helmbridge  again.
            """)
    }

    say("Connected to \(target.name).")
    return link
}

func videoAddress(from link: HelmLink, target: Target) async -> String {
    say("Waiting for the plotter's video address...")
    if let url = await link.waitForRTSPURL(timeout: 12) {
        return url
    }
    let fallback = "rtsp://\(urlHost(target.host)):554/helm_1280x720.h264"
    say("The plotter did not send one, so I will try the usual address instead.")
    return fallback
}

// MARK: - Modes

func runPlayOnThisMac(rtspURL: String, lifecycle: Lifecycle) async {
    do {
        try HLSPipeline.play(rtspURL: rtspURL)
    } catch {
        await stopAndExit(lifecycle, """
            I could not start the video player (\(error.localizedDescription)).

            What to do:
              1. Install the video tools if you have not already:  brew install ffmpeg
              2. Run  helmbridge --play  again.
            """)
    }
    say()
    say("Playing the plotter's screen on this Mac. Press Control-C here to stop.")
    say()
}

func runServer(pipeline: HLSPipeline,
               onTouch: @escaping @Sendable (Double, Double, Bool) async -> Void,
               detail: @escaping @Sendable (Bool) -> String,
               options: Options,
               hlsDirectory: URL,
               lifecycle: Lifecycle) async -> UInt16 {
    guard let webRoot = Bundle.module.url(forResource: "Web", withExtension: nil) else {
        await stopAndExit(lifecycle, """
            The phone web page is missing from this build.

            What to do:
              Rebuild the tool from the HelmMirror folder:  swift build
            """)
    }

    // If the requested port is taken (commonly a previous helmbridge that didn't
    // shut down cleanly), walk forward and use the next free one instead of
    // failing. Being stuck without a web server on a boat, with no way to ask for
    // help, is far worse than quietly moving to 8081.
    let firstPort = options.port
    let lastPort = UInt16(min(Int(firstPort) + 9, 65535))
    var lastError: Error?
    var boundPort: UInt16?

    for candidate in firstPort...lastPort {
        let server = WebServer(
            port: candidate,
            webRoot: webRoot,
            hlsDir: hlsDirectory,
            onTouch: onTouch,
            status: { [pipeline] in
                let streaming = await pipeline.isRunning
                return (streaming, detail(streaming))
            })
        await lifecycle.adopt(server: server)

        do {
            try await server.start()
            if candidate != firstPort {
                print("""

                    Note: port \(firstPort) was already in use, so I'm using \(candidate) instead.
                          Use the address printed below — it has the right port in it.
                    """)
            }
            boundPort = candidate
            break
        } catch {
            lastError = error
            await lifecycle.discardServer()
        }
    }

    if let bound = boundPort { return bound }

    await stopAndExit(lifecycle, """
        I could not open a port for the phone web page. I tried \(firstPort) through \(lastPort).
        (\(lastError?.localizedDescription ?? "unknown error"))

        What to do:
          Another program is using those ports. Either quit it, or pick a
          different range:
              swift run helmbridge --port 9000

          If a previous helmbridge is stuck, this frees it:
              pkill -f helmbridge
        """)
}

func runBridge(_ options: Options, lifecycle: Lifecycle) async {
    printBanner(options)

    let hlsDirectory: URL
    do {
        hlsDirectory = try freshHLSDirectory()
    } catch {
        await stopAndExit(lifecycle, """
            I could not create a working folder for the video (\(error.localizedDescription)).

            What to do:
              Check there is free space on this Mac, then run  helmbridge  again.
            """)
    }

    if options.demo {
        let pipeline = HLSPipeline.demo(outputDir: hlsDirectory)
        await lifecycle.adopt(pipeline: pipeline)
        say("Starting the test picture...")
        do {
            try await pipeline.start()
        } catch {
            await stopAndExit(lifecycle, """
                I could not start the test video (\(error.localizedDescription)).

                What to do:
                  1. Install the video tools:  brew install ffmpeg
                  2. Run  helmbridge --demo  again.
                """)
        }

        let boundPort = await runServer(pipeline: pipeline,
                        onTouch: { _, _, _ in },  // nothing to touch in demo mode
                        detail: { _ in "demo mode — synthetic video, no plotter" },
                        options: options,
                        hlsDirectory: hlsDirectory,
                        lifecycle: lifecycle)

        printPhoneInstructions(port: boundPort)
        return
    }

    let target = await locatePlotter(options, lifecycle: lifecycle)
    await requestPairing(with: target)
    let link = await openSession(with: target, lifecycle: lifecycle)
    let rtspURL = await videoAddress(from: link, target: target)

    if options.play {
        await runPlayOnThisMac(rtspURL: rtspURL, lifecycle: lifecycle)
        return
    }

    let pipeline = HLSPipeline(rtspURL: rtspURL, outputDir: hlsDirectory)
    await lifecycle.adopt(pipeline: pipeline)
    say("Starting the video...")
    do {
        try await pipeline.start()
    } catch {
        await stopAndExit(lifecycle, """
            I could not start the video (\(error.localizedDescription)).

            What to do:
              1. Install the video tools if you have not already:  brew install ffmpeg
              2. Check the plotter is still awake, then run  helmbridge  again.
            """)
    }

    let plotterName = target.name
    let boundPort = await runServer(pipeline: pipeline,
                    onTouch: { [link] x, y, down in
                        await link.sendTouch(nx: x, ny: y, down: down)
                    },
                    detail: { streaming in
                        streaming
                            ? "connected to \(plotterName)"
                            : "the video stopped — check the plotter is awake, then restart helmbridge"
                    },
                    options: options,
                    hlsDirectory: hlsDirectory,
                    lifecycle: lifecycle)

    printPhoneInstructions(port: boundPort)
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)  // keep progress lines flowing even when output is piped

let parsedOptions: Options
do {
    parsedOptions = try parseOptions(Array(CommandLine.arguments.dropFirst()))
} catch OptionsError.helpRequested {
    say(usageText)
    exit(0)
} catch let OptionsError.usage(message) {
    complain(message)
    complain("")
    complain(usageText)
    exit(2)
} catch {
    complain("I could not read the options: \(error.localizedDescription)")
    exit(2)
}

let lifecycle = Lifecycle()

Task {
    await lifecycle.installSignalHandlers()
    await runBridge(parsedOptions, lifecycle: lifecycle)
}

// Startup finishes inside the task above; this keeps the tool running (and the
// keepalive, ffmpeg and web server alive) until Control-C.
dispatchMain()
