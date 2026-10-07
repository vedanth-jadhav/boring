import SwiftUI

struct CodexAllowanceTrack: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = 24
        let gap: CGFloat = 2
        let width = max(0, (rect.width - CGFloat(count - 1) * gap) / CGFloat(count))
        let remaining = rect.width * max(0, min(1, fraction))
        var path = Path()
        for index in 0..<count {
            let x = CGFloat(index) * (width + gap)
            let fill = min(width, max(0, remaining - x))
            if fill > 0 {
                path.addRoundedRect(in: CGRect(x: rect.minX + x, y: rect.minY, width: fill, height: rect.height),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
        }
        return path
    }
}
