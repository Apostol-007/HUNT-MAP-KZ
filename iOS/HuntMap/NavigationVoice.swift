import Foundation
import AVFoundation
import UIKit
import UserNotifications
import HuntCore

@MainActor final class NavigationVoice {
    private let synthesizer = AVSpeechSynthesizer()
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
            message = "Отклонение от маршрута. Вернитесь к записанному пути."
        case .arrived:
            guard changed else { return }
            message = "Вы достигли конечной точки маршрута."
        case .following:
            let bucket = Int(max(0, result.remaining) / 500)
            guard changed || lastDistanceBucket.map({ bucket < $0 }) == true else {
                lastDistanceBucket = bucket
                return
            }
            lastDistanceBucket = bucket
            let meters = Int(result.remaining.rounded())
            message = "Следуйте по записанному пути. Осталось примерно \(meters) метров."
        }
        // Background notifications are independent of SwiftUI and need iOS permission.
        if UIApplication.shared.applicationState != .active {
            if result.status == .offTrack || result.status == .arrived { notify(message) }
            return
        }
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("ru") }) else {
            if result.status == .offTrack || result.status == .arrived { notify(message) }
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
    func speakRoute(_ message: String) {
        guard UserDefaults.standard.object(forKey: "hunt.navigation.voice") as? Bool ?? true else { return }
        guard UIApplication.shared.applicationState == .active else {
            notify(message)
            return
        }
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.stopSpeaking(at: .immediate)
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
