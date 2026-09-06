import Foundation

/// One macOS crash, reduced to the handful of content-free fields that are worth
/// sending to an analytics sink.
///
/// Everything here is either an enum-like constant produced by the kernel
/// (`EXC_BAD_ACCESS`, `SIGSEGV`) or a symbol name compiled into a binary. **No
/// path, filename, username, or user content ever reaches this struct** — the
/// `.ips` report is full of all four (`procPath`, the report's own filename, and
/// `userID` all carry the account name), so the parser reads only the fields
/// below and drops the rest on the floor.
struct CrashReport: Equatable {
    /// Apple's per-report UUID. Persisted after reporting so the same crash is
    /// never counted twice across launches.
    let incidentID: String
    /// Mach exception, e.g. `EXC_BAD_ACCESS`, `EXC_CRASH`, `EXC_BREAKPOINT`.
    let exceptionType: String
    /// POSIX signal, e.g. `SIGSEGV`, `SIGABRT`.
    let signal: String
    /// The app version that crashed — deliberately separate from the version
    /// doing the reporting, since the report is read on the *next* launch, which
    /// may already be a Sparkle update past it.
    let crashedVersion: String
    /// Groupable "where it died" string, e.g. `WhisperMaster!mlx::core::gpu::eval`.
    let signature: String
    /// The binary the signature's frame belongs to (`WhisperMaster`,
    /// `AGXMetalG17G`, `libsystem_kernel.dylib`), so GA can split "our bug" from
    /// "a system framework fell over" without parsing the signature.
    let binary: String
    let occurredAt: Date?
}

/// Reads Apple's `.ips` crash reports.
///
/// **Format.** A modern `.ips` is *two* JSON documents concatenated with a
/// newline: a one-line header (`app_name`, `bundleID`, `app_version`,
/// `incident_id`, `timestamp`) followed by the body (`exception`, `threads`,
/// `usedImages`). `JSONSerialization` will not read that as one document, which
/// is why `split(separator: "\n", maxSplits: 1)` comes first.
///
/// Pure and total: every field is optional in practice — Apple changes this
/// format between releases and a hang report has no `exception` at all — so
/// anything unreadable yields `nil` rather than a partially-invented report.
enum CrashReportParser {

    /// Parse one `.ips` file's contents.
    ///
    /// Returns `nil` for anything that isn't an actual crash of `bundleID`:
    /// another app's report, a hang/spin/wakeup report (those `.ips` types carry
    /// no `exception`), or a file whose shape we don't recognise.
    static func parse(_ raw: String, expectingBundleID bundleID: String?) -> CrashReport? {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let headerData = parts[0].data(using: .utf8),
              let bodyData = parts[1].data(using: .utf8),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        else { return nil }

        // Only ever report on ourselves. Without this the scan would happily
        // upload every crash on the user's Mac, which is both none of our
        // business and a privacy leak dressed up as telemetry.
        if let bundleID {
            guard header["bundleID"] as? String == bundleID else { return nil }
        }

        // The presence of an `exception` block is what separates a crash report
        // from the hangs, wakeup-limit, and disk-write reports that share the
        // `.ips` extension and this directory.
        guard let exception = body["exception"] as? [String: Any],
              let exceptionType = exception["type"] as? String,
              !exceptionType.isEmpty
        else { return nil }

        // The exception's own stack first, the crashed thread's second — see
        // `throwSiteFrame`.
        let frame = throwSiteFrame(in: body) ?? triggeredFrame(in: body)

        return CrashReport(
            incidentID: header["incident_id"] as? String ?? "",
            exceptionType: exceptionType,
            signal: exception["signal"] as? String ?? "",
            crashedVersion: header["app_version"] as? String ?? "",
            signature: frame.map { signature(binary: $0.binary, symbol: $0.symbol) } ?? "unsymbolicated",
            binary: frame?.binary ?? "",
            occurredAt: (header["timestamp"] as? String).flatMap(timestamp(from:))
        )
    }

    // MARK: - Frame selection

    /// The frame that *threw*, for a crash that came from an Objective-C exception.
    ///
    /// **Why the crashed thread isn't good enough here.** An uncaught exception unwinds
    /// before the process dies, so by the time the crash is taken the triggered thread
    /// is sitting in AppKit's exception trampoline and every frame naming the bug has
    /// already been popped. The real popover crash signs as
    /// `AppKit!+[NSApplication _crashOnException:]` from `threads` alone — and so does
    /// *every other* uncaught exception in the app, from an `AVAudioEngine` format
    /// mismatch to a bad `NSPopover` presentation. They all collapse into one bucket:
    /// the same "unrelated faults share a signature" failure `ownFrameSearchDepth`
    /// exists to prevent, just at the other end of the stack.
    ///
    /// `asiBacktraces` is the stack captured at the throw, and it still holds the
    /// culprit — for that crash, `ViewBridge!-[NSRemoteView containingWindowWillOrderOnScreen:]`.
    /// A plain memory fault carries no such block and falls through to the thread stack.
    private static func throwSiteFrame(in body: [String: Any]) -> (binary: String, symbol: String)? {
        // Several backtraces means several exceptions in flight; the first is the one
        // that started it, and the rest are duplicates of it in practice.
        guard let backtraces = body["asiBacktraces"] as? [String],
              let stack = backtraces.first
        else { return nil }

        let frames = stack
            .split(separator: "\n")
            .compactMap(parseThrowSiteLine)
            .filter { !isExceptionMachinery($0.symbol) && !shortenSymbol($0.symbol).isEmpty }

        let ownNearTop = frames.prefix(ownFrameSearchDepth).first { isOwnBinary($0.binary) }
        return ownNearTop ?? frames.first
    }

    /// One `asiBacktraces` line — index, binary, address, symbol, offset:
    ///
    /// ```
    /// 3   ViewBridge   0x19abae3f0 -[NSRemoteView containingWindowWillOrderOnScreen:] + 216
    /// ```
    private static func parseThrowSiteLine(_ line: Substring) -> (binary: String, symbol: String)? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, fields[2].hasPrefix("0x") else { return nil }
        let binary = String(fields[1])
        let tail = fields[3...].joined(separator: " ")

        guard let plus = tail.range(of: " + ", options: .backwards) else { return (binary, tail) }
        // An offset of exactly zero means the symbolicator landed on a function's first
        // instruction, which a *return* address never is — it's the nearest preceding
        // export standing in for a symbol the report doesn't carry. In the popover crash
        // that's `CoreFoundation!_CFBundleGetValueForInfoKey + 0` sitting directly above
        // the frame that actually threw. Naming it would be worse than naming nothing,
        // so it's dropped the same way `<deduplicated_symbol>` is below.
        guard tail[plus.upperBound...] != "0" else { return nil }
        return (binary, String(tail[..<plus.lowerBound]))
    }

    /// The frames on top of every uncaught Objective-C exception. They name the throw
    /// mechanism, never the bug.
    private static func isExceptionMachinery(_ symbol: String) -> Bool {
        symbol == "__exceptionPreprocess"
            || symbol == "objc_exception_throw"
            || symbol == "objc_exception_rethrow"
    }

    /// Pick the frame the signature should name.
    ///
    /// **Our own binary is preferred over the true top frame, but only near the
    /// top of the stack.** A Metal or libsystem frame on top is real but not
    /// groupable — every unrelated GPU fault collapses onto one `AGXMetalG17G`
    /// bucket — so the topmost *app* frame is usually what distinguishes one bug
    /// from another. The depth limit is what stops that preference from
    /// backfiring: every stack has our `main` at the bottom, so an uncaught
    /// AppKit exception during view layout (all AppKit frames, app code nowhere
    /// near it) would otherwise be signed `WhisperMaster!main` — useless, and
    /// actively misleading about whose bug it is. Past the limit the top frame
    /// wins and the report says AppKit, which is the truth.
    private static func triggeredFrame(in body: [String: Any]) -> (binary: String, symbol: String)? {
        guard let threads = body["threads"] as? [[String: Any]] else { return nil }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        // `faultingThread` is an index into `threads`; `triggered` is the flag on
        // the thread itself. Either can be missing, so try both before giving up.
        let crashed = threads.first { $0["triggered"] as? Bool == true }
            ?? (body["faultingThread"] as? Int).flatMap { index in
                threads.indices.contains(index) ? threads[index] : nil
            }
        guard let frames = crashed?["frames"] as? [[String: Any]] else { return nil }

        let resolved: [(binary: String, symbol: String)] = frames.compactMap { frame in
            guard let index = frame["imageIndex"] as? Int, images.indices.contains(index) else {
                return nil
            }
            let binary = images[index]["name"] as? String ?? ""
            guard !binary.isEmpty else { return nil }
            // No symbol (a stripped or JIT frame) still identifies a binary, which
            // is worth more than dropping the frame entirely.
            return (binary, frame["symbol"] as? String ?? "")
        }

        // A frame whose symbol shortens to nothing names no code. The real case
        // is Apple's `<deduplicated_symbol>` placeholder for a coalesced symbol,
        // which lands on top often enough to matter: taking it yields a bare
        // binary name while the genuinely informative frame sits directly below.
        let named = resolved.filter { !shortenSymbol($0.symbol).isEmpty }

        let ownNearTop = named.prefix(ownFrameSearchDepth).first { isOwnBinary($0.binary) }
        return ownNearTop ?? named.first ?? resolved.first
    }

    /// How deep to look for an app frame before concluding the crash happened
    /// somewhere else. Deep enough to see past a few frames of system machinery
    /// (`_crashOnException`, `objc_exception_throw`, a Metal driver's internals),
    /// shallow enough never to reach the run loop and `main`.
    private static let ownFrameSearchDepth = 12

    /// Whether an image name is the app's own executable rather than a system
    /// framework or a linked dylib. Matches the channel-badged names
    /// `Scripts/channel.sh` produces (`WhisperMaster`, `WhisperMasterBeta`, …).
    private static func isOwnBinary(_ name: String) -> Bool {
        name.hasPrefix("WhisperMaster")
    }

    // MARK: - Signatures

    /// `binary!symbol`, with the symbol shortened to the part that identifies it.
    static func signature(binary: String, symbol: String) -> String {
        let short = shortenSymbol(symbol)
        guard !short.isEmpty else { return binary }
        return "\(binary)!\(short)"
    }

    /// Strip a mangled C++/Swift symbol down to something that fits GA's 100-char
    /// parameter limit and groups correctly.
    ///
    /// The real symbols in this app's crash reports run to several hundred
    /// characters — one MLX frame is
    /// `mlx::core::binary_op_gpu_inplace(std::__1::vector<mlx::core::array, std::__1::allocator<…>> const&, …)`.
    /// Truncated at 100 that becomes indistinguishable from its sibling overload,
    /// so both collapse into one bucket. Dropping the argument list and template
    /// parameters — which is where all the length lives — keeps the qualified
    /// name, which is what actually names the bug.
    ///
    /// Objective-C symbols (`-[AGXG17GFamilyComputeContext setComputePipelineState:]`)
    /// have neither, and pass through unchanged.
    static func shortenSymbol(_ symbol: String) -> String {
        var output = ""
        var templateDepth = 0

        for character in symbol {
            switch character {
            case "<":
                templateDepth += 1
            case ">":
                // Guard against a stray `>` (an operator symbol, a malformed
                // name) driving the depth negative and swallowing the rest.
                templateDepth = max(0, templateDepth - 1)
            case "(":
                // The argument list is the tail of the symbol; everything that
                // identifies it has already been read.
                guard templateDepth > 0 else {
                    return trimmed(output)
                }
            default:
                if templateDepth == 0 { output.append(character) }
            }
        }
        return trimmed(output)
    }

    private static func trimmed(_ symbol: String) -> String {
        String(symbol.trimmingCharacters(in: .whitespaces).prefix(90))
    }

    // MARK: - Timestamps

    /// `.ips` header format: `2026-08-08 01:46:02.00 +0530`.
    private static func timestamp(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.date(from: raw)
    }
}
