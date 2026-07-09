#!/usr/bin/env swift
import Foundation

// Turns saved diagnostics sessions into an audio cases.jsonl the eval/replay
// harness understands: each session's WAV becomes an `input.audio` case, with the
// app's own final text as `reference` (a starting point — correct it by listening,
// since a real recording has no ground truth) and the raw ASR as `asr_reference`.
//
// Usage:
//   swift Scripts/diag-to-cases.swift [outfile.jsonl] [sessionsDir]
// Defaults: outfile = eval/text-cleanup/diag-cases.jsonl,
//           sessionsDir = ~/Library/Application Support/WhisperMaster/Diagnostics/sessions

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "eval/text-cleanup/diag-cases.jsonl"
let home = FileManager.default.homeDirectoryForCurrentUser
let defaultSessions = home
    .appendingPathComponent("Library/Application Support/WhisperMaster/Diagnostics/sessions")
    .path
let sessionsDir = args.count > 2 ? args[2] : defaultSessions

let fm = FileManager.default
guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
    FileHandle.standardError.write(Data("no sessions at \(sessionsDir)\n".utf8))
    exit(1)
}

func string(_ any: Any?) -> String { (any as? String) ?? "" }

var lines: [String] = []
for name in entries.sorted() where name.hasSuffix(".json") {
    let stem = String(name.dropLast(5))
    let jsonURL = URL(fileURLWithPath: sessionsDir).appendingPathComponent(name)
    let wavURL = URL(fileURLWithPath: sessionsDir).appendingPathComponent("\(stem).wav")
    guard fm.fileExists(atPath: wavURL.path),
          let data = try? Data(contentsOf: jsonURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let text = obj["text"] as? [String: Any]
    let case_: [String: Any] = [
        "id": string(obj["id"]).isEmpty ? stem : string(obj["id"]),
        "input": ["audio": wavURL.path],
        "targets": ["light"],
        "reference": string(text?["finalPasted"]),
        "asr_reference": string(text?["rawAsr"]),
    ]
    if let line = try? JSONSerialization.data(withJSONObject: case_),
       let s = String(data: line, encoding: .utf8) {
        lines.append(s)
    }
}

try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    .write(toFile: outPath, atomically: true, encoding: .utf8)
print("wrote \(lines.count) audio cases → \(outPath)")
