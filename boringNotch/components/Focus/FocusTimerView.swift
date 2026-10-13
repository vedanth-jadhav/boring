import SwiftUI

struct FocusTimerView: View {
    @ObservedObject private var manager = FocusSessionManager.shared
    @ObservedObject private var selection = FocusSessionManager.shared.selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modeNamespace

    private var showsSetup: Bool {
        selection.needsCaffeineSetup(isActive: manager.isActive)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(FocusSessionMode.allCases) { mode in
                    Button { selectMode(mode) } label: {
                        Text(mode.title).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selection.mode == mode ? .orange : .white.opacity(0.65))
                            .padding(.horizontal, 14).frame(height: 25)
                            .background {
                                if selection.mode == mode {
                                    Capsule().fill(.orange.opacity(0.15)).matchedGeometryEffect(id: "mode", in: modeNamespace)
                                }
                            }
                    }
                    .disabled(manager.isActive || manager.isBusy)
                    .accessibilityAddTraits(selection.mode == mode ? .isSelected : [])
                }
            }
            .padding(3).modifier(FocusControlSurface())
            if showsSetup {
                CaffeineSetupView().transition(.opacity)
            } else if manager.isActive {
                FocusActiveSessionView(editApps: editApps).transition(.opacity)
            } else {
                FocusDurationPicker(editApps: editApps).transition(.opacity)
            }
            if let error = manager.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 500, alignment: .leading)
            }
        }
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: manager.isActive)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: showsSetup)
        .buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 4)
        .frame(maxWidth: .infinity).foregroundStyle(.white)
    }

    private func editApps() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) {
            selection.caffeineSettingsOpen = true
        }
        FocusHaptics.action()
    }
    private func selectMode(_ mode: FocusSessionMode) {
        guard selection.mode != mode else { return }
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.94)) {
            selection.mode = mode
            if mode == .caffeine { selection.caffeineReady = false }
            selection.caffeineSettingsOpen = false
        }
        FocusHaptics.action()
    }
}
