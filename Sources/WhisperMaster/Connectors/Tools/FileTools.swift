import Foundation
import UniformTypeIdentifiers

/// Finding files on this Mac and opening one, through `DeviceToolRunner`.
///
/// `find_files` is the first device tool that only reads. The model never sees a path:
/// it gets numbered rows, and `open_file` takes a row number, so a path the model wrote
/// can never be opened.
enum FileToolCatalog {
    static let findFiles = ToolDescriptor(
        name: "find_files",
        summary: "Find files on this Mac by name, or list the files used most recently. "
            + "Returns numbered rows.",
        access: .read,
        capability: nil,
        targetArg: nil,
        parameters: [
            ToolParameter("query", description: "Words in the file name. Omit for recent files."),
            ToolParameter("kind", description: "The kind of file.",
                          allowedValues: FileQuery.Kind.allCases.map(\.rawValue)),
        ])

    static let openFile = ToolDescriptor(
        name: "open_file",
        summary: "Open a file that find_files listed, in its own app.",
        access: .write,
        capability: nil,
        targetArg: "row",
        parameters: [
            ToolParameter("row", type: .integer, isRequired: true,
                          description: "The row number from find_files."),
        ])

    static let all = [findFiles, openFile]

    /// A file name the model reads and the card shows: one line, and cut in the middle
    /// past `limit`, so the extension stays visible. Bidi embeddings, overrides and
    /// isolates are removed: U+202E made `fdp.html` show as `lmth.pdf`.
    static let maxNameLength = 60

    static func displayName(_ name: String, limit: Int = maxNameLength) -> String {
        let line = String(String.UnicodeScalarView(ToolRouter.oneLine(name).unicodeScalars.filter {
            !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }))
        guard line.count > limit else { return line }
        let keep = limit - 1
        return line.prefix(keep / 2) + "\u{2026}" + line.suffix(keep - keep / 2)
    }
}

/// A file a `find_files` row stands for.
struct FileRow: Equatable, Sendable {
    let url: URL
    let name: String
    let folder: String
}

/// The rows of the latest `find_files` call in one run: row number to file. Only a row
/// in here can be opened, and a new search replaces them, so a number always means what
/// the last list said. A box, like `Taint`, because the runner's `run` does not mutate.
@MainActor
final class FileRowTable {
    private(set) var rows: [FileRow] = []

    func replace(with rows: [FileRow]) { self.rows = rows }

    /// Rows count from 1, as the model reads them.
    func row(_ number: Int) -> FileRow? {
        rows.indices.contains(number - 1) ? rows[number - 1] : nil
    }
}

/// Files `open_file` refuses: those that can run code or act on their own when opened.
enum FileSafety {
    static let refusal = "That kind of file can run code, so it wasn't opened."

    private static let types: [UTType] = [
        .application, .executable, .script, .shellScript, .package, .diskImage,
        // A link to a page opens in the browser with no link card.
        .internetLocation,
    ] + [
        "com.apple.installer-package-archive", "com.apple.automator-workflow",
        "com.apple.terminal.settings", "com.microsoft.internet-shortcut",
    ].compactMap { UTType($0) }

    /// Types Launch Services only names for a bundle on disk, so a flat file with the
    /// extension reads as plain data.
    private static let extensions: Set<String> = ["workflow", "action"]

    static func isCodeType(_ type: UTType) -> Bool {
        types.contains { type.conforms(to: $0) }
    }

    /// Why this file must not be opened, or nil. A symlink is followed first, so a link
    /// named like a document cannot stand in for a program.
    static func refusal(for url: URL) -> String? {
        let url = url.resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isPackageKey])
        if values?.isPackage == true { return refusal }
        if let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension),
           isCodeType(type) { return refusal }
        return extensions.contains(url.pathExtension.lowercased()) ? refusal : nil
    }
}

extension DeviceToolRunner {
    // MARK: - find_files

    /// A read: it opens nothing, so there is no card. The names it returns are text the
    /// user did not write, so a result with rows taints the run, as a connector read does.
    func findFiles(_ call: ToolCall) async -> (ToolResult, Effect?) {
        let query = FileQuery(query: call.arguments["query"], kind: call.arguments["kind"])
        let outcome = await environment.findFiles(query)
        let hits = outcome.hits
        let shown = Array(hits.prefix(FileQuery.limit))
        fileRows.replace(with: shown.map {
            FileRow(url: $0.url, name: FileToolCatalog.displayName($0.name),
                    folder: FileToolCatalog.displayName($0.folder))
        })
        guard !shown.isEmpty else {
            return (ToolResult(ok: true, text: "No files matched.", instanceLabels: []), nil)
        }
        taint.isSet = true
        taint.outsideSelection = true
        var lines = shown.enumerated().map { index, hit in
            let row = fileRows.rows[index]
            let modified = hit.modified.map { ", modified \(Self.date.string(from: $0))" } ?? ""
            return "\(index + 1). \(row.name) \u{2014} \(FileToolCatalog.displayName(hit.kind))\(modified), in \(row.folder)"
        }
        if hits.count > shown.count { lines.append("Only the first \(shown.count) are listed.") }
        if outcome.timedOut {
            lines.append("The search stopped after \(Int(FileQuery.timeout)) seconds, so this list may be incomplete.")
        }
        return (ToolResult(ok: true, text: lines.joined(separator: "\n"),
                           instanceLabels: [DeviceToolCatalog.thisMacLabel]), nil)
    }

    // MARK: - open_file

    func openFile(_ call: ToolCall) async -> (ToolResult, Effect?) {
        guard let number = Int(call.arguments["row"] ?? ""), let file = fileRows.row(number) else {
            return (.failure("That row isn't in the list. Call find_files, then use a row number it listed."), nil)
        }
        let url = file.url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (.failure("\(file.name) is no longer there."), nil)
        }
        // Before the card: the user is never asked about a file that cannot open.
        if let refusal = FileSafety.refusal(for: url) { return (.failure(refusal), nil) }
        switch await authorize(FileToolCatalog.openFile, target: file.name,
                               arguments: ["file": file.name, "folder": file.folder]) {
        case .stop(let result):
            return (result, nil)
        case .go(let authorization, let waited):
            let opened = environment.openFile(url)
            return (ToolResult(ok: opened,
                               text: opened ? "Opened \(file.name)." : "Couldn't open \(file.name).",
                               instanceLabels: opened ? [DeviceToolCatalog.thisMacLabel] : [],
                               authorization: authorization,
                               approvalMilliseconds: waited),
                    opened ? .openedFile(name: file.name) : nil)
        }
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}
