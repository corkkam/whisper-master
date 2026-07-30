import SwiftUI

/// Chip-based editor for the custom-vocabulary glossary. Each term is a removable
/// pill; a single-line field adds new ones on Return. Replaces the raw multiline
/// text box — no two-way-binding/Enter hazards, since the array is mutated
/// explicitly (add on submit, remove on the pill's ×), never re-parsed from text.
///
/// A term may carry a mishearing alias with a colon ("RAG: rack"); the pill shows
/// it as "RAG → rack" while the stored string stays "RAG: rack".
struct VocabularyEditor: View {
    @Binding var terms: [String]
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !terms.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(terms, id: \.self) { term in
                        chip(term)
                    }
                }
            }
            addField
        }
    }

    private func chip(_ term: String) -> some View {
        HStack(spacing: 7) {
            Text(display(for: term))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Button {
                terms.removeAll { $0 == term }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(Theme.surfaceSunken))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var addField: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            if isSnapshot {
                // ImageRenderer can't draw an NSTextField — static stand-in.
                Text("Add a word, like RAG or RAG: rack")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Add a word, like RAG or RAG: rack", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit(add)
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: add)
                        .buttonStyle(.plain)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .pointerCursor()
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !value.isEmpty, !terms.contains(value) else { return }
        terms.append(value)
    }

    /// The stored form is `canonical: misheard` and the correction flows
    /// misheard → canonical, so the chip reads that way: "RAG: rack" → "rack → RAG"
    /// (what the engine hears, then what it's corrected to). A plain term is shown as-is.
    private func display(for term: String) -> String {
        guard let colon = term.firstIndex(of: ":") else { return term }
        let canonical = term[..<colon].trimmingCharacters(in: .whitespaces)
        let misheard = term[term.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return misheard.isEmpty ? canonical : "\(misheard) \u{2192} \(canonical)"
    }
}

/// Minimal wrapping layout: lays subviews left to right, wrapping to a new line
/// when the next one would overflow the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, maxWidth: maxWidth)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, projected > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
