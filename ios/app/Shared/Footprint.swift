import Darwin
import Foundation

/// The process's phys_footprint, the figure iOS holds against its limit, and
/// the kernel's record of its peak; each core request appends both to
/// `footprint.log` in the App Group (ios.md §7).
enum Footprint {
    private static let lock = NSLock()
    static let limit: UInt64 = 1 << 20

    /// The current footprint and the peak since the process started.
    static var now: (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(info.ledger_phys_footprint_peak, 0)))
    }

    static var log: URL { Tsync.groupContainer.appendingPathComponent("footprint.log") }
    static var oldLog: URL { Tsync.groupContainer.appendingPathComponent("footprint.old.log") }

    static func record(_ label: String) {
        let value = now
        let mib = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        append("\(label) now \(mib(value.current)) peak \(mib(value.peak))")
    }

    /// One line, stamped, at the end of the log; callbacks append from many
    /// threads. At `limit` the log becomes the old log.
    static func append(_ text: String) {
        let line = "\(stamp()) \(text)\n"
        lock.lock()
        defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: log.path)
        if let size = attributes?[.size] as? UInt64, size >= limit {
            try? FileManager.default.removeItem(at: oldLog)
            try? FileManager.default.moveItem(at: log, to: oldLog)
        }
        guard let handle = try? FileHandle(forWritingTo: log) else {
            try? line.write(to: log, atomically: false, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
