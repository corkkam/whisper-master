import Foundation

/// Reads the new lines of `events.jsonl`, like `tail -f`. It keeps a byte offset
/// and the file's inode. It starts again from the top when the inode changes or the
/// file shrinks (rotation or truncation). A last line without a newline waits for
/// the next read. The first read starts 256 KiB before the end, so a new launch
/// sees recent history. Shortcut: lines that the writer adds to the old file between
/// its last read and a rotation are lost. The writer rotates at 8 MiB only.
final class CrewEventTail {
    static let firstReadWindow: UInt64 = 256 * 1024
    private static let pendingLimit = 1 << 20

    let url: URL
    private var opened = false
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var pending = Data()
    /// True after a mid-file start, until the first newline drops the cut line.
    private var skipHead = false

    init(url: URL) {
        self.url = url
    }

    /// The events that arrived since the last call. A line that does not decode is skipped.
    func poll() -> [CrewEvent] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let node = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            // The file is gone. A new file starts from its top.
            opened = true
            inode = nil
            offset = 0
            pending = Data()
            skipHead = false
            return []
        }
        if !opened {
            opened = true
            offset = size > Self.firstReadWindow ? size - Self.firstReadWindow : 0
            skipHead = offset > 0
        } else if node != inode || size < offset {
            offset = 0
            pending = Data()
            skipHead = false
        }
        inode = node
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty
        else { return [] }
        offset += UInt64(data.count)

        var buffer = pending + data
        if skipHead {
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                pending = Data()
                return []
            }
            buffer = Data(buffer[buffer.index(after: newline)...])
            skipHead = false
        }
        guard let last = buffer.lastIndex(of: 0x0A) else {
            pending = buffer.count > Self.pendingLimit ? Data() : buffer
            return []
        }
        pending = Data(buffer[buffer.index(after: last)...])
        return buffer[..<last].split(separator: 0x0A).compactMap {
            String(data: $0, encoding: .utf8).flatMap(CrewEvent.decode(line:))
        }
    }
}
