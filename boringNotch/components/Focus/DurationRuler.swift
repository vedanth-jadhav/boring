import SwiftUI
import SwiftUIIntrospect

struct DurationRuler: View {
    @Binding var minutes: Int
    @ViewState private var position: Int?
    @ViewState private var lastDetent = Date.distantPast
    @ViewState private var mouseDrag = RulerMouseDrag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tickSpacing: CGFloat = 8

    init(minutes: Binding<Int>) {
        _minutes = minutes
        _position = ViewState(initialValue: nil)
    }

    var body: some View {
        // One viewport measurement; visualEffect runs tick fades in SwiftUI's
        // render pipeline without publishing per-tick geometry into view state.
        GeometryReader { viewport in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 0) {
                    ForEach(1...120, id: \.self) { minute in
                        DurationRulerTick(minute: minute, spacing: tickSpacing)
                            .visualEffect { effect, geometry in
                                let distance = abs(geometry.frame(in: .scrollView(axis: .horizontal)).midX - viewport.size.width / 2)
                                let proximity = max(0, 1 - distance / (viewport.size.width / 2))
                                return effect
                                    .opacity(0.2 + 0.8 * proximity)
                                    .scaleEffect(x: 0.96 + 0.04 * proximity, y: 0.94 + 0.06 * proximity, anchor: .bottom)
                            }
                            .id(minute)
                    }
                }
                .frame(height: 54)
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(0, (viewport.size.width - tickSpacing) / 2), for: .scrollContent)
            .scrollIndicators(.hidden)
            .modifier(CenteredRulerSnapping())
            .scrollPosition(id: $position, anchor: .center)
            .introspect(.scrollView, on: .macOS(.v14...)) { scrollView in
                mouseDrag.scrollView = scrollView
                scrollView.hasHorizontalScroller = false
                scrollView.hasVerticalScroller = false
                scrollView.drawsBackground = false

            }
            .simultaneousGesture(DragGesture(minimumDistance: 1)
                .onChanged {
                    if let minute = mouseDrag.move(translation: $0.translation.width, tickSpacing: tickSpacing) {
                        minutes = minute
                    }
                }
                .onEnded { _ in
                    guard let minute = mouseDrag.end(tickSpacing: tickSpacing) else { return }
                    withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.94)) {
                        position = minute
                    }
                })
            .overlay(alignment: .bottom) {
                VStack(spacing: 3) {
                    Capsule().fill(.orange).frame(width: 2, height: 26)
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 5)).rotationEffect(.degrees(180))
                        .foregroundStyle(.orange)
                }
                .allowsHitTesting(false)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 54)
        .onChange(of: position) { _, minute in
            guard let minute, minutes != minute else { return }
            minutes = minute
        }
        .onChange(of: minutes) { _, _ in
            let minute = minutes
            let now = Date()
            guard now.timeIntervalSince(lastDetent) >= 0.07 else { return }
            lastDetent = now
            FocusHaptics.detent(major: [1, 5, 10, 30, 60, 120].contains(minute))
        }
        .task { position = minutes }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Duration")
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = min(120, minutes + 1)
            case .decrement: position = max(1, minutes - 1)
            @unknown default: break
            }
        }
    }
}
