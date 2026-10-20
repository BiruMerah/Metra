import UIKit

@MainActor
final class CameraGuidanceAnnouncer {
    private var pendingAnnouncement: Task<Void, Never>?
    private var pendingMessage: String?
    private var lastAnnouncedMessage: String?
    private var lastAnnouncementTime = Date.distantPast
    // Space out changing camera instructions so VoiceOver can finish reading.
    private let announcementInterval: TimeInterval = 0.9

    func announce(_ message: String, force: Bool = false) {
        guard UIAccessibility.isVoiceOverRunning, !message.isEmpty else { return }

        pendingMessage = message
        guard pendingAnnouncement == nil else { return }
        guard force || message != lastAnnouncedMessage else {
            pendingMessage = nil
            return
        }

        let delay = force ? 0 : max(
            0,
            announcementInterval - Date().timeIntervalSince(lastAnnouncementTime)
        )

        pendingAnnouncement = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }

            self.pendingAnnouncement = nil
            guard let message = self.pendingMessage else {
                self.pendingMessage = nil
                return
            }

            self.pendingMessage = nil
            self.lastAnnouncedMessage = message
            self.lastAnnouncementTime = Date()
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    func stop() {
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        pendingMessage = nil
        lastAnnouncedMessage = nil
        lastAnnouncementTime = .distantPast
    }
}
