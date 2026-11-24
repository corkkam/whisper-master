import Foundation

/// What a `find_files` call asks Spotlight for, and which of its answers may be shown.
///
/// Pure data and rules, so the scope, the predicate and the exclusions are testable
/// without running Spotlight. `SpotlightFileSearch` is the live half.
struct FileQuery: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case document, pdf, image, spreadsheet, presentation, folder

        /// Spotlight's content type tree, the same attribute Finder's Kind filter reads.
        fileprivate var predicate: NSPredicate {
            func tree(_ type: String) -> NSPredicate {
                NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, type)
            }
            switch self {
            case .pdf: return tree("com.adobe.pdf")
            case .image: return tree("public.image")
            case .spreadsheet: return tree("public.spreadsheet")
            case .presentation: return tree("public.presentation")
            case .folder: return tree("public.folder")
            case .document:
                // Source code is plain text too, and would bury every real document.
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        tree("public.composite-content"), tree("public.plain-text")]),
                    NSCompoundPredicate(notPredicateWithSubpredicate: tree("public.source-code")),
                ])
            }
        }
    }

    /// Rows a result lists.
    static let limit = 15
    /// How long a search may run before what it has is used.
    static let timeout: TimeInterval = 3
    /// Raw results looked at: most of a broad name match is `~/Library` and dot-folders.
    static let scanLimit = 2_000
    /// With no words, the files used in this many days.
    static let recentDays = 30

    let words: [String]
    let kind: Kind?
    /// The only folder searched. Everything outside it is never returned.
    let home: URL

    /// - Parameters:
    ///   - query: the model's words for the file name. Wildcards and quotes are dropped,
    ///     so a word can only ever be a plain substring.
    ///   - kind: one of `Kind`'s names. An unknown one is ignored, not guessed.
    init(query: String?, kind: String?,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        words = (query ?? "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .map { String($0.prefix(40)) }
        self.kind = kind.flatMap { Kind(rawValue: $0.lowercased()) }
        self.home = home
    }

    var scope: URL { home }

    /// Every word must be in the name. With no words it is the recent files, so the
    /// predicate never matches the whole home folder.
    func predicate(now: Date = Date()) -> NSPredicate {
        var parts = words.map {
            NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0)
        }
        if words.isEmpty {
            let since = now.addingTimeInterval(-Double(Self.recentDays) * 86_400)
            parts.append(NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, since as NSDate))
        }
        if let kind { parts.append(kind.predicate) }
        // `NSMetadataQuery` raises on an AND of one predicate.
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// Newest first: by last use for the recent files, by change otherwise.
    var sortKey: String {
        words.isEmpty ? NSMetadataItemLastUsedDateKey : NSMetadataItemFSContentChangeDateKey
    }

    /// Whether a result may be shown: inside the home folder, not in `~/Library`, not
    /// hidden (any dot-named folder or file on the way), and not an app bundle or
    /// anything inside one.
    func accepts(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/")
        guard let first = parts.first, first.lowercased() != "library" else { return false }
        return !parts.contains { $0.hasPrefix(".") || $0.lowercased().hasSuffix(".app") }
    }
}

/// One file Spotlight found.
struct FileHit: Equatable, Sendable {
    let url: URL
    let kind: String
    let modified: Date?

    var name: String { url.lastPathComponent }
    /// The parent folder's own name, never the path.
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

struct FileSearchOutcome: Equatable, Sendable {
    var hits: [FileHit] = []
    /// The 3 seconds ran out, so `hits` may be missing files.
    var timedOut = false
}

/// The live search: `NSMetadataQuery` over the user's home folder.
@MainActor
enum SpotlightFileSearch {
    static func search(_ query: FileQuery) async -> FileSearchOutcome {
        let spotlight = NSMetadataQuery()
        spotlight.predicate = query.predicate()
        spotlight.searchScopes = [query.scope]
        spotlight.sortDescriptors = [NSSortDescriptor(key: query.sortKey, ascending: false)]

        // Whichever comes first: the gather finishes, or the time runs out.
        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false
            var observer: NSObjectProtocol?
            func end(timedOut: Bool) {
                guard !finished else { return }
                finished = true
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: timedOut)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: spotlight, queue: .main
            ) { _ in end(timedOut: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + FileQuery.timeout) { end(timedOut: true) }
            spotlight.start()
        }
        spotlight.disableUpdates()
        spotlight.stop()

        var hits: [FileHit] = []
        // One more than the limit, so the caller can say there were more.
        for index in 0..<min(spotlight.resultCount, FileQuery.scanLimit) where hits.count <= FileQuery.limit {
            guard let item = spotlight.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard query.accepts(url) else { continue }
            hits.append(FileHit(
                url: url,
                kind: item.value(forAttribute: NSMetadataItemKindKey) as? String ?? "File",
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date))
        }
        return FileSearchOutcome(hits: hits, timedOut: timedOut)
    }
}
