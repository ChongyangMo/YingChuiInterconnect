import Darwin
import Foundation

struct ProcessResourceSnapshot {
    let memoryBytes: UInt64
    let cpuSeconds: Double
    let uptime: TimeInterval

    static func read() throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: "进程内存读取失败", code: Int(status)) }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return Self(memoryBytes: info.phys_footprint, cpuSeconds: cpu, uptime: ProcessInfo.processInfo.systemUptime)
    }
}
