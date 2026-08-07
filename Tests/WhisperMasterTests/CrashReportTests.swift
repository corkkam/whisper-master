import XCTest
@testable import WhisperMaster

/// Covers the pure half of crash reporting: turning Apple's `.ips` file into a
/// content-free, groupable signature.
///
/// The stakes are that this runs on data nobody can inspect before it ships —
/// the parser reads whatever macOS wrote on a stranger's Mac, and a wrong answer
/// is either missing crash data or, much worse, a filename or path leaking into
/// an analytics sink. Both failure modes are checked here.
final class CrashReportTests: XCTestCase {

    // MARK: - Fixtures

    /// A trimmed copy of a real `WhisperMaster-….ips` from a shipped 1.0.1 build:
    /// the MLX/Metal `EXC_BAD_ACCESS` that crashed inside `AGXMetalG17G` with the
    /// app's own frames below it. Kept verbatim in shape — two JSON documents
    /// separated by a newline — because that concatenation is the single most
    /// likely thing to break the parser.
    private func fixture(bundleID: String = "app.whispermaster.mac") -> String {
        let header = """
        {"app_name":"WhisperMaster","timestamp":"2026-08-08 01:46:02.00 +0530","app_version":"1.0.1",\
        "bundleID":"\(bundleID)","incident_id":"51DBF058-DBA5-4EDF-9D52-9FFE75462F21","bug_type":"309"}
        """
        let body = """
        {"faultingThread":0,"exception":{"codes":"0x0000000000000001","type":"EXC_BAD_ACCESS",\
        "signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x9cc"},\
        "usedImages":[{"name":"AGXMetalG17G"},{"name":"WhisperMaster"}],\
        "threads":[{"triggered":true,"frames":[\
        {"imageIndex":0,"symbol":"AGX::ComputeContext<AGX::HAL300::Encoders, AGX::HAL300::Classes>::setPipelineCommon(AGX::HAL300::ComputePipeline*)","imageOffset":3416852},\
        {"imageIndex":0,"symbol":"-[AGXG17GFamilyComputeContext setComputePipelineState:]","imageOffset":3927200},\
        {"imageIndex":1,"symbol":"mlx::core::gpu::eval(mlx::core::array&)","imageOffset":12611252}\
        ]}]}
        """
        return header + "\n" + body
    }

    // MARK: - Parsing

    func testParsesARealCrashReport() throws {
        let report = try XCTUnwrap(
            CrashReportParser.parse(fixture(), expectingBundleID: "app.whispermaster.mac")
        )

        XCTAssertEqual(report.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(report.signal, "SIGSEGV")
        XCTAssertEqual(report.crashedVersion, "1.0.1")
        XCTAssertEqual(report.incidentID, "51DBF058-DBA5-4EDF-9D52-9FFE75462F21")
        XCTAssertNotNil(report.occurredAt)
    }

    /// The whole point of the frame-selection rule. The literal top frame is a
    /// GPU driver symbol; every unrelated Metal fault in the app would land in
    /// that one bucket. The topmost frame from our own binary is what separates
    /// one bug from another.
    func testTheSignatureNamesOurOwnFrameNotTheTopSystemFrame() throws {
        let report = try XCTUnwrap(
            CrashReportParser.parse(fixture(), expectingBundleID: nil)
        )

        XCTAssertEqual(report.binary, "WhisperMaster")
        XCTAssertEqual(report.signature, "WhisperMaster!mlx::core::gpu::eval")
    }

    func testFallsBackToTheTopFrameWhenNoneOfTheStackIsOurs() throws {
        let raw = """
        {"app_version":"1.0.1","incident_id":"X","bundleID":"app.whispermaster.mac"}
        {"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},\
        "usedImages":[{"name":"libsystem_kernel.dylib"}],\
        "threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"__pthread_kill"}]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))

        XCTAssertEqual(report.binary, "libsystem_kernel.dylib")
        XCTAssertEqual(report.signature, "libsystem_kernel.dylib!__pthread_kill")
    }

    // MARK: - What must never be reported

    /// The directory holds every app's diagnostics. Reporting another app's crash
    /// would be both wrong and a privacy leak dressed up as telemetry.
    func testAnotherAppsReportIsRejected() {
        let raw = fixture(bundleID: "com.apple.Safari")
        XCTAssertNil(CrashReportParser.parse(raw, expectingBundleID: "app.whispermaster.mac"))
    }

    /// Hang, spin, and wakeup-limit reports share the `.ips` extension and this
    /// directory but carry no `exception`. Counting them as crashes would inflate
    /// the crash rate with reports of the app merely being slow.
    func testANonCrashDiagnosticIsRejected() {
        let raw = """
        {"app_version":"1.0.1","bundleID":"app.whispermaster.mac","bug_type":"142"}
        {"threads":[],"reason":"unresponsive"}
        """
        XCTAssertNil(CrashReportParser.parse(raw, expectingBundleID: "app.whispermaster.mac"))
    }

    func testGarbageAndTruncatedFilesYieldNilRatherThanAPartialReport() {
        for raw in ["", "not json", "{}", "{\"a\":1}\n{ truncated", "\n"] {
            XCTAssertNil(
                CrashReportParser.parse(raw, expectingBundleID: nil),
                "expected nil for \(raw.debugDescription)"
            )
        }
    }

    /// From a real 1.0.1 report. Apple coalesces identical symbols and writes the
    /// placeholder `<deduplicated_symbol>` in their place. It shortens to nothing
    /// (it's all template brackets), so taking it left the signature as a bare
    /// `WhisperMaster` while the frame that actually named the bug sat directly
    /// beneath it.
    func testApplesDeduplicatedSymbolPlaceholderIsSkippedForTheFrameBelowIt() throws {
        let raw = """
        {"app_version":"1.0.1","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},\
        "usedImages":[{"name":"WhisperMaster"}],\
        "threads":[{"triggered":true,"frames":[\
        {"imageIndex":0,"symbol":"<deduplicated_symbol>"},\
        {"imageIndex":0,"symbol":"mlx::core::scheduler::Scheduler::get_default_stream(mlx::core::Device const&) const"}\
        ]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(
            report.signature,
            "WhisperMaster!mlx::core::scheduler::Scheduler::get_default_stream"
        )
    }

    /// From a real dev-build report: an uncaught Objective-C exception thrown
    /// during `NSView` layout. Every frame near the crash is AppKit and our only
    /// frame is `main`, at the very bottom — which every stack has. Preferring
    /// our own binary without a depth limit signed this `WhisperMaster!main`:
    /// useless as a grouping key and wrong about whose code failed.
    func testAnAppKitExceptionIsNotMisattributedToOurMainFunction() throws {
        var frames = (0..<20).map { index in
            "{\"imageIndex\":0,\"symbol\":\"AppKitFrame\(index)\"}"
        }
        frames.append("{\"imageIndex\":1,\"symbol\":\"static WhisperMasterApp.main()\"}")
        let raw = """
        {"app_version":"1.0.0","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},\
        "usedImages":[{"name":"AppKit"},{"name":"WhisperMaster.debug.dylib"}],\
        "threads":[{"triggered":true,"frames":[\(frames.joined(separator: ","))]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.binary, "AppKit")
        XCTAssertEqual(report.signature, "AppKit!AppKitFrame0")
    }

    /// The real 1.0.0 popover crash. An uncaught Objective-C exception unwinds
    /// before the process dies, so the crashed thread is left sitting in AppKit's
    /// exception trampoline — every frame naming the bug already popped. Read from
    /// `threads` alone this signs `AppKit!+[NSApplication _crashOnException:]`,
    /// which is where *every* uncaught exception in the app lands: an AVAudioEngine
    /// format mismatch and a bad popover presentation would share one bucket.
    /// `asiBacktraces` still holds the throw site, so it wins.
    func testTheThrowSiteNamesTheBugRatherThanAppKitsExceptionTrampoline() throws {
        let raw = """
        {"app_version":"1.0.0","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},\
        "asiBacktraces":["0   CoreFoundation   0x19011e448 __exceptionPreprocess + 176\\n\
        1   libobjc.A.dylib   0x18fb7c5e4 objc_exception_throw + 88\\n\
        2   CoreFoundation   0x190142f50 _CFBundleGetValueForInfoKey + 0\\n\
        3   ViewBridge   0x19abae3f0 -[NSRemoteView containingWindowWillOrderOnScreen:] + 216\\n\
        19  AppKit   0x194784124 -[NSPopover showRelativeToRect:ofView:preferredEdge:] + 2000"],\
        "usedImages":[{"name":"AppKit"}],\
        "threads":[{"triggered":true,"frames":[\
        {"imageIndex":0,"symbol":"+[NSApplication _crashOnException:]"}]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.binary, "ViewBridge")
        XCTAssertEqual(
            report.signature,
            "ViewBridge!-[NSRemoteView containingWindowWillOrderOnScreen:]"
        )
    }

    /// A `+ 0` offset in a throw stack means the symbolicator landed on a
    /// function's first instruction, which a *return* address never is — it's the
    /// nearest preceding export standing in for a missing symbol. In the popover
    /// report one sits directly above the frame that actually threw, so taking it
    /// would name the wrong thing with full confidence.
    func testAMissymbolicatedZeroOffsetFrameIsSkippedForTheOneBelowIt() throws {
        let raw = """
        {"app_version":"1.0.0","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},\
        "asiBacktraces":["0   CoreFoundation   0x1 _CFBundleGetValueForInfoKey + 0\\n\
        1   ViewBridge   0x2 -[NSRemoteView layout] + 40"],\
        "usedImages":[{"name":"AppKit"}],\
        "threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"trampoline"}]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.signature, "ViewBridge!-[NSRemoteView layout]")
    }

    /// The throw stack gets the same "ours beats theirs, near the top" preference
    /// the thread stack does — when our code is what threw, say so.
    func testOurOwnFrameInTheThrowStackStillWins() throws {
        let raw = """
        {"app_version":"1.0.0","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},\
        "asiBacktraces":["0   CoreFoundation   0x1 __exceptionPreprocess + 176\\n\
        1   libobjc.A.dylib   0x2 objc_exception_throw + 88\\n\
        2   AVFAudio   0x3 -[AVAudioEngine startAndReturnError:] + 100\\n\
        3   WhisperMaster   0x4 MicrophoneCaptureService.start(onBuffer:) + 20"],\
        "usedImages":[{"name":"AppKit"}],\
        "threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"trampoline"}]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.signature, "WhisperMaster!MicrophoneCaptureService.start")
    }

    /// The flip side: an app frame a few frames down — under a little system
    /// machinery — is still the one that names the bug.
    func testAnAppFrameJustBelowSystemMachineryIsStillPreferred() throws {
        let raw = """
        {"app_version":"1.0.0","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},\
        "usedImages":[{"name":"libobjc.A.dylib"},{"name":"WhisperMaster"}],\
        "threads":[{"triggered":true,"frames":[\
        {"imageIndex":0,"symbol":"objc_exception_throw"},\
        {"imageIndex":1,"symbol":"MicrophoneCaptureService.start(onBuffer:)"}\
        ]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.signature, "WhisperMaster!MicrophoneCaptureService.start")
    }

    /// A stripped or JIT frame has no symbol. The binary name alone still says
    /// something useful, so the frame must not be discarded.
    func testAFrameWithNoSymbolStillIdentifiesItsBinary() throws {
        let raw = """
        {"app_version":"1.0.1","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_BAD_ACCESS"},"usedImages":[{"name":"WhisperMaster"}],\
        "threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":42}]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.signature, "WhisperMaster")
    }

    func testACrashWithNoReadableStackStillReportsTheException() throws {
        let raw = """
        {"app_version":"1.0.1","incident_id":"X","bundleID":"a"}
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"}}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.exceptionType, "EXC_BREAKPOINT")
        XCTAssertEqual(report.signature, "unsymbolicated")
    }

    /// `faultingThread` is an index; `triggered` is a flag. Apple has used both,
    /// so a report carrying only the index must still resolve.
    func testTheFaultingThreadIndexIsUsedWhenNoThreadIsFlaggedTriggered() throws {
        let raw = """
        {"app_version":"1.0.1","incident_id":"X","bundleID":"a"}
        {"faultingThread":1,"exception":{"type":"EXC_BAD_ACCESS"},\
        "usedImages":[{"name":"libA"},{"name":"libB"}],\
        "threads":[{"frames":[{"imageIndex":0,"symbol":"idle"}]},\
        {"frames":[{"imageIndex":1,"symbol":"boom"}]}]}
        """
        let report = try XCTUnwrap(CrashReportParser.parse(raw, expectingBundleID: nil))
        XCTAssertEqual(report.signature, "libB!boom")
    }

    // MARK: - Symbol shortening

    /// GA truncates a parameter at 100 characters. The real MLX symbols run to
    /// several hundred and differ only in their argument lists, so a raw
    /// truncation collapses distinct overloads into one indistinguishable bucket.
    func testOverloadsThatDifferOnlyByArgumentsAreNotShortenedIntoAmbiguity() {
        let vectorOverload = """
        mlx::core::binary_op_gpu_inplace(std::__1::vector<mlx::core::array, \
        std::__1::allocator<mlx::core::array>> const&, \
        std::__1::vector<mlx::core::array, std::__1::allocator<mlx::core::array>>&, \
        char const*, mlx::core::Stream const&)
        """
        XCTAssertGreaterThan(vectorOverload.count, GA4Limits.maxParameterValueLength)
        XCTAssertEqual(
            CrashReportParser.shortenSymbol(vectorOverload),
            "mlx::core::binary_op_gpu_inplace"
        )
    }

    func testTemplateParametersAreStrippedButTheQualifiedNameSurvives() {
        XCTAssertEqual(
            CrashReportParser.shortenSymbol(
                "AGX::ComputeContext<AGX::HAL300::Encoders, AGX::HAL300::Classes>::setPipelineCommon(AGX::HAL300::ComputePipeline*)"
            ),
            "AGX::ComputeContext::setPipelineCommon"
        )
    }

    /// Objective-C selectors have neither templates nor an argument list, and
    /// their trailing colon is part of the name.
    func testObjectiveCSelectorsPassThroughUnchanged() {
        let selector = "-[AGXG17GFamilyComputeContext setComputePipelineState:]"
        XCTAssertEqual(CrashReportParser.shortenSymbol(selector), selector)
    }

    func testAStraySymbolCannotDriveTheTemplateDepthNegativeAndSwallowTheName() {
        // `operator>` and friends: a `>` with no matching `<`. Naive depth
        // counting goes negative here and drops everything that follows.
        XCTAssertEqual(
            CrashReportParser.shortenSymbol("std::greater::operator>"),
            "std::greater::operator"
        )
    }

    func testEveryShortenedSymbolFitsInsideGooglesParameterLimit() {
        let monster = String(repeating: "Namespace::", count: 40) + "function(int, int)"
        let short = CrashReportParser.shortenSymbol(monster)
        XCTAssertLessThanOrEqual(short.count, GA4Limits.maxParameterValueLength)
    }

    // MARK: - The event

    func testTheCrashEventIsAcceptedByGoogleAndCarriesNoUserContent() {
        let report = CrashReportParser.parse(fixture(), expectingBundleID: nil)
        XCTAssertNotNil(report)

        for event in [AnalyticsEvent.appCrashed(report), .appCrashed(nil)] {
            XCTAssertEqual(GA4Limits.eventName(event.googleName), event.googleName)

            let clamped = GA4Limits.parameters(event.parameters)
            for (name, value) in clamped {
                XCTAssertLessThanOrEqual(value.count, GA4Limits.maxParameterValueLength)
                XCTAssertNotNil(
                    name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression),
                    "\(name) is not a legal GA4 parameter name"
                )
                // The `.ips` is full of the account name — in `procPath`, in
                // `userID`, and in its own filename. None of it may get this far.
                XCTAssertFalse(value.contains("/"), "a path reached the wire: \(value)")
            }
            XCTAssertEqual(clamped["crash_signature"]?.isEmpty, false)
        }
    }

    /// An unclean exit with no report is a real and common case (Force Quit,
    /// power cut, an unreadable diagnostics directory). It must still send —
    /// flagged — rather than being silently dropped.
    func testAnUncleanExitWithNoReportIsFlaggedRatherThanDropped() {
        let parameters = AnalyticsEvent.appCrashed(nil).parameters
        XCTAssertEqual(parameters["hasReport"], "false")
        XCTAssertEqual(parameters["exceptionType"], "unknown")
    }

    func testAConfirmedCrashIsDistinguishableFromAnUncleanExit() {
        let report = CrashReportParser.parse(fixture(), expectingBundleID: nil)
        XCTAssertEqual(AnalyticsEvent.appCrashed(report).parameters["hasReport"], "true")
    }

    // MARK: - Discovery

    private func makeReportsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func write(_ contents: String, named name: String, in directory: URL) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func testFindsOurCrashAmongOtherAppsDiagnostics() throws {
        let directory = try makeReportsDirectory()
        try write("noise", named: "SFA-ckks.json_2026-08-04_lappy.diag", in: directory)
        try write(fixture(bundleID: "com.apple.Safari"), named: "Safari-2026-08-08.ips", in: directory)
        try write(fixture(), named: "WhisperMaster-2026-08-08-014602.ips", in: directory)

        let report = CrashReporter.findLatestCrashReport(
            bundleID: "app.whispermaster.mac",
            excludingIncident: nil,
            directory: directory
        )

        XCTAssertEqual(report?.exceptionType, "EXC_BAD_ACCESS")
    }

    /// The same `.ips` sits in the directory for weeks. Without the incident-id
    /// guard, every subsequent unclean exit would re-report the same old crash
    /// and the crash count would climb on its own.
    func testAnAlreadyReportedCrashIsNotCountedTwice() throws {
        let directory = try makeReportsDirectory()
        try write(fixture(), named: "WhisperMaster-2026-08-08-014602.ips", in: directory)

        XCTAssertNil(CrashReporter.findLatestCrashReport(
            bundleID: "app.whispermaster.mac",
            excludingIncident: "51DBF058-DBA5-4EDF-9D52-9FFE75462F21",
            directory: directory
        ))
    }

    /// A Mac that was shut down for a week must not attribute last week's crash
    /// to this morning's launch.
    func testAStaleReportIsIgnored() throws {
        let directory = try makeReportsDirectory()
        let name = "WhisperMaster-2026-08-08-014602.ips"
        try write(fixture(), named: name, in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: directory.appendingPathComponent(name).path
        )

        XCTAssertNil(CrashReporter.findLatestCrashReport(
            bundleID: "app.whispermaster.mac",
            excludingIncident: nil,
            directory: directory
        ))
    }

    func testAnUnreadableDirectoryIsNotAnError() {
        XCTAssertNil(CrashReporter.findLatestCrashReport(
            bundleID: "app.whispermaster.mac",
            excludingIncident: nil,
            directory: URL(fileURLWithPath: "/nonexistent/DiagnosticReports")
        ))
    }
}
