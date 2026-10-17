//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService: CalendarServiceProviding

    private var eventStoreChangedObserver: NSObjectProtocol?
    /// EventKit can fire EKEventStoreChanged in bursts during syncs; reloads
    /// coalesce so the UI refreshes once per burst instead of per notification.
    private var reloadTask: Task<Void, Never>?
    private var storeChangePending = false
    private var eventRequestTask: Task<Void, Never>?
    private var eventRequestGeneration: UInt64 = 0

    init(calendarService: CalendarServiceProviding = CalendarService()) {
        self.calendarService = calendarService
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.calendarService.invalidateReminderCache()
                self.cancelPendingEventRequest()
                self.storeChangePending = true
                guard self.reloadTask == nil else { return }
                self.reloadTask = Task { @MainActor in
                    defer { self.reloadTask = nil }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    while self.storeChangePending && !Task.isCancelled {
                        self.storeChangePending = false
                        await self.reloadCalendarAndReminderLists()
                        guard !Task.isCancelled else { return }
                        if self.storeChangePending {
                            try? await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                        await self.updateEvents()
                        if self.storeChangePending {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            Log.calendar.debug("📅 Current calendar authorization status: \(String(describing: status))")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                await updateEvents()
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            Log.calendar.debug("Unknown authorization status")
        }
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            Log.calendar.debug("📅 Current reminder authorization status: \(String(describing: status))")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                await updateEvents()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            Log.calendar.debug("Unknown authorization status")
        }
    }

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        eventRequestGeneration &+= 1
        let generation = eventRequestGeneration
        eventRequestTask?.cancel()

        let service = calendarService
        let selectedDate = currentWeekStartDate
        let calendarIDs = selectedCalendars.map { $0.id }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        let request = Task { @MainActor [weak self] in
            // Date-strip gestures can generate many changes in a single frame.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            let result = await service.events(from: selectedDate, to: nextDay, calendars: calendarIDs)
            guard !Task.isCancelled,
                  let self,
                  self.eventRequestGeneration == generation else { return }
            self.events = result
        }
        eventRequestTask = request
        await request.value
    }

    private func cancelPendingEventRequest() {
        eventRequestGeneration &+= 1
        eventRequestTask?.cancel()
        eventRequestTask = nil
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        calendarService.invalidateReminderCache()
        await updateEvents()
    }
}
