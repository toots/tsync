import Darwin
import Foundation

/// The process's phys_footprint, the figure iOS holds against its limit,
/// sampled every 20 ms; each record appends the current value and the peak
/// since the previous record to `footprint.log` in the App Group container.
enum Footprint {
    private static let lock = NSLock()
    private static var peak: UInt64 = 0
    private static var started = false

    static var now: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static var log: URL { Core.group.appendingPathComponent("footprint.log") }

    static func startSampling() {
        lock.lock()
        defer { lock.unlock() }
        if started { return }
        started = true
        Thread.detachNewThread {
            while true {
                let value = now
                lock.lock()
                peak = max(peak, value)
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    static func record(_ label: String) {
        let value = now
        lock.lock()
        let seen = max(peak, value)
        peak = value
        lock.unlock()
        let mib = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        append("\(label) now \(mib(value)) peak \(mib(seen))")
    }

    /// One line, stamped, at the end of the log.
    static func append(_ text: String) {
        let line = "\(stamp()) \(text)\n"
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
