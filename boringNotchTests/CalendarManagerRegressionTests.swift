import Defaults
import EventKit
import XCTest
@testable import boringNotch

final class CalendarManagerRegressionTests: XCTestCase {
    @MainActor
    func testOlderDateCompletionCannotReplaceNewerSelection() async throws {
        let service = DelayedCalendarService()
        let manager = CalendarManager(calendarService: service)
        let calendar = Calendar.current
        let olderDate = calendar.startOfDay(for: Date())
        let newerDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: olderDate))

        let olderRequest = Task { await manager.updateCurrentDate(olderDate) }
        try await Task.sleep(for: .milliseconds(45))
        let newerRequest = Task { await manager.updateCurrentDate(newerDate) }
        await newerRequest.value
        await olderRequest.value

        XCTAssertEqual(manager.currentWeekStartDate, newerDate)
        XCTAssertEqual(manager.events.map(\.id), ["newer"])
    }

    @MainActor
    func testEventStoreChangeInvalidatesReminderCacheAndRefreshesSelectedDay() async throws {
        let service = DelayedCalendarService()
        let manager = CalendarManager(calendarService: service)
        let selectedDate = Calendar.current.startOfDay(for: Date())
        await manager.updateCurrentDate(selectedDate)
        let callsBeforeChange = service.eventCallCount

        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        XCTAssertGreaterThan(service.invalidationCount, 0)
        try await waitUntil(timeout: .seconds(4)) {
            service.eventCallCount > callsBeforeChange && service.invalidationCount > 0
        }

        XCTAssertGreaterThan(service.eventCallCount, callsBeforeChange)
        XCTAssertGreaterThan(service.invalidationCount, 0)
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class DelayedCalendarService: CalendarServiceProviding {
    private let lock = NSLock()
    private var calls = 0
    private var invalidations = 0
    private let calendar = Calendar.current
    let olderDate = Calendar.current.startOfDay(for: Date())

    var eventCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var invalidationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invalidations
    }

    func requestAccess(to type: EKEntityType) async throws -> Bool { true }
    func calendars() async -> [CalendarModel] { [] }

    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] {
        lock.lock()
        calls += 1
        lock.unlock()
        let isOlder = calendar.isDate(start, inSameDayAs: olderDate)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(isOlder ? 250 : 20)) {
                continuation.resume()
            }
        }
        return [event(id: isOlder ? "older" : "newer", start: start)]
    }

    func invalidateReminderCache() {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {}

    private func event(id: String, start: Date) -> EventModel {
        EventModel(
            id: id,
            start: start,
            end: start,
            title: id,
            location: nil,
            notes: nil,
            url: nil,
            isAllDay: true,
            type: .event(.unknown),
            calendar: CalendarModel(id: "test", account: "", title: "Test", color: .clear, isSubscribed: false),
            participants: [],
            timeZone: nil,
            hasRecurrenceRules: false,
            priority: nil,
            meetingLink: nil
        )
    }
}
