import Foundation
import UIKit
import Darwin

/// Lightweight, local performance counters. No GPS or personal information.
@MainActor final class HuntPerformance: NSObject {
    static let shared = HuntPerformance()
    private let started = CACurrentMediaTime()
    private var firstReady: Double?
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var sampleStart: CFTimeInterval = 0
    private var frames = 0
    private var fps: Double?
    private var worstFrame: Double = 0
    private var offlineOpen: Double?
    private var openingAt: CFTimeInterval?
    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrame = 0; sampleStart = 0; frames = 0
    }
    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrame > 0 { worstFrame = max(worstFrame, (now - lastFrame) * 1000) }
        lastFrame = now
        if sampleStart == 0 { sampleStart = now; frames = 0; return }
        frames += 1
        if now - sampleStart >= 1 {
            fps = Double(frames) / (now - sampleStart)
            sampleStart = now; frames = 0
        }
    }
    func markReady() {
        if firstReady == nil { firstReady = (CACurrentMediaTime() - started) * 1000 }
    }
    func markOfflineOpening() { openingAt = CACurrentMediaTime() }
    func markOfflineOpened() {
        if let at = openingAt { offlineOpen = (CACurrentMediaTime() - at) * 1000; openingAt = nil }
    }
    private func residentMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_048_576
    }
    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "not measured"
    }
    var report: String {
        """
        UI readiness since app init ms: \(format(firstReady))
        Display-link cadence FPS (not GPU rendering FPS): \(format(fps))
        Longest foreground frame interval ms: \(format(worstFrame > 0 ? worstFrame : nil))
        Resident RAM MiB: \(format(residentMB()))
        Offline manager presentation ms: \(format(offlineOpen))
        """
    }
}
