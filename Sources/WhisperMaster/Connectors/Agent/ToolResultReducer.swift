import Foundation

/// A tool result as the model reads it on every later turn: the rows that matter
/// most, cut to a character budget, with the cut stated.
///
/// `AgentLoop.render` sends every tool result again on each later turn, and the
/// on-device generation neither truncates its prompt nor times prompt processing, so a
/// runaway result would be paid for once per iteration. The budget is only a stop for
/// that: the Phase 0 chain bench found one fact in 600- and 1,200-word listings 4 of 4
/// times with no cut, so a smaller budget would lose facts the model handles. A cut
/// that says nothing would read as the whole result, so the last line always states
/// what was left out.
///
/// The trace keeps its own clamp (`TraceText.clamp`) on the full result; this is only
/// what the model sees.
enum ToolResultReducer {
    /// Characters of one tool result the model sees. The same as `SelectionReader.limit`.
    static let budget = 8_000

    /// `text` unchanged when it fits. A listing (`ToolRouter.read`: one line per item,
    /// ending in its `[Connection]`) keeps its other lines — the day heading, a
    /// connection that couldn't be read — and as many rows as fit. Unread rows are
    /// chosen first, then the rest in the tool's order, and a row too long to fit is
    /// passed over for a shorter one after it. The kept rows stay in the tool's own
    /// order, which is the order the user knows (a day reads by time). Any other text
    /// is cut at the budget.
    static func reduce(_ text: String, budget: Int = budget) -> String {
        guard text.count > budget else { return text }
        let lines = text.components(separatedBy: "\n")
        let rowIndices = lines.indices.filter { isRow(lines[$0]) }
        guard rowIndices.count > 1, let firstRow = rowIndices.first else {
            return cut(text, budget: budget)
        }
        let rows = Set(rowIndices)
        let head = lines[..<firstRow].filter { !$0.isEmpty }
        let tail = lines[firstRow...].indices.filter { !rows.contains($0) }.map { lines[$0] }
            .filter { !$0.isEmpty }
        // Reserved at the widest count it could state, so the line always fits.
        let fixed = (head + tail).reduce(0) { $0 + $1.count + 1 }
            + moreLine(rowIndices.count).count
        var spent = fixed
        var kept = Set<Int>()
        for index in chosenOrder(rowIndices, lines: lines) {
            guard spent + lines[index].count + 1 <= budget else { continue }
            spent += lines[index].count + 1
            kept.insert(index)
        }
        // Nothing fits beside the fixed lines: a plain cut at least shows some rows.
        guard !kept.isEmpty else { return cut(text, budget: budget) }
        let shown = rowIndices.filter(kept.contains).map { lines[$0] }
        return (head + shown + tail + [moreLine(rowIndices.count - kept.count)])
            .joined(separator: "\n")
    }

    /// The stated cut of a listing.
    static func moreLine(_ count: Int) -> String { "\(count) more not shown." }

    /// A row as `ToolRouter.read` writes one: text, then ` [Connection label]`. A
    /// gap line starts with the label instead and is never a row.
    static func isRow(_ line: String) -> Bool {
        guard line.hasSuffix("]"), !line.hasPrefix("["),
              let open = line.range(of: " [", options: .backwards)
        else { return false }
        return !line[open.upperBound...].dropLast().contains("]")
    }

    /// The order rows are chosen in: unread first, then the rest, each in the tool's
    /// order.
    static func chosenOrder(_ rowIndices: [Int], lines: [String]) -> [Int] {
        rowIndices.filter { isUnread(lines[$0]) } + rowIndices.filter { !isUnread(lines[$0]) }
    }

    /// `ToolRouter.read` writes an unread item's detail as "(unread)" or
    /// "(unread · …)", and an Outlook detail carries "unread · " itself.
    static func isUnread(_ row: String) -> Bool {
        row.contains("(unread)") || row.contains("(unread · ")
    }

    /// Any text that is not a listing: the first characters that fit, and how many
    /// were left out.
    static func cut(_ text: String, budget: Int) -> String {
        // Sized for the largest count it could state, so the result stays in budget.
        let room = max(0, budget - "\n[\(text.count) more characters not shown]".count)
        let kept = String(text.prefix(room))
        return kept + "\n[\(text.count - kept.count) more characters not shown]"
    }
}
