import AVFAudio
import UIKit

@MainActor
final class CameraGuidanceAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private var pendingAnnouncement: Task<Void, Never>?
    private var pendingMessage: String?
    private var lastAnnouncedMessage: String?
    private var lastAnnouncementTime = Date.distantPast
    private var isFirstAnnouncement = true

    // VoiceOver needs a moment after navigation. Later updates are spaced out
    // so a new camera frame does not interrupt every instruction.
    private let firstAnnouncementDelay: TimeInterval = 0.7
    private let announcementInterval: TimeInterval = 0.9

    func announce(_ message: String) {
        guard !message.isEmpty else { return }

        pendingMessage = message
        guard pendingAnnouncement == nil else { return }
        guard message != lastAnnouncedMessage else {
            pendingMessage = nil
            return
        }

        let delay = isFirstAnnouncement
            ? firstAnnouncementDelay
            : max(0, announcementInterval - Date().timeIntervalSince(lastAnnouncementTime))

        pendingAnnouncement = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }

            self.pendingAnnouncement = nil
            guard let message = self.pendingMessage,
                  message != self.lastAnnouncedMessage else {
                self.pendingMessage = nil
                return
            }

            self.pendingMessage = nil
            self.lastAnnouncedMessage = message
            self.lastAnnouncementTime = Date()
            self.isFirstAnnouncement = false

            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: message)
            } else {
                self.synthesizer.stopSpeaking(at: .immediate)
                let utterance = AVSpeechUtterance(string: message)
                utterance.voice = AVSpeechSynthesisVoice(language: "id-ID")
                self.synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        pendingMessage = nil
        lastAnnouncedMessage = nil
        lastAnnouncementTime = .distantPast
        isFirstAnnouncement = true
        synthesizer.stopSpeaking(at: .immediate)
    }
}
