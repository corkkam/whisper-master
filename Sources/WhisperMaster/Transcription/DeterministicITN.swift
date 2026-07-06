import Foundation

/// Deterministic inverse text normalization: rewrites spoken forms into written
/// form with rules only — same input always yields the same output, instantly,
/// on-device, no model. Handles spoken numbers → digits, currency, percentages,
/// clock times, and emails/URLs. Leaves everything else (including plain "at",
/// "period", and questions) untouched.
///
/// Validated against a suite in the repo's dev notes; extend that suite when
/// adding cases.
enum DeterministicITN {
    static func normalize(_ text: String) -> String {
        // Parakeet's output is inconsistent — sometimes fully spoken ("twenty
        // five"), sometimes hyphenated ("twenty-five"), sometimes already
        // collapsed to digits ("430", "20 percent"). Handle all three: split
        // hyphenated compounds, then a digit pass for the pre-collapsed forms,
        // then the spoken-word pass.
        let toks = tokenize(dehyphenate(text))
        return render(convertNumbers(convertDigits(joinEmails(toks))))
    }

    /// English hyphenates compound numbers 21–99 ("twenty-five"), and the ASR
    /// often emits that form — split it so the number pass can read it.
    private static func dehyphenate(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)-(one|two|three|four|five|six|seven|eight|nine)\b"#,
            with: "$1 $2",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// A whitespace-separated token split into leading punctuation, an
    /// alphanumeric core (used for matching), and trailing punctuation — so
    /// replacements preserve surrounding punctuation ("dollars." → "$5.").
    private struct Tok {
        let lead: String
        let core: String
        let trail: String
        var lower: String { core.lowercased() }
    }

    private static func tokenize(_ s: String) -> [Tok] {
        s.split(separator: " ", omittingEmptySubsequences: true).map { raw -> Tok in
            let chars = Array(String(raw))
            func keep(_ c: Character) -> Bool { c.isLetter || c.isNumber }
            var i = 0, j = chars.count - 1
            while i <= j && !keep(chars[i]) { i += 1 }
            while j >= i && !keep(chars[j]) { j -= 1 }
            if i > j { return Tok(lead: "", core: String(chars), trail: "") }
            return Tok(lead: String(chars[0..<i]), core: String(chars[i...j]), trail: String(chars[(j + 1)...]))
        }
    }

    private static func render(_ toks: [Tok]) -> String {
        toks.map { $0.lead + $0.core + $0.trail }.joined(separator: " ")
    }

    private static func isWordy(_ core: String) -> Bool {
        core.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    // MARK: - Emails / URLs ("ninja at gmail dot com" → "ninja@gmail.com")

    private static func joinEmails(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            if i + 2 < toks.count, toks[i + 1].lower == "at", isWordy(toks[i].core) {
                let local = toks[i]
                // Domain already collapsed by the ASR ("gmail.com").
                if toks[i + 2].core.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z]{2,})+$"#, options: .regularExpression) != nil {
                    out.append(Tok(lead: local.lead,
                                   core: "\(local.core.lowercased())@\(toks[i + 2].core.lowercased())",
                                   trail: toks[i + 2].trail))
                    i += 3
                    continue
                }
                // Spoken domain: <domain> dot <tld> (dot <tld2>)*
                if i + 3 < toks.count, toks[i + 3].lower == "dot", isWordy(toks[i + 2].core) {
                    var parts = [toks[i + 2].core.lowercased()]
                    var j = i + 3
                    var trail = toks[i + 2].trail
                    while j + 1 < toks.count, toks[j].lower == "dot", isWordy(toks[j + 1].core) {
                        parts.append(toks[j + 1].core.lowercased())
                        trail = toks[j + 1].trail
                        j += 2
                    }
                    out.append(Tok(lead: local.lead,
                                   core: "\(local.core.lowercased())@\(parts.joined(separator: "."))",
                                   trail: trail))
                    i = j
                    continue
                }
            }
            out.append(toks[i])
            i += 1
        }
        return out
    }

    // MARK: - Times ("four thirty" → "4:30", "four o'clock pm" → "4:00 PM")

    /// A time starting at `i` given `hour` (1–12), or `nil` if the following
    /// tokens aren't a minute. Runs before number parsing so "four thirty" isn't
    /// merged into the invalid cardinal 34.
    private static func matchTime(_ toks: [Tok], hour: Int, at i: Int) -> (tok: Tok, next: Int)? {
        guard i + 1 < toks.count else { return nil }
        let n1 = toks[i + 1].lower
        var minute: String?
        var next = i + 1
        var trail = ""
        if n1 == "o'clock" {
            minute = "00"; trail = toks[i + 1].trail; next = i + 2
        } else if (n1 == "oh" || n1 == "o"), i + 2 < toks.count,
                  let u = SpokenNumber.units[toks[i + 2].lower], u < 10 {
            minute = "0\(u)"; trail = toks[i + 2].trail; next = i + 3
        } else if let m = SpokenNumber.units[n1], m >= 10 && m < 60 {
            var mm = m, k = i + 2
            trail = toks[i + 1].trail
            if m % 10 == 0, k < toks.count, let u2 = SpokenNumber.units[toks[k].lower], u2 > 0 && u2 < 10 {
                mm += u2; trail = toks[k].trail; k += 1
            }
            minute = String(format: "%02d", mm); next = k
        }
        guard let mm = minute else { return nil }
        var core = "\(hour):\(mm)"
        if next < toks.count {
            let ap = toks[next].lower.replacingOccurrences(of: ".", with: "")
            if ap == "am" || ap == "pm" { core += " " + ap.uppercased(); trail = toks[next].trail; next += 1 }
        }
        return (Tok(lead: toks[i].lead, core: core, trail: trail), next)
    }

    // MARK: - Pre-collapsed digits from the ASR ("430 today" → "4:30", "20 percent" → "20%")

    private static let timePreps: Set<String> = ["at", "by", "before", "after", "around", "til", "till", "until"]
    private static let timeWords: Set<String> = [
        "today", "tomorrow", "tonight", "morning", "afternoon", "evening", "noon", "midnight", "am", "pm", "o'clock",
    ]

    /// Handles digits the ASR already emitted: "430 dollars" → "$430",
    /// "20 percent" → "20%", and a bare 3–4 digit time ("430") → "4:30" — the
    /// last only next to a time word/preposition, so "430 items" stays a number.
    private static func convertDigits(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            guard !t.core.isEmpty, t.core.allSatisfy(\.isNumber), let d = Int(t.core) else {
                out.append(t); i += 1; continue
            }
            if i + 1 < toks.count, ["dollar", "dollars", "buck", "bucks"].contains(toks[i + 1].lower) {
                out.append(Tok(lead: t.lead, core: "$\(d)", trail: toks[i + 1].trail)); i += 2; continue
            }
            if i + 1 < toks.count, toks[i + 1].lower == "percent" {
                out.append(Tok(lead: t.lead, core: "\(d)%", trail: toks[i + 1].trail)); i += 2; continue
            }
            if t.core.count == 3 || t.core.count == 4 {
                let hour = d / 100, minute = d % 100
                if (1...12).contains(hour), (0...59).contains(minute) {
                    let prev = out.last?.lower ?? ""
                    let next = i + 1 < toks.count ? toks[i + 1].lower.replacingOccurrences(of: ".", with: "") : ""
                    if timePreps.contains(prev) || timeWords.contains(next) {
                        out.append(Tok(lead: t.lead, core: "\(hour):\(String(format: "%02d", minute))", trail: t.trail))
                        i += 1; continue
                    }
                }
            }
            out.append(t); i += 1
        }
        return out
    }

    // MARK: - Room / suite numbers ("room two oh five" → "room 205")

    private static let roomKeywords: Set<String> = ["room", "suite", "apartment", "apt", "unit", "rm"]

    /// A room/suite number spoken as digit-chunks, read as a concatenated digit
    /// sequence rather than a clock time or a summed cardinal. Each unit/teen
    /// word is one chunk; a tens word (20–90) may absorb a following ones word
    /// into a two-digit chunk ("twenty five" → "25"); "oh"/"o"/"zero" is a literal
    /// 0. "two oh five" → "205", "two fourteen" → "214", "one twenty" → "120".
    /// Requires ≥ 2 digits so a single "room five" falls through to the normal
    /// number pass ("room 5"), not this path.
    private static func matchRoomNumber(_ toks: [Tok], at i: Int) -> (tok: Tok, next: Int)? {
        var digits = "", j = i, trail = ""
        while j < toks.count {
            let w = toks[j].lower
            if w == "oh" || w == "o" || w == "zero" {
                digits += "0"; trail = toks[j].trail; j += 1
            } else if let u = SpokenNumber.units[w] {
                if u >= 20, u % 10 == 0, j + 1 < toks.count,
                   let o = SpokenNumber.units[toks[j + 1].lower], (1...9).contains(o) {
                    digits += String(u + o); trail = toks[j + 1].trail; j += 2
                } else {
                    digits += String(u); trail = toks[j].trail; j += 1
                }
            } else {
                break
            }
        }
        guard digits.count >= 2 else { return nil }
        return (Tok(lead: toks[i].lead, core: digits, trail: trail), j)
    }

    // MARK: - Numbers, currency, percentages

    private static func convertNumbers(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let w0 = toks[i].lower
            // Room/suite numbers before time/cardinal parsing, so "room two oh
            // five" reads as 205 rather than the clock time 2:05.
            if let prev = out.last?.lower, roomKeywords.contains(prev),
               let r = matchRoomNumber(toks, at: i) {
                out.append(r.tok); i = r.next; continue
            }
            if let hour = SpokenNumber.units[w0], (1...12).contains(hour),
               let t = matchTime(toks, hour: hour, at: i) {
                out.append(t.tok); i = t.next; continue
            }
            let startsA = (w0 == "a" || w0 == "an") && i + 1 < toks.count
                && SpokenNumber.scales[toks[i + 1].lower] != nil
            guard SpokenNumber.isWord(w0) || startsA else { out.append(toks[i]); i += 1; continue }

            var j = i, run: [String] = []
            if startsA { run.append(w0); j = i + 1 }
            while j < toks.count {
                let w = toks[j].lower
                if SpokenNumber.isWord(w) {
                    run.append(w); j += 1
                } else if w == "and", j + 1 < toks.count, SpokenNumber.isWord(toks[j + 1].lower) {
                    run.append(w); j += 1
                } else {
                    break
                }
            }
            guard let value = SpokenNumber.value(run) else {
                // Not a well-formed cardinal (e.g. "one two three") — leave the
                // whole run as spoken words instead of digitizing part of it.
                for k in i..<j { out.append(toks[k]) }
                i = j
                continue
            }

            // A bare "one" is nearly always a word, not a count — "one day",
            // "one of them", "one honest footnote". Digitize it only when a
            // unit that demands a figure follows ("one percent" → 1%,
            // "one dollar" → $1). Times are unaffected (matchTime runs first).
            if run == ["one"] {
                let unitFollows = j < toks.count
                    && ["dollar", "dollars", "buck", "bucks", "percent", "cent", "cents"].contains(toks[j].lower)
                if !unitFollows { out.append(toks[i]); i += 1; continue }
            }

            let lead = toks[i].lead
            var replacement = "\(value)", trail = toks[j - 1].trail, next = j
            if j < toks.count, ["dollar", "dollars", "buck", "bucks"].contains(toks[j].lower) {
                replacement = "$\(value)"; trail = toks[j].trail; next = j + 1
                if next + 1 < toks.count, toks[next].lower == "and" {
                    var k = next + 1, cw: [String] = []
                    while k < toks.count, SpokenNumber.units[toks[k].lower] != nil { cw.append(toks[k].lower); k += 1 }
                    if k < toks.count, ["cent", "cents"].contains(toks[k].lower),
                       let c = SpokenNumber.value(cw), c < 100 {
                        replacement = "$\(value).\(String(format: "%02d", c))"; trail = toks[k].trail; next = k + 1
                    }
                }
            } else if j < toks.count, toks[j].lower == "percent" {
                replacement = "\(value)%"; trail = toks[j].trail; next = j + 1
            }
            out.append(Tok(lead: lead, core: replacement, trail: trail))
            i = next
        }
        return out
    }
}
