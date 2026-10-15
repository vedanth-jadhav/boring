import SwiftUI

/// A scalloped terminal mark that remains crisp at tab and stats sizes.
struct CodexLogo: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 100
            Path { path in
                path.move(to: CGPoint(x: 26, y: 20))
                path.addCurve(to: CGPoint(x: 69, y: 10), control1: CGPoint(x: 30, y: -3), control2: CGPoint(x: 56, y: -7))
                path.addCurve(to: CGPoint(x: 98, y: 40), control1: CGPoint(x: 91, y: 2), control2: CGPoint(x: 104, y: 20))
                path.addCurve(to: CGPoint(x: 87, y: 81), control1: CGPoint(x: 118, y: 60), control2: CGPoint(x: 105, y: 79))
                path.addCurve(to: CGPoint(x: 43, y: 91), control1: CGPoint(x: 80, y: 106), control2: CGPoint(x: 57, y: 111))
                path.addCurve(to: CGPoint(x: 12, y: 62), control1: CGPoint(x: 20, y: 100), control2: CGPoint(x: 4, y: 83))
                path.addCurve(to: CGPoint(x: 26, y: 20), control1: CGPoint(x: -10, y: 42), control2: CGPoint(x: 4, y: 23))
                path.closeSubpath()
                var chevron = Path()
                chevron.move(to: CGPoint(x: 30.67, y: 39.22))
                chevron.addLine(to: CGPoint(x: 39.05, y: 51.79))
                chevron.addLine(to: CGPoint(x: 29.95, y: 62.42))
                chevron.addCurve(to: CGPoint(x: 36.05, y: 67.58), control1: CGPoint(x: 26.55, y: 66.46), control2: CGPoint(x: 32.66, y: 71.63))
                chevron.addLine(to: CGPoint(x: 47.05, y: 54.58))
                chevron.addCurve(to: CGPoint(x: 47.33, y: 49.78), control1: CGPoint(x: 48.35, y: 53.05), control2: CGPoint(x: 48.45, y: 51.46))
                chevron.addLine(to: CGPoint(x: 37.33, y: 34.78))
                chevron.addCurve(to: CGPoint(x: 30.67, y: 39.22), control1: CGPoint(x: 35.49, y: 32.02), control2: CGPoint(x: 28.83, y: 36.46))
                chevron.closeSubpath()
                path.addPath(chevron)
                path.addRoundedRect(in: CGRect(x: 54, y: 61, width: 29, height: 8), cornerSize: CGSize(width: 4, height: 4))
            }
            .transform(CGAffineTransform(scaleX: scale * 0.88, y: scale * 0.88).translatedBy(x: 5, y: 5))
            .fill(style: FillStyle(eoFill: true))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
