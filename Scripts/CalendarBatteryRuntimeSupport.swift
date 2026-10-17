import AppKit
import Defaults
import EventKit
import Foundation
import OSLog
import SwiftUI

struct CalendarModel: Equatable {
    var id: String
    var isReminder = false
}

struct EventModel: Equatable {
    var id: String
    var start: Date
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

extension Defaults.Keys {
    static let calendarSelectionState = Key<CalendarSelectionState>(
        "calendar-battery-runtime-checks",
        default: .all
    )
}

enum Log {
    static let calendar = Logger(subsystem: "calendar-battery-runtime-checks", category: "calendar")
    static let battery = Logger(subsystem: "calendar-battery-runtime-checks", category: "battery")
}

protocol CalendarServiceProviding {
    func requestAccess(to type: EKEntityType) async throws -> Bool
    func calendars() async -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel]
    func invalidateReminderCache()
    func setReminderCompleted(reminderID: String, completed: Bool) async
}

final class CalendarService: CalendarServiceProviding {
    func requestAccess(to type: EKEntityType) async throws -> Bool { true }
    func calendars() async -> [CalendarModel] { [] }
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] { [] }
    func invalidateReminderCache() {}
    func setReminderCompleted(reminderID: String, completed: Bool) async {}
}

enum RuntimeNotice {
    case expandingView(type: Kind)
    enum Kind { case battery }
}

final class RuntimeEventBus {
    static let events = RuntimeEventBus()
    private(set) var batteryExpansionCount = 0

    func send(_ event: RuntimeNotice) {
        if case .expandingView(type: .battery) = event {
            batteryExpansionCount += 1
        }
    }

    func reset() { batteryExpansionCount = 0 }
}

enum NotchUIEventBus {
    static let events = RuntimeEventBus.events
}

@MainActor
final class CalendarBatteryRuntimeChecks {
    func run() async throws {
        try await calendarRequestOrderingAndCoalescing()
        try await eventStoreRefresh()
        try await batterySnapshotAndExpansion()
    }

    private func calendarRequestOrderingAndCoalescing() async throws {
        let service = RuntimeCalendarService()
        let manager = CalendarManager(calendarService: service)
        let calendar = Calendar.current
        let older = calendar.startOfDay(for: Date())
        let newer = try require(calendar.date(byAdding: .day, value: 1, to: older))

        let oldRequest = Task { await manager.updateCurrentDate(older) }
        try await Task.sleep(for: .milliseconds(50))
        let newRequest = Task { await manager.updateCurrentDate(newer) }
        await newRequest.value
        await oldRequest.value
        try require(manager.currentWeekStartDate == newer, "selected date should stay on the latest request")
        try require(manager.events.map(\.id) == ["day1-call2"], "late older result overwrote latest events")

        let before = service.eventCallCount
        let sameDateA = Task { await manager.updateCurrentDate(newer) }
        try await Task.sleep(for: .milliseconds(5))
        let sameDateB = Task { await manager.updateCurrentDate(newer) }
        await sameDateA.value
        await sameDateB.value
        try require(service.eventCallCount == before + 1, "rapid same-day requests were not coalesced")
        print("PASS CalendarManager ordering, generation gate, and same-day coalescing")
    }

    private func eventStoreRefresh() async throws {
        let service = RuntimeCalendarService()
        let manager = CalendarManager(calendarService: service)
        await manager.updateCurrentDate(Date())
        let callsBefore = service.eventCallCount

        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        try await waitUntil(timeout: .seconds(1)) { service.invalidationCount > 0 }
        try require(service.invalidationCount > 0, "store change did not invalidate reminders promptly")
        try await waitUntil(timeout: .seconds(4)) { service.eventCallCount > callsBefore }
        let firstRefreshCall = service.eventCallCount
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        try await waitUntil(timeout: .seconds(1)) { service.invalidationCount > 1 }
        try await waitUntil(timeout: .seconds(4)) { service.eventCallCount > firstRefreshCall }
        let expectedLatestID = "day0-call\(firstRefreshCall + 1)"
        try await waitUntil(timeout: .seconds(2)) { manager.events.first?.id == expectedLatestID }
        try require(manager.events.first?.id == expectedLatestID, "notification during refresh was dropped; latest event snapshot was not published")
        print("PASS EventKit invalidation, refresh, and trailing notification during active fetch")
    }

    private func batterySnapshotAndExpansion() async throws {
        let manager = BatteryActivityManager(startMonitoring: false)
        let baseline = batteryInfo(plugged: false, charging: false, level: 42, estimate: 90)
        manager.processBatteryInfo(baseline)
        var observedSnapshots = 0
        _ = manager.addSnapshotObserver { _ in observedSnapshots += 1 }
        let viewModel = BatteryStatusViewModel(manager: manager, initialBatteryInfo: baseline)
        NotchUIEventBus.events.reset()

        manager.processBatteryInfo(batteryInfo(plugged: true, charging: true, level: 43, estimate: 0))
        try await Task.sleep(for: .milliseconds(100))

        try require(viewModel.isPluggedIn && viewModel.isCharging, "view model did not apply the coherent power snapshot")
        try require(viewModel.levelBattery == 43 && viewModel.timeToDischarge == 0, "view model exposed mixed snapshot fields")
        try require(observedSnapshots == 1, "new observer received a battery snapshot queued before it subscribed")
        try require(NotchUIEventBus.events.batteryExpansionCount == 1, "one source change generated multiple expansion notices")
        print("PASS synthetic battery snapshot and single expansion notice")
    }

    private func batteryInfo(plugged: Bool, charging: Bool, level: Float, estimate: Int) -> BatteryInfo {
        BatteryInfo(
            isPluggedIn: plugged,
            isCharging: charging,
            currentCapacity: level,
            maxCapacity: 95,
            isInLowPowerMode: false,
            timeToFullCharge: charging ? 40 : 0,
            timeToDischarge: estimate,
            maxAdapterWatts: plugged ? 67 : 0
        )
    }

    private func waitUntil(timeout: Duration, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try require(ContinuousClock.now < deadline, "timed out waiting for asynchronous refresh")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard let value else { throw RuntimeCheckFailure(message: "unexpected nil", file: file, line: line) }
        return value
    }

    private func require(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else { throw RuntimeCheckFailure(message: message, file: file, line: line) }
    }
}

private struct RuntimeCheckFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt
    init(message: String, file: StaticString, line: UInt) {
        self.message = message
        self.file = file
        self.line = line
    }
    var description: String { "\(file):\(line): \(message)" }
}

private final class RuntimeCalendarService: CalendarServiceProviding {
    private let lock = NSLock()
    private var calls = 0
    private var invalidations = 0
    private let calendar = Calendar.current
    private let today = Calendar.current.startOfDay(for: Date())

    var eventCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var invalidationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return invalidations
    }

    func requestAccess(to type: EKEntityType) async throws -> Bool { true }
    func calendars() async -> [CalendarModel] { [] }

    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] {
        let callNumber = incrementCallCount()
        let offset = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        // Deliberately ignore task cancellation to model EventKit's callback API.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + (offset == 0 ? .milliseconds(300) : .milliseconds(30))) {
                continuation.resume()
            }
        }
        return [EventModel(id: "day\(offset)-call\(callNumber)", start: start)]
    }

    func invalidateReminderCache() {
        lock.lock(); invalidations += 1; lock.unlock()
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {}

    private func incrementCallCount() -> Int {
        lock.lock()
        calls += 1
        let callNumber = calls
        lock.unlock()
        return callNumber
    }
}

@main struct CalendarBatteryRuntimeMain {
    @MainActor static func main() async throws {
        let checks = CalendarBatteryRuntimeChecks()
        try await checks.run()
        print("3 calendar and battery runtime regression groups passed")
    }
}
