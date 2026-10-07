import Combine
import Foundation

@MainActor
final class CursorShelfModel: ObservableObject {
    @Published var branch: ShelfTool?
    @Published var selected: ShelfTool?
    @Published var count = 1
    var fileURLs: [URL] = []
    var tools: [ShelfTool] { branch?.children.filter { $0.supports(fileURLs) } ?? ShelfTool.primary }
    var radius: CGFloat { tools.count > 5 ? 148 : 128 }

    func point(for index: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(tools.count)
        return CGPoint(x: 210 + cos(angle) * radius, y: 210 + sin(angle) * radius)
    }

    func tool(at point: CGPoint) -> ShelfTool? {
        for (index, tool) in tools.enumerated() {
            let center = self.point(for: index)
            if abs(point.x - center.x) <= 43, abs(point.y - center.y) <= 34, tool.supports(fileURLs) { return tool }
        }
        return nil
    }
}
