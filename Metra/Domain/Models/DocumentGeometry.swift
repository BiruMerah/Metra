import CoreGraphics

struct DocumentGeometry: Sendable {
    let center: CGPoint
    let coverage: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let tilt: CGFloat
}
