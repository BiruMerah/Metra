import Foundation
import Darwin
import MachO
import UIKit

enum DeviceIdentity {
    static func hardwareModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

enum BuildIdentity {
    static var metadata: [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let configuration = info["MetraBuildConfiguration"] as? String ?? "unknown"
        return [
            "configuration": configuration,
            "bundle_id": Bundle.main.bundleIdentifier as Any? ?? NSNull(),
            "app_version": info["CFBundleShortVersionString"] as Any? ?? NSNull(),
            "build_number": info["CFBundleVersion"] as Any? ?? NSNull(),
            "debugger_attached": NSNull()
        ]
    }
}

struct MetricEvent: Codable, Sendable {
    let eventID: String
    let runID: String
    let pageID: String?
    let stage: String
    let kind: String
    let wallTime: String
    let monotonicSeconds: Double
    let durationMilliseconds: Double?
    let status: String
    let detail: String?
}

struct MemorySample: Codable, Sendable {
    let wallTime: String
    let monotonicSeconds: Double
    let appPhysFootprintBytes: UInt64?
    let sampler: String
    let thermalState: String
    let lowPowerMode: Bool
    let scope: String
}

enum ProcessMemory {
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

@MainActor
final class MemorySampler {
    private var task: Task<Void, Never>?
    private let outputURL: URL
    private let runID: String
    private let intervalSeconds: Double = 0.2

    init(outputURL: URL, runID: String) {
        self.outputURL = outputURL
        self.runID = runID
    }

    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.record()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func sampleNow() { record() }

    private func record() {
        let process = ProcessInfo.processInfo
        let sample = MemorySample(
            wallTime: ISO8601DateFormatter().string(from: Date()),
            monotonicSeconds: process.systemUptime,
            appPhysFootprintBytes: ProcessMemory.physicalFootprintBytes(),
            sampler: "task_info(TASK_VM_INFO).phys_footprint; 200ms interval",
            thermalState: Self.thermalString(process.thermalState),
            lowPowerMode: process.isLowPowerModeEnabled,
            scope: "app_process_only; WKWebView WebContent and runtime-internal unreported memory excluded"
        )
        appendJSONLine(sample, to: outputURL)
    }

    static func thermalString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

func appendJSONLine<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let line = String(data: data, encoding: .utf8)?.appending("\n"),
          let lineData = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: lineData)
}
