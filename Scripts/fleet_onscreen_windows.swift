// Read-only CoreGraphics sampler for the FM-05 live probe.
//
//   fleet_onscreen_windows.swift <pid>
//   fleet_onscreen_windows.swift --watch --interval-ms 20 --duration-seconds 45 <pid>
//
// Counts layer-0 windows owned by <pid> from the on-screen list. CG window numbers are
// not MCP logical window IDs; callers must never equate them.
import CoreGraphics
import Darwin
import Foundation

func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fleet_onscreen_windows: \(message)\n".utf8))
    exit(code)
}

/// nil means CoreGraphics returned nothing readable; callers must never treat that as zero windows.
func layerZeroNumbers(pid: Int32, options: CGWindowListOption) -> [Int]? {
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var numbers: [Int] = []
    for row in rows {
        guard let owner = row[kCGWindowOwnerPID as String] as? Int,
              let layer = row[kCGWindowLayer as String] as? Int,
              let number = row[kCGWindowNumber as String] as? Int
        else { continue }
        if owner == Int(pid), layer == 0 { numbers.append(number) }
    }
    return numbers.sorted()
}

func sampleObject(pid: Int32, auxiliary: Bool) -> [String: Any]? {
    let time = monotonicSeconds()
    guard let numbers = layerZeroNumbers(pid: pid, options: [.optionOnScreenOnly]) else { return nil }
    var object: [String: Any] = ["pid": Int(pid), "t": time, "count": numbers.count, "numbers": numbers]
    if auxiliary {
        guard let all = layerZeroNumbers(pid: pid, options: [.optionAll]) else { return nil }
        object["all_numbers"] = all
    }
    return object
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        fail("could not encode sample")
    }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

var watch = false
var intervalMs = 20.0
var durationSeconds = 45.0
var pidText: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--watch":
        watch = true
    case "--interval-ms":
        guard let value = arguments.isEmpty ? nil : Double(arguments.removeFirst()), value >= 1 else {
            fail("--interval-ms needs a number >= 1", code: 2)
        }
        intervalMs = value
    case "--duration-seconds":
        guard let value = arguments.isEmpty ? nil : Double(arguments.removeFirst()), value > 0 else {
            fail("--duration-seconds needs a positive number", code: 2)
        }
        durationSeconds = value
    default:
        guard pidText == nil, !argument.hasPrefix("--") else { fail("unexpected argument: \(argument)", code: 2) }
        pidText = argument
    }
}

guard let text = pidText, let pidValue = Int32(text), pidValue > 0 else {
    fail("a positive owner PID is required", code: 2)
}

if !watch {
    guard let object = sampleObject(pid: pidValue, auxiliary: false) else {
        fail("CGWindowListCopyWindowInfo returned no readable window list")
    }
    emit(object)
    exit(0)
}

// Resident mode: one process, absolute deadlines so a slow sample does not accumulate drift.
let stopAt = monotonicSeconds() + durationSeconds
var next = monotonicSeconds()
var ready = false
while monotonicSeconds() < stopAt {
    guard let object = sampleObject(pid: pidValue, auxiliary: true) else {
        fail("CGWindowListCopyWindowInfo returned no readable window list")
    }
    emit(object)
    if !ready {
        ready = true
        emit(["event": "ready", "t": monotonicSeconds()])
    }
    next += intervalMs / 1000
    let wait = next - monotonicSeconds()
    if wait > 0 {
        usleep(UInt32(wait * 1_000_000))
    } else {
        next = monotonicSeconds()
    }
}

exit(0)
