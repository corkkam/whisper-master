import Foundation

/// Chooses the tools one local prompt offers, so the count stays inside what the
/// on-device model was measured to handle.
///
/// The Phase 0 sweep put first-turn tool choice at 16 of 16 with 11 tools and 15 of
/// 16 with 16, and every tool is prompt text the 4B holds beside the command. So the
/// notes and reminders tools always stay (filing the words is what the chord falls
/// back to), `read_selection` stays when it is offered, and past the limit the
/// connector tools that share the fewest words with the command are left out. Which
/// connector tools are offered at all is still `ToolRegistry`'s answer.
enum ToolPackRouter {
    static let limit = 16

    /// `tools` in their own order, at most `limit` of them.
    static func pack(_ tools: [ToolDescriptor], spoken: String,
                     limit: Int = limit) -> [ToolDescriptor] {
        guard tools.count > limit else { return tools }
        let words = keywords(spoken)
        let optional = tools.indices.filter { tools[$0].access != .local }
        let room = max(0, limit - (tools.count - optional.count))
        // Most shared words first; a tie keeps the list's own order.
        // A listing ranks as high as the row tools that need it, so "reply to Sam in
        // Slack" keeps `list_messages` beside `reply_message`.
        let raw = tools.map { score($0, words) }
        func rank(_ index: Int) -> Int {
            tools.indices.reduce(raw[index]) { best, other in
                needs[tools[other].name]?.contains(tools[index].name) == true ? max(best, raw[other]) : best
            }
        }
        // shortcut: a tie at the room's edge can still keep a row tool without its listing;
        // rank the pair as one unit if a bench shows it.
        let ranked = optional.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            return left != right ? left > right : lhs < rhs
        }
        let kept = Set(ranked.prefix(room))
        return tools.indices
            .filter { tools[$0].access == .local || kept.contains($0) }
            .map { tools[$0] }
    }

    /// Tools that take a row number, and the listings that give one.
    static let needs: [String: [String]] = [
        ItemTools.replyMessage: ["list_messages"],
        ItemTools.replyMail: ["list_mail", ItemTools.searchMail],
        ItemTools.readItem: ["list_mail", ItemTools.searchMail, "list_messages"],
        FileToolCatalog.openFile.name: [FileToolCatalog.findFiles.name],
    ]

    /// How many of the command's words the tool's name and summary carry.
    static func score(_ tool: ToolDescriptor, _ words: Set<String>) -> Int {
        words.intersection(keywords(tool.name + " " + tool.summary)).count
    }

    /// Lowercased words of three letters or more, a plural `s` dropped, so "emails"
    /// meets "email" and "events" meets "event".
    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : String($0) })
    }
}
