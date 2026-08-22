import Darwin
import Foundation
import MLX

/// Where a memory sample comes from. A seam, so the run engine can be exercised
/// in a test without touching Metal — `swift test` cannot run MLX at all (its
/// shaders only compile under xcodebuild), so anything that calls into it has to
/// be replaceable.
protocol LabMemorySource: Sendable {
    func sample(atMs: Int) -> LabMemorySample
    /// Forget the high-water mark, so the next model's peak is its own.
    func resetPeak()
}

/// The real one: MLX's own accounting for GPU buffers, plus the process
/// footprint from the kernel.
///
/// **These two numbers answer different questions and both are shown.** MLX's
/// `activeMemory` is what the model's weights and working buffers cost;
/// `phys_footprint` is what the whole app costs the machine, which is the number
/// a user would see in Activity Monitor and includes the ASR models, the UI and
/// everything else. Reporting only the first flatters the model; reporting only
/// the second cannot tell two models apart.
struct LabGPUMemorySource: LabMemorySource {
    func sample(atMs: Int) -> LabMemorySample {
        let snapshot = MLX.GPU.snapshot()
        return LabMemorySample(
            atMs: atMs,
            activeBytes: Int64(snapshot.activeMemory),
            cacheBytes: Int64(snapshot.cacheMemory),
            peakBytes: Int64(snapshot.peakMemory),
            footprintBytes: LabProcessMemory.footprintBytes())
    }

    func resetPeak() { MLX.GPU.resetPeakMemory() }
}

/// Physical footprint of this process, the same figure Activity Monitor shows as
/// "Memory". `task_vm_info`'s `phys_footprint` rather than `resident_size`:
/// resident size counts pages shared with other processes and undercounts
/// compressed ones, so it drifts from what the machine actually feels.
enum LabProcessMemory {
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

/// Which Mac produced a run. Recorded on every run because a latency figure from
/// an M1 Air and one from an M3 Max are not comparable, and a history rail that
/// mixes them silently is worse than no history.
enum LabMachine {
    static var summary: String {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let gigabytes = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "\(chip), \(gigabytes) GB"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Byte counts as a person reads them. Decimal units, matching how model cards
/// and download sizes are quoted.
enum LabFormat {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0" }
        let gigabyte = 1_000_000_000.0
        let megabyte = 1_000_000.0
        if Double(value) >= gigabyte { return String(format: "%.2f GB", Double(value) / gigabyte) }
        return String(format: "%.0f MB", Double(value) / megabyte)
    }

    static func milliseconds(_ value: Int) -> String {
        value >= 10_000 ? String(format: "%.1f s", Double(value) / 1000) : "\(value) ms"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }
}
