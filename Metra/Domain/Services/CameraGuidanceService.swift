import Foundation
import CoreGraphics

@MainActor
final class CameraGuidanceService {
    private var lastGeometry: DocumentGeometry?
    private var stableSince: Date?
    private var lastDetectedAt: Date?
    private var lastState: CameraGuidanceState?

    private let requiredStableDuration: TimeInterval = 0.45
    private let detectionGracePeriod: TimeInterval = 0.45
    private let centerMovementTolerance: CGFloat = 0.05
    private let coverageMovementTolerance: CGFloat = 0.08
    private let tiltMovementTolerance: CGFloat = 0.1

    func evaluate(_ geometry: DocumentGeometry?, now: Date = Date()) -> CameraGuidanceState {
        guard let geometry else {
            if let lastDetectedAt, let lastState,
               now.timeIntervalSince(lastDetectedAt) < detectionGracePeriod {
                return lastState
            }
            reset()
            return .searching
        }

        lastDetectedAt = now
        let direction = direction(for: geometry)
        guard direction == .holdStill else {
            stableSince = nil
            lastGeometry = geometry
            lastState = direction
            return direction
        }

        if let previous = lastGeometry {
            let centerMovement = hypot(
                geometry.center.x - previous.center.x,
                geometry.center.y - previous.center.y
            )
            let coverageMovement = abs(geometry.coverage - previous.coverage)
            let tiltMovement = abs(geometry.tilt - previous.tilt)

            if centerMovement > centerMovementTolerance ||
                coverageMovement > coverageMovementTolerance ||
                tiltMovement > tiltMovementTolerance {
                stableSince = now
            }
        } else {
            stableSince = now
        }

        lastGeometry = geometry
        guard let stableSince,
              now.timeIntervalSince(stableSince) >= requiredStableDuration else {
            lastState = .holdStill
            return .holdStill
        }
        lastState = .ready
        return .ready
    }

    func reset() {
        lastGeometry = nil
        stableSince = nil
        lastDetectedAt = nil
        lastState = nil
    }

    private func direction(for geometry: DocumentGeometry) -> CameraGuidanceState {
        if geometry.coverage < 0.10 { return .moveCloser }
        if geometry.coverage > 0.92 { return .moveFarther }
        if geometry.tilt > 0.3 { return .straighten }
        if geometry.horizontalOffset < -0.18 { return .moveLeft }
        if geometry.horizontalOffset > 0.18 { return .moveRight }
        if geometry.verticalOffset < -0.18 { return .moveDown }
        if geometry.verticalOffset > 0.18 { return .moveUp }
        return .holdStill
    }
}
