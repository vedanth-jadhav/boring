//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject private var focus = FocusSessionManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var shelfState = ShelfStateViewModel.shared
    @Default(.codexUsageDisplay) private var codexUsageDisplay
    private var codexPreferences = CodexGlancePreferences()

    private var codexWidth: CGFloat {
        let corners = Defaults[.compactMode] ? compactCornerRadiusInsets.opened.top : cornerRadiusInsets.opened.top
        let sideWidth = (vm.notchSize.width - 24 - 2 * corners - vm.closedNotchSize.width) / 2
        let battery: CGFloat = Defaults[.showBatteryIndicator] ? (Defaults[.showBatteryPercentage] ? 72 : 34) : 0
        let settings: CGFloat = Defaults[.settingsIconInNotch] ? 34 : 0
        let mirror: CGFloat = Defaults[.showMirror] && coordinator.currentView == .home ? 34 : 0
        let activity: CGFloat = focus.isActive ? 44 : 0
        let available = max(40, sideWidth - battery - settings - mirror - activity - 6)
        return min(available, codexPreferences.width(expanded: true))
    }
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if vm.notchState == .open {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if focus.isActive {
                        FocusActivityAnchor(width: codexUsageDisplay == .off ? FocusActivityMetrics.width(for: focus.session.duration) : 36)
                            .padding(.trailing, 4)
                    }
                    if codexUsageDisplay == .pill {
                        CodexActivityAnchor(width: codexWidth).padding(.trailing, 2)
                    } else if codexUsageDisplay == .text {
                        CodexInlineUsageView(width: codexWidth) {
                            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : StandardAnimations.focusTab) {
                                coordinator.currentView = .codex
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    if isOSDType(coordinator.sneakPeekState(for: vm.screenUUID).type) && coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.showOpenNotchOSD] {
                        OpenNotchOSD(
                             type: coordinator.binding(for: vm.screenUUID).type,
                             value: coordinator.binding(for: vm.screenUUID).value,
                             icon: coordinator.binding(for: vm.screenUUID).icon,
                             accent: coordinator.binding(for: vm.screenUUID).accent
                        )
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.showMirror] && coordinator.currentView == .home {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                timeToDischarge: batteryModel.timeToDischarge,
                                maxAdapterWatts: batteryModel.maxAdapterWatts,
                                isForNotification: false
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isOSDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#if !BORING_LOCAL_BUILD
#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
#endif
