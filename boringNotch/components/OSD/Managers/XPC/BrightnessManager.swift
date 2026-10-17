//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var animatedBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	/// Key repeats arriving while an XPC call is in flight accumulate here so
	/// no press is lost — each press used to trigger its own 3-RPC sequence
	/// (adjust + read + display lookup), and they would queue behind each other.
	private var pendingDelta: Float = 0
	private var pendingTarget: Float?
	private var flushTask: Task<Void, Never>?
	private var changeGeneration = 0

	/// The brightness target display only changes with the display set.
	private var cachedTargetUUID: String?
	private var screenParametersObserver: (any NSObjectProtocol)?

	private init() {
		refresh()
		screenParametersObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.cachedTargetUUID = nil
		}
	}

	/// Determine which screen UUID should be used for brightness OSDs
	/// when the built‑in source is selected.  This mirrors the logic in the
	/// XPC helper, which chooses the menu-bar display if it supports brightness and
	/// otherwise falls back to an internal panel.
	/// Cached; invalidated when the display configuration changes.
	func brightnessTargetUUID() async -> String? {
		if let cachedTargetUUID { return cachedTargetUUID }
		var resolved: String?
		if let displayID = await client.displayIDForBrightness() {
			resolved = NSScreen.screens.first(where: { $0.cgDisplayID == displayID })?.displayUUID
		}
		resolved = resolved ?? NSScreen.main?.displayUUID
		cachedTargetUUID = resolved
		return resolved
	}

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			guard flushTask == nil else { return }
			let generation = changeGeneration
			if let current = await client.currentScreenBrightness(),
			   flushTask == nil, generation == changeGeneration {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		changeGeneration += 1
		if let target = pendingTarget {
			pendingTarget = max(0, min(1, target + delta))
		} else {
			pendingDelta += delta
		}
		flushPendingChanges()
	}

	@MainActor func setAbsolute(value: Float) {
		changeGeneration += 1
		let clamped = max(0, min(1, value))
		pendingTarget = clamped
		pendingDelta = 0
		publish(brightness: clamped, touchDate: true)
		flushPendingChanges()
	}

	@MainActor private func flushPendingChanges() {
		guard flushTask == nil else { return }
		flushTask = Task { @MainActor in
			var needsRefresh = false
			defer {
				flushTask = nil
				if needsRefresh { refresh() }
			}
			while pendingTarget != nil || pendingDelta != 0 {
				// Bound slider writes to 15 Hz and retain the final target.
				try? await Task.sleep(for: .milliseconds(67))
				let target = pendingTarget
				let delta = pendingDelta
				pendingTarget = nil
				pendingDelta = 0
				let current: Float?
				if let target {
					current = await client.setScreenBrightness(target) ? target : nil
				} else {
					current = await client.adjustScreenBrightness(by: delta)
				}
				guard pendingTarget == nil, pendingDelta == 0 else { continue }
				if let current {
					needsRefresh = false
					publish(brightness: current, touchDate: true)
					let uuid = await brightnessTargetUUID()
					guard pendingTarget == nil, pendingDelta == 0 else { continue }
					NotchUIEventBus.events.send(.sneakPeek(type: .brightness, value: CGFloat(current), targetScreenUUID: uuid))
				} else {
					needsRefresh = true
				}
			}
		}
	}

	@MainActor private func publish(brightness: Float, touchDate: Bool) {
		if rawBrightness != brightness || touchDate {
			if touchDate { lastChangeAt = Date() }
			rawBrightness = brightness
			animatedBrightness = brightness
		}
	}
}

// (DisplayServices helpers moved into XPC helper)

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	/// Deltas accumulate while a read or set call is in flight so key repeats
	/// are coalesced into the next adjustment.
	private var pendingDelta: Float = 0
	private var flushTask: Task<Void, Never>?

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		pendingDelta += delta
		guard flushTask == nil else { return }
		flushTask = Task { @MainActor in
			defer { flushTask = nil }
			while pendingDelta != 0 {
				let delta = pendingDelta
				pendingDelta = 0
				// Include changes made outside the app in every adjustment.
				guard let current = await client.currentKeyboardBrightness() else {
					refresh()
					return
				}
				let target = max(0, min(1, current + delta))
				let ok = await client.setKeyboardBrightness(target)
				if ok {
					publish(brightness: target, touchDate: true)
				} else {
					refresh()
					return
				}
				NotchUIEventBus.events.send(.sneakPeek(type: .backlight, value: CGFloat(target)))
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setKeyboardBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	@MainActor private func publish(brightness: Float, touchDate: Bool) {
		if rawBrightness != brightness || touchDate {
			if touchDate { lastChangeAt = Date() }
			rawBrightness = brightness
		}
	}
}
