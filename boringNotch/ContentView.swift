//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var focus = FocusSessionManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject private var musicState = NotchMusicState()
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var notificationManager = SystemNotificationManager.shared
    /// Which entry of the closed-notch activity stack is on top.
    @ViewState private var activityIndex: Int = 0
    @ViewState private var hoverTask: Task<Void, Never>?
    @ViewState private var isHovering: Bool = false
    @ViewState private var anyDropDebounceTask: Task<Void, Never>?

    @ViewState private var gestureProgress: CGFloat = .zero
    @ViewState private var horizontalMediaGestureTriggered = false
    @ViewState private var horizontalMediaGestureFeedback: CGFloat = .zero
    @ViewState private var isHoveringMusicArea = false

    @ViewState private var haptics: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace var albumArtNamespace

    @Default(.cornerRadiusScaling) private var cornerRadiusScaling
    @Default(.compactMode) private var compactMode
    @Default(.showPowerStatusNotifications) private var showPowerStatusNotifications
    @Default(.enableShadow) private var enableShadow
    @Default(.enableGestures) private var enableGestures
    @Default(.closeGestureEnabled) private var closeGestureEnabled
    @Default(.enableHorizontalMediaGestures) private var enableHorizontalMediaGestures
    @Default(.boringShelf) private var boringShelf
    @Default(.inlineOSD) private var inlineOSD
    @Default(.sneakPeekStyles) private var sneakPeekStyles
    @Default(.enableHaptics) private var enableHaptics
    @Default(.openNotchOnHover) private var openNotchOnHover
    @Default(.minimumHoverDuration) private var minimumHoverDuration
    @Default(.gestureSensitivity) private var gestureSensitivity
    @Default(.showNotHumanFace) var showNotHumanFace

    // Use standardized animations from StandardAnimations enum
    private let animationSpring = StandardAnimations.interactive

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10
    private let nowPlayingFallbackNoticeWidth: CGFloat = 330
    /// Matches the popovers' dismiss delay; long enough to reach a control
    /// inside the panel without closing under the pointer.
    private let hoverExitDelayMilliseconds = 350

    private var tabTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5))
    }

    private var presentingNotifications: Bool {
        coordinator.notificationPresentation(for: vm, dragging: vm.dropInteraction.anyDropZoneTargeting) == .stack
    }

    // MARK: - Corner Radius Scaling
    private var cornerRadiusScaleFactor: CGFloat? {
        guard cornerRadiusScaling else { return nil }
        let effectiveHeight = displayClosedNotchHeight
        guard effectiveHeight > 0 else { return nil }
        return effectiveHeight / 38.0
    }

    /// Compact mode gets a rounder opened shape (35 vs 19) — at its smaller
    /// size the standard radius reads square rather than pill-like.
    private var openedInsets: (top: CGFloat, bottom: CGFloat) {
        compactMode ? compactCornerRadiusInsets.opened : cornerRadiusInsets.opened
    }

    private var topCornerRadius: CGFloat {
        // If the notch is open, return the opened radius.
        if presentingNotifications { return 12 }
        if vm.notchState == .open {
            return openedInsets.top
        }

        // For the closed notch, scale if enabled
        let baseClosedTop = cornerRadiusInsets.closed.top
        guard let scaleFactor = cornerRadiusScaleFactor else {
            return displayClosedNotchHeight > 0 ? baseClosedTop : 0
        }
        return max(0, baseClosedTop * scaleFactor)
    }

    private var currentNotchShape: NotchShape {
        // Scale bottom corner radius for closed notch shape when scaling is enabled.
        let baseClosedBottom = cornerRadiusInsets.closed.bottom
        let bottomCorner: CGFloat

        if presentingNotifications {
            bottomCorner = 24
        } else if vm.notchState == .open {
            bottomCorner = openedInsets.bottom
        } else if let scaleFactor = cornerRadiusScaleFactor {
            bottomCorner = max(0, baseClosedBottom * scaleFactor)
        } else {
            bottomCorner = displayClosedNotchHeight > 0 ? baseClosedBottom : 0
        }

        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCorner
        )
    }

    /// Music keeps its identity while notifications expand underneath it.
    /// Message queue and interaction state live in NotificationManager.
    private var liveActivities: [LiveActivityItem] {
        var items: [LiveActivityItem] = []

        // Keep music's identity and transport alive when a message emerges
        // beneath it. Notifications get their own vertically stacked surface.

        let musicIsShowing = (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && (musicState.snapshot.isPlaying || !musicState.snapshot.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
        if musicIsShowing {
            items.append(.music)
        }

        return items
    }

    /// Compact mode must use nil: this frame bounds hit-testing as well as
    /// layout, so any value shorter than the content leaves the transport
    /// row outside the hover region — moving toward the buttons registered
    /// as a hover-exit and closed the notch. The compact panel's height is
    /// controlled by its own internal padding instead, which is the honest
    /// lever anyway.
    private var openNotchHeight: CGFloat? {
        if coordinator.currentView == .timer { return focus.isActive ? 190 : 230 }
        return compactMode ? nil : vm.notchSize.height
    }

    /// Compact mode drops the tab bar along with the tabs it switches
    /// between — there's only the player to show, so a switcher would have
    /// nothing to switch to. Also what keeps the panel narrow, since the
    /// header spans the full notch width.
    private var showsHeader: Bool {
        vm.notchState == .open
            && (!compactMode || coordinator.currentView == .timer)
    }

    /// The activity currently on top of the stack — what the chin has to be
    /// sized for.
    private func selectedActivity(in items: [LiveActivityItem]) -> LiveActivityItem? {
        guard !items.isEmpty else { return nil }
        return items[min(max(activityIndex, 0), items.count - 1)]
    }

    private enum ClosedNotchContent: Equatable {
        case hello
        case nowPlayingFallback
        case batteryStatus
        case osd(SneakContentType)
        case activities([LiveActivityItem])
        case face
        case idle
    }

    private func closedNotchContent(for items: [LiveActivityItem]) -> ClosedNotchContent {
        if coordinator.helloAnimationRunning { return .hello }
        if nowPlayingFallbackNoticeActive { return .nowPlayingFallback }
        if coordinator.expandingView.show,
           coordinator.expandingView.type == .battery,
           showPowerStatusNotifications {
            return .batteryStatus
        }
        if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
            return .osd(coordinator.sneakPeekState(for: vm.screenUUID).type)
        }
        if !items.isEmpty, !vm.hideOnClosed {
            return .activities(items)
        }
        if !coordinator.expandingView.show,
           !musicState.snapshot.isPlaying,
           musicState.snapshot.isPlayerIdle,
           showNotHumanFace,
           !vm.hideOnClosed {
            return .face
        }
        return .idle
    }

    private func mainChinWidth(for items: [LiveActivityItem]) -> CGFloat {
        if presentingNotifications { return 384 }
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if shouldDisplayNowPlayingFallbackNotice {
            chinWidth = nowPlayingFallbackNoticeWidth
        } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && showPowerStatusNotifications {
            chinWidth = 640
        } else if vm.notchState == .closed, !vm.hideOnClosed, let activity = selectedActivity(in: items) {
            // Sized for whichever activity is actually on top, not for
            // whichever happens to exist — otherwise swiping to music while a
            // notification is still in the stack leaves the chin at the
            // notification's width.
            switch activity {
            case .notification:
                chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
            case .music:
                chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20 + 2 * liveActivityEdgeMargin + 2)
                // The inline song-change peek widens the pill itself, so the
                // chin has to grow with it — otherwise the hover region is
                // narrower than what's on screen.
                if showingInlineMusicPeek {
                    chinWidth += 2 * inlineMusicPeekLabelWidth
                }
            }
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicState.snapshot.isPlaying && musicState.snapshot.isPlayerIdle) && showNotHumanFace
            && !vm.hideOnClosed {
            chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    private var satelliteVisible: Bool {
        focus.isActive && !vm.hideOnClosed && displayClosedNotchHeight >= 20
    }

    private var activityCanvasWidth: CGFloat {
        min(windowSize.width, getScreenFrame(vm.screenUUID)?.width ?? windowSize.width)
    }

    private func satelliteWidth(chinWidth: CGFloat) -> CGFloat {
        let preferred: CGFloat = FocusActivityMetrics.width(for: focus.session.duration)
        let available = (activityCanvasWidth - chinWidth) / 2 - 8
        return available >= preferred ? preferred : 36
    }

    private var shouldDisplayNowPlayingFallbackNotice: Bool {
        vm.notchState == .closed && nowPlayingFallbackNoticeActive
    }

    private var nowPlayingFallbackNoticeActive: Bool {
        guard musicState.snapshot.notice != nil else { return false }

        let selectedScreen = NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
        let targetScreenUUID = selectedScreen?.displayUUID ?? NSScreen.main?.displayUUID
        let currentScreen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let isConnected = vm.screenUUID == nil || currentScreen != nil
        let isTargetDisplay = vm.screenUUID == nil || vm.screenUUID == targetScreenUUID

        return isConnected
            && isTargetDisplay
            && !isNotchHeightZero
    }

    // If the closed notch height is 0 (any display/setting), display a 10pt nearly-invisible notch
    // instead of fully hiding it. This preserves layout while avoiding visual artifacts.
    private var isNotchHeightZero: Bool { vm.effectiveClosedNotchHeight == 0 }

    private var displayClosedNotchHeight: CGFloat { isNotchHeightZero ? 10 : vm.effectiveClosedNotchHeight }

    var body: some View {
        @Bindable var dropInteraction = vm.dropInteraction
        let activities = liveActivities
        let contentKey = closedNotchContent(for: activities)
        let chinWidth = mainChinWidth(for: activities)
        let satelliteWidth = satelliteWidth(chinWidth: chinWidth)
        let computedChinWidth = chinWidth + (satelliteVisible && vm.notchState == .closed ? 2 * (satelliteWidth + 8) : 0)

        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard !reduceMotion, gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = LiquidGlassSurface(shape: currentNotchShape, expanded: vm.notchState == .open || presentingNotifications) {
                    NotchLayout(activities: activities)
                        .environmentObject(vm)
                        .environment(\.colorScheme, .dark)
                        .frame(alignment: .top)
                        .padding(.horizontal, vm.notchState == .open ? 12 : max(0, cornerRadiusInsets.closed.bottom - topCornerRadius))
                        .padding(.bottom, vm.notchState == .open ? 12 : 0)
                }
                    .frame(width: vm.notchState == .open ? (compactMode && coordinator.currentView != .timer ? 336 + 24 + 2 * openedInsets.top : vm.notchSize.width) : nil, alignment: .top)
                    .clipShape(currentNotchShape)
                    .animation(reduceMotion ? nil : StandardAnimations.interactive, value: NotificationSurfaceTransition(state: notificationManager.state, presented: presentingNotifications, expanded: isHovering))
                          .overlay(alignment: .top) {
                              displayClosedNotchHeight.isZero && vm.notchState == .closed ? nil
                        : Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    // Removed conditional bottom padding when using custom 0 notch to keep layout stable
                    .opacity((isNotchHeightZero && vm.notchState == .closed && !presentingNotifications) ? 0.01 : 1)

                mainLayout
                    .overlay(alignment: .leading) {
                        // A closed notch without music still needs a destination
                        // for the cached cover to shrink into as it fades away.
                        // This slot is layout-neutral and never draws pixels.
                        if vm.notchState == .closed {
                            let artSize = max(0, displayClosedNotchHeight - 12 * (cornerRadiusScaleFactor ?? 1))
                            Color.clear
                                .frame(width: artSize, height: artSize)
                                .anchorPreference(key: AlbumArtworkAnchorKey.self, value: .bounds) {
                                    [.hidden: $0]
                                }
                                .padding(.leading, topCornerRadius + (displayClosedNotchHeight - artSize) / 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlayPreferenceValue(AlbumArtworkAnchorKey.self) { anchors in
                        GeometryReader { geometry in
                            if let anchor = vm.notchState == .open
                                ? anchors[.open]
                                : (anchors[.closed] ?? anchors[.hidden]) {
                                NotchAlbumArtwork(
                                    rect: geometry[anchor],
                                    expanded: vm.notchState == .open,
                                    cornerRadius: vm.notchState == .open
                                        ? (compactMode ? 10 : MusicPlayerImageSizes.cornerRadiusInset.opened)
                                        : MusicPlayerImageSizes.cornerRadiusInset.closed * (cornerRadiusScaleFactor ?? 1),
                                    visible: vm.notchState == .open || anchors[.closed] != nil
                                )
                                .transition(.opacity.animation(reduceMotion ? nil : StandardAnimations.contentDismiss))
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if vm.notchState == .open, notificationManager.activeNotification != nil {
                            Button { notificationManager.showRecent(); vm.close() } label: {
                                Label("\(notificationManager.state.notifications.count)", systemImage: "bell.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(.black.opacity(0.8), in: Capsule())
                            }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                            .accessibilityLabel("Show queued notifications")
                            .padding(.trailing, 18).padding(.bottom, 8)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if satelliteVisible && vm.notchState == .closed {
                            FocusActivityAnchor(width: satelliteWidth, height: max(26, displayClosedNotchHeight - 4))
                                .offset(x: satelliteWidth + 8)
                        }
                    }
                    // Keep the visible surface anchored to the display top
                    // as workspace or notification content changes height.
                    .frame(height: vm.notchState == .open ? openNotchHeight : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        return view
                            .animation(reduceMotion ? nil : .smooth, value: gestureProgress)
                            // Outermost on purpose: it only fires when the
                            // closed-state content changes (the key is stable
                            // across open/close), and when several keys change
                            // at once the innermost animation wins, so the
                            // open/close springs below keep precedence.
                            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: contentKey)

                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice && !presentingNotifications {
                            doOpen()
                        }
                    }
                    .conditionalModifier(enableGestures && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(closeGestureEnabled && enableGestures && coordinator.currentView != .timer && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(enableHorizontalMediaGestures && enableGestures && (vm.notchState == .closed || coordinator.currentView != .timer) && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .left) { translation, phase in
                                handleNextTrackGesture(translation: translation, phase: phase)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handlePreviousTrackGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    // Keep the retained music activity selection in range.
                    .onChange(of: notificationManager.activeNotification?.id) { _, newID in
                        if newID != nil { activityIndex = 0 }
                    }
                    // Music may disappear independently of the message queue.
                    .onChange(of: activities.count) { _, count in
                        if activityIndex >= count { activityIndex = max(count - 1, 0) }
                    }
                    .onChange(of: vm.isPopoverActive) { _, _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Color.clear
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: activityCanvasWidth, maxHeight: windowSize.height, alignment: .top)
        .overlayPreferenceValue(FocusActivityAnchorKey.self) { anchor in
            GeometryReader { geometry in
                if focus.isActive, let anchor {
                    let rect = geometry[anchor]
                    FocusActivityView(width: rect.width, height: rect.height, expanded: vm.notchState == .open) {
                        coordinator.currentView = .timer
                        doOpen()
                    }
                    .onHover { handleHover($0) }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        // One transaction drives the main surface and the persistent activity.
        .animation(reduceMotion ? nil : (vm.notchState == .open ? StandardAnimations.open : StandardAnimations.close), value: vm.notchState)
        .animation(reduceMotion ? nil : StandardAnimations.interactive, value: chinWidth)
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: coordinator.currentView)
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: focus.isActive)
        .ignoresSafeArea(.all)
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(reduceMotion ? nil : .smooth, value: gestureProgress)
        .background(dragDetector)
        .environmentObject(vm)
        .onChange(of: vm.notchState) { _, _ in gestureProgress = .zero }
        .onChange(of: coordinator.currentView) { _, _ in gestureProgress = .zero }
        .onChange(of: dropInteraction.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if boringShelf && vm.notchState == .closed {
                    if doOpen() {
                        coordinator.currentView = .shelf
                    }
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if dropInteraction.dropEvent {
                    dropInteraction.dropEvent = false
                    return
                }

                dropInteraction.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout(activities: [LiveActivityItem]) -> some View {
        @Bindable var dropInteraction = vm.dropInteraction

        VStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if shouldDisplayNowPlayingFallbackNotice,
                       let notice = musicState.snapshot.notice {
                        nowPlayingFallbackNotice(notice)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && showPowerStatusNotifications {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    maxAdapterWatts: batteryModel.maxAdapterWatts,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: displayClosedNotchHeight, alignment: .center)
                        } else if coordinator.shouldShowSneakPeek(on: vm.screenUUID) && inlineOSD && (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .battery) && vm.notchState == .closed {
                           InlineOSD(
                              type: coordinator.binding(for: vm.screenUUID).type,
                              value: coordinator.binding(for: vm.screenUUID).value,
                              icon: coordinator.binding(for: vm.screenUUID).icon,
                              accent: coordinator.binding(for: vm.screenUUID).accent,
                              hoverAnimation: $isHovering,
                              gestureProgress: $gestureProgress
                          )
                              .transition(.opacity)
                      } else if !activities.isEmpty && vm.notchState == .closed && !vm.hideOnClosed {
                          LiveActivityStack(items: activities, index: $activityIndex) { item in
                              switch item {
                              case .notification(let notification):
                                  NotificationLiveActivity(notification: notification)
                              case .music:
                                  NotchMusicActivityView(height: displayClosedNotchHeight, cornerScale: cornerRadiusScaleFactor,
                                      centerWidth: musicActivityCenterWidth, closedWidth: vm.closedNotchSize.width,
                                      gesture: gestureProgress, albumArtNamespace: albumArtNamespace)
                                      .frame(alignment: .center)
                              }
                          }
                      } else if !presentingNotifications && !coordinator.expandingView.show && vm.notchState == .closed && (!musicState.snapshot.isPlaying && musicState.snapshot.isPlayerIdle) && showNotHumanFace && !vm.hideOnClosed {
                          BoringFaceAnimation()
                       } else if showsHeader {
                           // No tab bar over a notification: it's a glance,
                           // not a place to switch between home and shelf —
                           // and the header spans the full notch width,
                           // which is what was stretching the whole panel
                           // out around a short message.
                           BoringHeader()
                               .frame(height: max(38, displayClosedNotchHeight))
                       } else if vm.notchState == .open && focus.isActive && compactMode {
                           HStack {
                               Button("Timer", systemImage: "timer") { coordinator.currentView = .timer }
                                   .buttonStyle(.plain).font(.caption)
                               Spacer()
                               FocusActivityAnchor(width: FocusActivityMetrics.width(for: focus.session.duration))
                           }
                           .frame(width: 336, height: 30)
                       }
                        // New case to enable compact notch on external displays
                        else if !vm.hasNotch {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: 11) // idle notch height is halved on non notch display
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: displayClosedNotchHeight)
                       }

                        if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                           if (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .battery) && !inlineOSD && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: coordinator.binding(for: vm.screenUUID).type,
                                  value: coordinator.binding(for: vm.screenUUID).value,
                                  icon: coordinator.binding(for: vm.screenUUID).icon,
                                  accent: coordinator.binding(for: vm.screenUUID).accent,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeekState(for: vm.screenUUID).type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                           // Old sneak peek music
                           else if coordinator.sneakPeekState(for: vm.screenUUID).type == .music {
                               if vm.notchState == .closed && !vm.hideOnClosed && sneakPeekStyles == .standard {
                                   HStack(alignment: .center) {
                                       Image(systemName: "music.note")
                                       GeometryReader { geo in
                                           NotchMusicPeekLabel(width: geo.size.width)
                                       }
                                   }
                                   .foregroundStyle(.gray)
                                   .padding(.bottom, 10)
                               }
                           }
                       }
                        }
                      }
                      .conditionalModifier((coordinator.shouldShowSneakPeek(on: vm.screenUUID) && (coordinator.sneakPeekState(for: vm.screenUUID).type == .music) && vm.notchState == .closed && !vm.hideOnClosed && sneakPeekStyles == .standard) || (coordinator.shouldShowSneakPeek(on: vm.screenUUID) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (vm.notchState == .closed))) { view in
                          view
                              .fixedSize()
                      }
                      .zIndex(1)
            if presentingNotifications {
                NotificationQueueView(manager: notificationManager, musicIsPlaying: musicState.snapshot.isPlaying, expanded: isHovering)
                    .transition(.asymmetric(insertion: .offset(y: -12).combined(with: .opacity), removal: .opacity))
            }
            if vm.notchState == .open {
                VStack {
                    // An explicitly opened workspace retains its own content.
                    // Pending notifications emerge after the workspace closes.
                    if compactMode && coordinator.currentView != .timer {
                        // Player only — no tab switching, so currentView is
                        // ignored here rather than offering a shelf the
                        // compact layout has no room (or tab bar) for.
                        // 336 = Atoll's 420 base less 20%, which also lands
                        // within a few points of their Dynamic Island width
                        // (340) — the tighter of their two compact sizes.
                        CompactHomeView(
                            albumArtNamespace: albumArtNamespace,
                            horizontalMediaGestureFeedback: horizontalMediaGestureFeedback
                        )
                        .frame(width: 336)
                        .onHover { hovering in
                            isHoveringMusicArea = hovering
                        }
                        .onDisappear {
                            isHoveringMusicArea = false
                        }
                    } else {
                        switch coordinator.currentView {
                        case .home:
                            NotchHomeView(
                                albumArtNamespace: albumArtNamespace,
                                horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                                isHoveringMusicArea: $isHoveringMusicArea
                            )
                            .transition(tabTransition)
                        case .timer:
                            FocusTimerView()
                                .transition(tabTransition)
                        case .shelf:
                            ShelfView(
                                dropInteraction: vm.dropInteraction,
                                animation: vm.animation
                            )
                            .transition(tabTransition)
                        }
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .animation(reduceMotion ? nil : StandardAnimations.contentSettle),
                        removal: .opacity
                            .animation(reduceMotion ? nil : StandardAnimations.contentDismiss)
                    )
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $dropInteraction.generalDropTargeting))
    }

    private func nowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(notice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(2)

            Spacer(minLength: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: nowPlayingFallbackNoticeWidth)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .onAppear {
            if MusicManager.shared.markNowPlayingNoticePresented(notice.id) {
                announceNowPlayingFallbackNotice(notice)
            }
        }
    }

    private func announceNowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) {
        let announcement = "\(String(localized: notice.title)). \(String(localized: notice.subtitle))."
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 20)
            let faceScale = min(1.0, displayClosedNotchHeight / 30.0)
            AnimatedFace(height: 24.0 * faceScale, width: 30.0 * faceScale)
        }.frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

    /// True while the song-change peek is expanding the closed pill inline.
    private var showingInlineMusicPeek: Bool {
        coordinator.expandingView.show
            && coordinator.expandingView.type == .music
            && sneakPeekStyles == .inline
    }

    /// Width of the black centre section of the closed music pill.
    ///
    /// Derived from the real notch width rather than the previous hard-coded
    /// 380. That constant assumed a particular notch size: the title sits
    /// left of the cutout and the artist right of it, separated by a spacer
    /// as wide as the notch itself, so on a wider notch there was no room
    /// left for the artist and the labels collided. Sizing from
    /// closedNotchSize keeps a fixed label budget either side whatever the
    /// hardware is, and keeps liveActivityEdgeMargin in play so content
    /// clears the bezel — the inline path had dropped it entirely.
    private var musicActivityCenterWidth: CGFloat {
        let margin = vm.closedNotchSize.width - 4 + (2 * liveActivityEdgeMargin)
        guard showingInlineMusicPeek else { return margin }
        return margin + (2 * inlineMusicPeekLabelWidth)
    }

    /// Space reserved for the title (left of the cutout) and artist (right).
    private let inlineMusicPeekLabelWidth: CGFloat = 110

    @ViewBuilder
    var dragDetector: some View {
        @Bindable var dropInteraction = vm.dropInteraction

        if boringShelf && vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $dropInteraction.dragDetectorTargeting) { providers in
            dropInteraction.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

}
// MARK: - Gesture & Hover Handling

extension ContentView {
    @discardableResult
    private func doOpen() -> Bool {
        var didOpen = false
        withAnimation(animationSpring) {
            didOpen = vm.open()
        }
        return didOpen
    }

    // MARK: - Hover Management

    /// Closes the open notch after the hover grace period unless a popover
    /// still owns the pointer.
    private func scheduleCloseIfNotHovering(overNotch notchViewModel: BoringViewModel) {
        guard notchViewModel.notchState == .open,
              !isHovering,
              !notchViewModel.isPopoverActive else { return }
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(hoverExitDelayMilliseconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.vm.notchState == .open,
                   !self.isHovering,
                   !self.vm.isPopoverActive,
                   !SharingStateManager.shared.preventNotchClose {
                    self.vm.close()
                }
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            // Freeze the dismiss countdown the moment the pointer arrives,
            // not when the notch finishes opening. Opening waits out
            // minimumHoverDuration plus an animation, and a notification
            // near the end of its life would expire during that — so it
            // vanished exactly as the notch opened around it.
            if notificationManager.activeNotification != nil {
                notificationManager.holdActive()
            }

            if vm.notchState == .closed && enableHaptics {
                haptics.toggle()
            }

            guard vm.notchState == .closed,
                  !presentingNotifications,
                  !shouldDisplayNowPlayingFallbackNotice,
                  !coordinator.shouldShowSneakPeek(on: vm.screenUUID),
                  openNotchOnHover else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(minimumHoverDuration))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.shouldDisplayNowPlayingFallbackNotice,
                          !self.coordinator.shouldShowSneakPeek(on: self.vm.screenUUID) else { return }

                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(hoverExitDelayMilliseconds))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }

                    // Pointer left — let the notification age out again.
                    self.notificationManager.resumeDismiss()

                    if self.vm.notchState == .open,
                       !self.vm.isPopoverActive,
                       !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .ended || phase == .cancelled {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard vm.notchState == .closed else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / gestureSensitivity) * 20
        }

        if translation > gestureSensitivity {
            if enableHaptics {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .ended || phase == .cancelled {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / gestureSensitivity) * -20
        }

        if translation > gestureSensitivity {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose {
                gestureProgress = .zero
                vm.close()
            }

            if enableHaptics {
                haptics.toggle()
            }
        }
    }

    private func handleNextTrackGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleHorizontalMediaGesture(translation: translation, phase: phase, feedback: -1) {
            MusicManager.shared.nextTrack()
        }
    }

    private func handlePreviousTrackGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleHorizontalMediaGesture(translation: translation, phase: phase, feedback: 1) {
            MusicManager.shared.previousTrack()
        }
    }

    private func handleHorizontalMediaGesture(
        translation: CGFloat,
        phase: NSEvent.Phase,
        feedback: CGFloat,
        action: () -> Void
    ) {
        guard isHorizontalMediaGestureContext else {
            resetHorizontalMediaGesture()
            return
        }
        guard phase != .ended else {
            resetHorizontalMediaGesture()
            return
        }
        guard !horizontalMediaGestureTriggered else { return }
        guard translation > gestureSensitivity else { return }

        horizontalMediaGestureTriggered = true
        triggerHorizontalMediaFeedback(feedback)
        action()

        if enableHaptics {
            haptics.toggle()
        }
    }

    private func resetHorizontalMediaGesture() {
        horizontalMediaGestureTriggered = false
    }

    private func triggerHorizontalMediaFeedback(_ feedback: CGFloat) {
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.62)) {
            horizontalMediaGestureFeedback = feedback
            if vm.notchState == .closed {
                gestureProgress = 2
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(animationSpring) {
                horizontalMediaGestureFeedback = .zero
                if vm.notchState == .closed {
                    gestureProgress = .zero
                }
            }
        }
    }

    private var isHorizontalMediaGestureContext: Bool {
        guard !presentingNotifications else { return false }
        switch vm.notchState {
        case .closed:
            guard !vm.hideOnClosed else { return false }

            if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                return coordinator.sneakPeekState(for: vm.screenUUID).type == .music
            }

            guard !coordinator.expandingView.show || coordinator.expandingView.type == .music else {
                return false
            }

            return coordinator.musicLiveActivityEnabled && (musicState.snapshot.isPlaying || !musicState.snapshot.isPlayerIdle)

        case .open:
            if compactMode {
                return !musicState.snapshot.isPlayerIdle && isHoveringMusicArea
            }
            return coordinator.currentView == .home && !musicState.snapshot.isPlayerIdle && isHoveringMusicArea
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }
}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#if !BORING_LOCAL_BUILD
#Preview {
    let vm = BoringViewModel(camera: CameraModel())
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
#endif
