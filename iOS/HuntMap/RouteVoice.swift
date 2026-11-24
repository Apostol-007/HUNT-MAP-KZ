import SwiftUI
import AVFoundation

@MainActor final class RouteVoice: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastKey = ""
    func announce(instruction: String, distance: Double, maneuver: Int) {
        guard !instruction.isEmpty, distance.isFinite, distance >= 0, distance <= 300 else { return }
        let threshold = distance <= 30 ? 30 : distance <= 100 ? 100 : 300
        let key = "\(maneuver)|\(threshold)|\(instruction)"
        guard key != lastKey else { return }
        lastKey = key
        let utterance = AVSpeechUtterance(string: distance <= 30 ? instruction : "Через \(Int(distance.rounded())) метров. \(instruction)")
        if let voice = AVSpeechSynthesisVoice(language: "ru-RU") { utterance.voice = voice }
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        lastKey = ""
    }
}
