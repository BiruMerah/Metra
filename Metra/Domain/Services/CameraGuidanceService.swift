import Foundation
import CoreGraphics

@MainActor
final class CameraGuidanceService {
    private var lastGeometry: DocumentGeometry?
    private var stableSince: Date?

    private let requiredStableDuration: TimeInterval = 0.65
    private let movementTolerance: CGFloat = 0.015

    func evaluate(_ geometry: DocumentGeometry?, now: Date = Date()) -> CameraGuidanceState {
        guard let geometry else {
            reset()
            return .searching
        }

        let direction = direction(for: geometry)
        guard direction == .holdStill else {
            stableSince = nil
            lastGeometry = geometry
            return direction
        }

        if let previous = lastGeometry {
            let centerMovement = hypot(
                geometry.center.x - previous.center.x,
                geometry.center.y - previous.center.y
            )
            let coverageMovement = abs(geometry.coverage - previous.coverage)
            let tiltMovement = abs(geometry.tilt - previous.tilt)

            if centerMovement > movementTolerance ||
                coverageMovement > movementTolerance ||
                tiltMovement > movementTolerance {
                stableSince = now
            }
        } else {
            stableSince = now
        }

        lastGeometry = geometry
        guard let stableSince,
              now.timeIntervalSince(stableSince) >= requiredStableDuration else {
            return .holdStill
        }
        return .ready
    }

    func reset() {
        lastGeometry = nil
        stableSince = nil
    }

    private func direction(for geometry: DocumentGeometry) -> CameraGuidanceState {
        if geometry.coverage < 0.20 { return .moveCloser }
        if geometry.coverage > 0.88 { return .moveFarther }
        if geometry.tilt > 0.18 { return .straighten }
        if geometry.horizontalOffset < -0.12 { return .moveLeft }
        if geometry.horizontalOffset > 0.12 { return .moveRight }
        if geometry.verticalOffset < -0.12 { return .moveDown }
        if geometry.verticalOffset > 0.12 { return .moveUp }
        return .holdStill
    }
}
