import Foundation
import AVFoundation
import UIKit
import UserNotifications
import HuntCore

@MainActor final class NavigationVoice {
    private let synthesizer = AVSpeechSynthesizer()
    private var selectedVoice: AVSpeechSynthesisVoice?
    private var lastSpoken: String?
    private var lastSpokenAt: Date?
    private var lastStatus: TrackReturnTracker.Status?
    private var lastWarningAt: Date?
    private var lastTimestamp: Date?
    private var lastDistanceBucket: Int?
    func reset() {
        synthesizer.stopSpeaking(at: .immediate)
        lastStatus = nil
        lastWarningAt = nil
        lastTimestamp = nil
        lastDistanceBucket = nil
        lastSpoken = nil
        lastSpokenAt = nil
    }
    func update(_ result: TrackReturnTracker.Result, timestamp: Date) {
        guard lastTimestamp.map({ timestamp > $0 }) ?? true else { return }
        lastTimestamp = timestamp
        let changed = lastStatus != result.status
        lastStatus = result.status
        guard UserDefaults.standard.object(forKey: "hunt.navigation.voice") as? Bool ?? true else { return }
        let message: String
        switch result.status {
        case .waiting, .approachingDeviation:
            return
        case .offTrack:
            guard changed || lastWarningAt.map({ timestamp.timeIntervalSince($0) >= 120 }) ?? true else { return }
            lastWarningAt = timestamp
            message = "Вы отклонились. Вернитесь на маршрут."
        case .arrived:
            guard changed else { return }
            message = "Вы прибыли."
        case .following:
            let bucket = Int(max(0, result.remaining) / 500)
            guard changed || lastDistanceBucket.map({ bucket < $0 }) == true else {
                lastDistanceBucket = bucket
                return
            }
            lastDistanceBucket = bucket
            let meters = Int(result.remaining.rounded())
            message = "Осталось \(meters) метров."
        }
        // Background notifications are independent of SwiftUI and need iOS permission.
        if UIApplication.shared.applicationState != .active {
            if result.status == .offTrack || result.status == .arrived { notify(message) }
            return
        }
        speak(message)
    }
    func speakRoute(_ message: String) {
        guard UserDefaults.standard.object(forKey: "hunt.navigation.voice") as? Bool ?? true else { return }
        guard UIApplication.shared.applicationState == .active else {
            notify(message)
            return
        }
        speak(message)
    }

    private func speak(_ message: String) {
        let now = Date()
        if lastSpoken == message, let lastSpokenAt, now.timeIntervalSince(lastSpokenAt) < 8 { return }
        if selectedVoice == nil {
            selectedVoice = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("ru") }
                .sorted { $0.quality.rawValue > $1.quality.rawValue }.first
                ?? AVSpeechSynthesisVoice(language: "ru-RU")
        }
        guard let voice = selectedVoice else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.91
        utterance.pitchMultiplier = 0.97
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.06
        utterance.postUtteranceDelay = 0.12
        lastSpoken = message
        lastSpokenAt = now
        synthesizer.speak(utterance)
    }
    private func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "QAZ TRAIL"
        content.body = message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
