import UniformTypeIdentifiers
import XCTest

@testable import WhisperMaster

/// `find_files` reads and `open_file` acts. The rules: the model never sees a path and
/// can only open a row a search in this run listed; a file that can run code is
/// refused before any card; every open shows the card, with no Always; and the names
/// a search returns taint the run.
@MainActor
final class FileToolsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - The Spotlight query

    func testTheSearchIsScopedToTheHomeFolder() {
        XCTAssertEqual(FileQuery(query: "plan", kind: nil, home: home).scope, home)
    }

    func testEveryWordMustBeInTheName() {
        let format = FileQuery(query: "Q3 plan", kind: nil, home: home).predicate().predicateFormat
        XCTAssertTrue(format.contains(#"kMDItemFSName CONTAINS[cd] "Q3""#), format)
        XCTAssertTrue(format.contains(#"kMDItemFSName CONTAINS[cd] "plan""#), format)
        XCTAssertFalse(format.contains("kMDItemLastUsedDate"), "a named search is not a recent-files search")
    }

    /// `NSMetadataQuery` raises (and the app would crash) on an AND or an OR of a single
    /// predicate, which a one-word search or a recent-files search would build.
    func testNoCompoundHoldsASinglePredicate() {
        func walk(_ predicate: NSPredicate) {
            guard let compound = predicate as? NSCompoundPredicate else { return }
            if compound.compoundPredicateType != .not {
                XCTAssertGreaterThan(compound.subpredicates.count, 1, predicate.predicateFormat)
            }
            compound.subpredicates.forEach { walk($0 as! NSPredicate) }
        }
        let kinds: [String?] = [nil] + FileQuery.Kind.allCases.map(\.rawValue)
        for query in [nil, "plan", "q3 plan"] {
            for kind in kinds {
                walk(FileQuery(query: query, kind: kind, home: home).predicate())
            }
        }
    }

    func testNoWordsMeansTheRecentlyUsedFiles() {
        let query = FileQuery(query: nil, kind: nil, home: home)
        XCTAssertEqual(query.sortKey, "kMDItemLastUsedDate")
        XCTAssertTrue(query.predicate().predicateFormat.contains("kMDItemLastUsedDate >="))
        XCTAssertEqual(FileQuery(query: "  ", kind: nil, home: home).words, [])
        XCTAssertEqual(FileQuery(query: "plan", kind: nil, home: home).sortKey, "kMDItemFSContentChangeDate")
    }

    func testAKindNarrowsTheSearch() {
        let expected = ["pdf": "com.adobe.pdf", "image": "public.image",
                        "spreadsheet": "public.spreadsheet", "presentation": "public.presentation",
                        "folder": "public.folder", "document": "public.composite-content"]
        XCTAssertEqual(Set(expected.keys), Set(FileQuery.Kind.allCases.map(\.rawValue)))
        for (kind, type) in expected {
            let format = FileQuery(query: nil, kind: kind, home: home).predicate().predicateFormat
            XCTAssertTrue(format.contains(type), "\(kind): \(format)")
        }
        XCTAssertTrue(FileQuery(query: nil, kind: "document", home: home).predicate().predicateFormat
            .contains("public.source-code"), "code is not a document")
        XCTAssertEqual(FileQuery(query: nil, kind: "PDF", home: home).kind, .pdf)
        XCTAssertNil(FileQuery(query: nil, kind: "program", home: home).kind, "an unknown kind is dropped")
    }

    /// A word is a plain substring: wildcards, quotes and operators cannot ride in.
    func testTheWordsAreCleaned() {
        XCTAssertEqual(FileQuery(query: #"re*port" || x"#, kind: nil, home: home).words, ["re", "port", "x"])
        XCTAssertEqual(FileQuery(query: "one two three four five six", kind: nil, home: home).words.count, 5)
        XCTAssertEqual(FileQuery(query: String(repeating: "a", count: 90), kind: nil, home: home)
            .words.first?.count, 40)
    }

    func testOnlyAFileInsideTheHomeFolderMayBeShown() {
        let query = FileQuery(query: "x", kind: nil, home: home)
        func accepts(_ path: String) -> Bool { query.accepts(URL(fileURLWithPath: path)) }
        XCTAssertTrue(accepts("/Users/tester/Documents/Reports/plan.pdf"))
        XCTAssertTrue(accepts("/Users/tester/Desktop/notes.txt"))
        XCTAssertFalse(accepts("/Users/tester"), "the folder itself")
        XCTAssertFalse(accepts("/Users/tester/Library/Mobile Documents/plan.pdf"), "Library")
        XCTAssertFalse(accepts("/Users/tester/library/Caches/x"), "Library, any case")
        XCTAssertFalse(accepts("/Users/tester/.ssh/id_rsa"), "hidden folder")
        XCTAssertFalse(accepts("/Users/tester/Documents/.secret.txt"), "hidden file")
        XCTAssertFalse(accepts("/Users/tester/Documents/.git/config"), "inside a hidden folder")
        XCTAssertFalse(accepts("/Users/tester/Applications/Figma.app"), "an app bundle")
        XCTAssertFalse(accepts("/Users/tester/Downloads/Foo.APP/Contents/Info.plist"), "inside an app bundle")
        XCTAssertFalse(accepts("/Users/testerevil/Documents/plan.pdf"), "a folder that only starts like home")
        XCTAssertFalse(accepts("/etc/hosts"))
        XCTAssertTrue(accepts("/Users/tester/Documents/App notes.pdf"), "a name that only mentions app")
    }

    // MARK: - The row table

    private func row(_ name: String) -> FileRow {
        FileRow(url: temp.appendingPathComponent(name), name: name, folder: "Docs")
    }

    func testRowsCountFromOneAndANewSearchReplacesThem() {
        let table = FileRowTable()
        table.replace(with: [row("a.txt"), row("b.txt")])
        XCTAssertEqual(table.row(1)?.name, "a.txt")
        XCTAssertEqual(table.row(2)?.name, "b.txt")
        XCTAssertNil(table.row(0))
        XCTAssertNil(table.row(3))
        XCTAssertNil(table.row(-1))
        table.replace(with: [row("c.txt")])
        XCTAssertEqual(table.row(1)?.name, "c.txt")
        XCTAssertNil(table.row(2), "a row of the earlier list is gone")
    }

    // MARK: - find_files

    private final class Recorder {
        var cards: [PendingApproval] = []
        var opened: [URL] = []
        var queries: [FileQuery] = []
    }

    private func emptyStore() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    private func hit(_ name: String, in folder: String = "Docs", kind: String = "PDF document",
                     modified: Date? = nil) -> FileHit {
        FileHit(url: temp.appendingPathComponent(folder).appendingPathComponent(name),
                kind: kind, modified: modified)
    }

    private func makeRunner(hits: [FileHit] = [], timedOut: Bool = false,
                        answer: ApprovalOutcome = .allowedOnce,
                        recorder: Recorder, store: ConnectorInstanceStore? = nil,
                        taint: Taint? = nil, rows: FileRowTable? = nil) -> DeviceToolRunner {
        DeviceToolRunner(
            store: store ?? emptyStore(),
            requestApproval: { recorder.cards.append($0); return answer },
            environment: DeviceToolRunner.Environment(
                installedApp: { _ in nil },
                openApp: { _ in false },
                openURL: { _ in false },
                frontApp: { nil },
                findFiles: { query in
                    recorder.queries.append(query)
                    return FileSearchOutcome(hits: hits, timedOut: timedOut)
                },
                openFile: { recorder.opened.append($0); return true }),
            taint: taint ?? Taint(),
            fileRows: rows ?? FileRowTable())
    }

    private func call(_ tool: String, _ arguments: [String: String]) -> ToolCall {
        ToolCall(tool: tool, arguments: arguments)
    }

    func testFindFilesListsNumberedRowsWithNoPath() async {
        let recorder = Recorder()
        let when = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let (result, effect) = await makeRunner(
            hits: [hit("Q3 plan.pdf", in: "Reports", modified: when),
                   hit("Q3 notes.txt", in: "Docs", kind: "Plain text document")],
            recorder: recorder)
            .run(call("find_files", ["query": "q3"]))

        XCTAssertTrue(result.ok)
        XCTAssertNil(effect, "a read is not an action")
        XCTAssertTrue(recorder.cards.isEmpty, "a read raises no card")
        XCTAssertEqual(result.text, """
            1. Q3 plan.pdf \u{2014} PDF document, modified 12 Nov 2026, in Reports
            2. Q3 notes.txt \u{2014} Plain text document, in Docs
            """)
        XCTAssertFalse(result.text.contains(temp.path), "the model never sees a path")
        XCTAssertEqual(result.instanceLabels, ["This Mac"])
        XCTAssertEqual(recorder.queries.first?.words, ["q3"])
    }

    func testFindFilesPassesTheKindAndLimitsTheRows() async {
        let recorder = Recorder()
        let many = (1...16).map { hit("file\($0).pdf") }
        let (result, _) = await makeRunner(hits: many, timedOut: true, recorder: recorder)
            .run(call("find_files", ["kind": "pdf"]))
        XCTAssertEqual(recorder.queries.first?.kind, .pdf)
        XCTAssertEqual(result.text.components(separatedBy: "\n").filter { $0.first?.isNumber == true }.count, 15)
        XCTAssertFalse(result.text.contains("file16.pdf"))
        XCTAssertTrue(result.text.contains("Only the first 15 are listed."))
        XCTAssertTrue(result.text.contains("may be incomplete"), "a search that ran out of time says so")
    }

    func testANameIsOneShortLine() async {
        let recorder = Recorder()
        let long = String(repeating: "a", count: 100) + ".pdf"
        let (result, _) = await makeRunner(hits: [hit("two\nlines.pdf"), hit(long)], recorder: recorder)
            .run(call("find_files", [:]))
        XCTAssertEqual(result.text.components(separatedBy: "\n").count, 2, "a name cannot add a line")
        XCTAssertTrue(result.text.contains("\u{2026}"))
        XCTAssertTrue(result.text.contains(".pdf \u{2014}"), "the cut keeps the extension")
        let shown = FileToolCatalog.displayName(long)
        XCTAssertEqual(shown.count, FileToolCatalog.maxNameLength)
    }

    /// U+202E reverses what follows it on screen, so `fdp.html` showed as `lmth.pdf`
    /// on the card. The name is shown without the bidi controls, in its real order.
    func testANameShowsItsRealExtension() {
        XCTAssertEqual(FileToolCatalog.displayName("Q3 plan\u{202E}fdp.html"), "Q3 planfdp.html")
        XCTAssertEqual(FileToolCatalog.displayName("a\u{2066}b\u{2069}.pdf"), "ab.pdf")
    }

    /// File names are text the user did not write, so a result with rows taints the run
    /// as a connector read does. A search that found nothing read nothing.
    func testFileNamesTaintTheRun() async {
        let taint = Taint()
        _ = await makeRunner(hits: [], recorder: Recorder(), taint: taint).run(call("find_files", [:]))
        XCTAssertFalse(taint.isSet)

        _ = await makeRunner(hits: [hit("a.pdf")], recorder: Recorder(), taint: taint)
            .run(call("find_files", [:]))
        XCTAssertTrue(taint.isSet)
        XCTAssertTrue(taint.outsideSelection)
    }

    func testNoMatchSaysSo() async {
        let (result, _) = await makeRunner(recorder: Recorder()).run(call("find_files", ["query": "zzz"]))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.text, "No files matched.")
    }

    // MARK: - open_file

    private func makeFile(_ name: String, in folder: String = "Docs") throws -> URL {
        let directory = temp.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A runner that has already searched and found `names`, so rows 1... are those files.
    private func found(_ names: [String], answer: ApprovalOutcome = .allowedOnce,
                       recorder: Recorder, store: ConnectorInstanceStore? = nil,
                       taint: Taint? = nil) async throws -> DeviceToolRunner {
        let hits = try names.map { FileHit(url: try makeFile($0), kind: "File", modified: nil) }
        let runner = makeRunner(hits: hits, answer: answer, recorder: recorder, store: store, taint: taint)
        _ = await runner.run(call("find_files", [:]))
        return runner
    }

    func testOpenFileShowsTheCardWithTheNameAndFolderAndNoAlways() async throws {
        let recorder = Recorder()
        let runner = try await found(["plan.txt"], recorder: recorder)
        let (result, effect) = await runner.run(call("open_file", ["row": "1"]))

        let card = try XCTUnwrap(recorder.cards.first)
        XCTAssertEqual(card.tool, "open_file")
        XCTAssertEqual(card.target, "plan.txt")
        XCTAssertEqual(card.arguments, ["file": "plan.txt", "folder": "Docs"])
        XCTAssertEqual(card.instanceID, DeviceToolCatalog.thisMacID)
        XCTAssertFalse(card.offersAlways, "Always is hidden for a file")
        XCTAssertFalse(card.grantable)
        XCTAssertFalse(card.target.contains(temp.path) || card.detail.contains(temp.path))
        XCTAssertEqual(card.headline, "Open plan.txt on This Mac")
        XCTAssertEqual(card.detail, "In the \u{201C}Docs\u{201D} folder.")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(effect, .openedFile(name: "plan.txt"))
        XCTAssertEqual(recorder.opened.map(\.lastPathComponent), ["plan.txt"])
    }

    func testARowThatDoesNotExistOpensNothingAndAsksNothing() async throws {
        let recorder = Recorder()
        let runner = try await found(["plan.txt"], recorder: recorder)
        for row in ["2", "0", "-1", "99", "one", "", "1.5"] {
            let (result, effect) = await runner.run(call("open_file", ["row": row]))
            XCTAssertFalse(result.ok, row)
            XCTAssertNil(effect)
        }
        let (missing, _) = await runner.run(call("open_file", [:]))
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(recorder.cards.isEmpty)
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    /// The file must come from a search in this run: with no search, no row exists, and
    /// a path the model wrote is not a row.
    func testNothingOpensBeforeASearch() async {
        let recorder = Recorder()
        let (result, _) = await makeRunner(recorder: recorder).run(call("open_file", ["row": "1"]))
        XCTAssertFalse(result.ok)
        let (path, _) = await makeRunner(recorder: recorder)
            .run(call("open_file", ["row": "1", "path": "/etc/hosts"]))
        XCTAssertFalse(path.ok)
        XCTAssertTrue(recorder.opened.isEmpty)
        XCTAssertTrue(recorder.cards.isEmpty)
    }

    func testANewSearchReplacesTheRowsAnOldNumberMeant() async throws {
        let recorder = Recorder()
        let runner = try await found(["first.txt", "second.txt"], recorder: recorder)
        let again = FileHit(url: try makeFile("third.txt"), kind: "File", modified: nil)
        let replaced = self.makeRunner(hits: [again], recorder: recorder, rows: runner.fileRows)
        _ = await replaced.run(call("find_files", [:]))
        let (old, _) = await replaced.run(call("open_file", ["row": "2"]))
        XCTAssertFalse(old.ok, "row 2 of the first list is not in the new one")
        _ = await replaced.run(call("open_file", ["row": "1"]))
        XCTAssertEqual(recorder.opened.map(\.lastPathComponent), ["third.txt"])
    }

    func testADeclinedCardOpensNothing() async throws {
        let recorder = Recorder()
        let runner = try await found(["plan.txt"], answer: .denied, recorder: recorder)
        let (result, effect) = await runner.run(call("open_file", ["row": "1"]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.authorization, .denied)
        XCTAssertNil(effect)
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    /// Even a stored grant for the name does not answer, and an Always stores none. The
    /// run is tainted by the search too, so the card carries the after-reading warning.
    func testAGrantNeverAnswersForAFile() async throws {
        let store = emptyStore()
        store.addGrant(Grant(tool: "open_file", instanceID: DeviceToolCatalog.thisMacID, target: "plan.txt"))
        let recorder = Recorder()
        let runner = try await found(["plan.txt"], answer: .allowedAlways, recorder: recorder, store: store)
        let (result, _) = await runner.run(call("open_file", ["row": "1"]))
        XCTAssertEqual(recorder.cards.count, 1, "the card showed")
        XCTAssertEqual(result.authorization, .allowedOnce, "an Always answer runs once")
        XCTAssertEqual(store.grants.count, 1, "nothing new stored")
        XCTAssertNotNil(recorder.cards.first?.readWarning)
    }

    func testAFileThatWentAwayIsNotOpened() async throws {
        let recorder = Recorder()
        let runner = try await found(["gone.txt"], recorder: recorder)
        try FileManager.default.removeItem(at: temp.appendingPathComponent("Docs/gone.txt"))
        let (result, _) = await runner.run(call("open_file", ["row": "1"]))
        XCTAssertFalse(result.ok)
        XCTAssertTrue(recorder.cards.isEmpty)
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    /// A refused file raises no card and opens nothing, whatever the model asked.
    func testAFileThatCanRunCodeIsRefusedBeforeTheCard() async throws {
        let recorder = Recorder()
        let runner = try await found(["install.sh", "plan.txt"], recorder: recorder)
        let (result, effect) = await runner.run(call("open_file", ["row": "1"]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, FileSafety.refusal)
        XCTAssertNil(effect)
        XCTAssertTrue(recorder.cards.isEmpty, "the user is not asked about a file that cannot open")
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    // MARK: - Which files are refused

    private func refused(_ name: String, directory: Bool = false, executable: Bool = false) throws -> Bool {
        let url = temp.appendingPathComponent(name)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try "#!/bin/sh\necho hi\n".write(to: url, atomically: true, encoding: .utf8)
        }
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return FileSafety.refusal(for: url) != nil
    }

    func testEachKindThatCanRunCodeIsRefused() throws {
        // An app, an installer package, a disk image, a script of each kind, a shell
        // command file, an Automator workflow (bundle and flat file), a Terminal
        // settings file, and a link file that opens a page.
        for name in ["Tool.app", "flow.workflow"] {
            XCTAssertTrue(try refused(name, directory: true), name)
        }
        for name in ["setup.pkg", "setup.mpkg", "disk.dmg", "disk.iso", "run.sh", "run.zsh", "run.command",
                     "run.py", "run.rb", "run.pl", "run.js", "run.scpt", "run.applescript",
                     "flat.workflow", "quick.action", "window.terminal", "page.webloc",
                     "page.inetloc", "page.url", "run.jar", "run.exe"] {
            XCTAssertTrue(try refused(name), name)
        }
        // A program with no extension: the type is read from the file, not the name.
        XCTAssertTrue(try refused("program", executable: true))
    }

    func testDocumentsAndFoldersAreAllowed() throws {
        for name in ["plan.pdf", "notes.txt", "photo.png", "sheet.xlsx", "deck.pptx", "memo.docx",
                     "data.csv", "notes.md", "main.swift", "archive.zip", "plain"] {
            XCTAssertFalse(try refused(name), name)
        }
        XCTAssertFalse(try refused("Reports", directory: true))
    }

    /// A link named like a document cannot stand in for a program.
    func testASymlinkIsJudgedByWhatItPointsAt() throws {
        let script = temp.appendingPathComponent("real.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        let link = temp.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        XCTAssertNotNil(FileSafety.refusal(for: link))
    }

    func testTheRefusalTypesNameTheGroup() {
        for type in [UTType.application, .executable, .script, .shellScript, .package, .diskImage] {
            XCTAssertTrue(FileSafety.isCodeType(type), type.identifier)
        }
        XCTAssertTrue(FileSafety.isCodeType(.unixExecutable))
        XCTAssertTrue(FileSafety.isCodeType(UTType("com.apple.installer-package-archive")!))
        XCTAssertFalse(FileSafety.isCodeType(.pdf))
        XCTAssertFalse(FileSafety.isCodeType(.plainText))
        XCTAssertFalse(FileSafety.isCodeType(.folder))
    }

    // MARK: - Where the tools sit

    func testTheToolsAreOfferedAndShapedLikeAnyDeviceTool() {
        XCTAssertEqual(FileToolCatalog.findFiles.access, .read)
        XCTAssertNil(FileToolCatalog.findFiles.capability)
        XCTAssertEqual(FileToolCatalog.openFile.access, .write)
        XCTAssertEqual(FileToolCatalog.openFile.targetArg, "row")
        XCTAssertEqual(FileToolCatalog.openFile.parameters.first?.type, .integer)
        XCTAssertTrue(DeviceToolCatalog.names.isSuperset(of: ["find_files", "open_file"]))
        XCTAssertFalse(DeviceToolCatalog.grantable("open_file"))
        for frontApp in [true, false] {
            let names = DeviceToolCatalog.offered(selection: false, frontApp: frontApp).map(\.name)
            XCTAssertTrue(names.contains("find_files") && names.contains("open_file"))
        }
        // Neither is local, so the tool pack can leave them out of a crowded prompt.
        XCTAssertTrue(FileToolCatalog.all.allSatisfy { $0.access != .local })
    }

    func testTheTraceBadgesASearchAsAReadAndAnOpenAsAWrite() {
        func trace(_ tool: String) -> ToolCallTrace {
            ToolCallTrace(tool: tool, arguments: [:], connectors: [], ok: true, result: "",
                          milliseconds: 0, approvalMilliseconds: 0, authorization: nil)
        }
        XCTAssertFalse(trace("find_files").isWrite)
        XCTAssertTrue(trace("find_files").isDevice)
        XCTAssertTrue(trace("open_file").isWrite)
    }

    func testTheCardCopy() {
        XCTAssertEqual(ApprovalCopy.verb(for: "open_file"), "Open")
        XCTAssertEqual(ApprovalCopy.detail(tool: "open_file", arguments: ["file": "a.pdf", "folder": ""]),
                       "Approve this action?")
    }

    // MARK: - Through the router

    /// A search is not an action. An open that came back ok is.
    func testOnlyTheOpenCountsAsAnAction() async throws {
        let recorder = Recorder()
        let notes = NotesStore(fileURL: temp.appendingPathComponent("notes.json"), load: false)
        let router = CommandToolRouter(
            local: LocalToolRunner(notes: notes),
            connectors: nil,
            device: try await found(["plan.txt"], recorder: recorder))
        let search = await router.run(call("find_files", [:]))
        XCTAssertTrue(search.ok)
        XCTAssertFalse(router.didCreateSomething, "a read is the whole of its result")
        let open = await router.run(call("open_file", ["row": "1"]))
        XCTAssertTrue(open.ok)
        XCTAssertTrue(router.didCreateSomething)
        XCTAssertEqual(router.executed, ["find_files", "open_file"])

        let refusedRow = await router.run(call("open_file", ["row": "9"]))
        XCTAssertFalse(refusedRow.ok)
        XCTAssertEqual(router.executed, ["find_files", "open_file"], "a failed call is not counted")
    }
}
