import XCTest
@testable import boringNotch

final class BatterySnapshotTests: XCTestCase {
    @MainActor
    func testSyntheticPowerSourceChangePublishesOneCoherentSnapshotAndLegacyEvents() async {
        let manager = BatteryActivityManager(startMonitoring: false)
        manager.processBatteryInfo(batteryInfo(
            pluggedIn: false,
            charging: false,
            capacity: 42,
            timeToDischarge: 90
        ))

        let snapshotExpectation = expectation(description: "one snapshot callback")
        let legacyEventsExpectation = expectation(description: "legacy property callbacks")
        legacyEventsExpectation.expectedFulfillmentCount = 6
        var receivedSnapshots: [BatteryInfo] = []
        var receivedEvents: [BatteryActivityManager.BatteryEvent] = []

        manager.addSnapshotObserver { snapshot in
            receivedSnapshots.append(snapshot)
            snapshotExpectation.fulfill()
        }
        manager.addObserver { event in
            receivedEvents.append(event)
            legacyEventsExpectation.fulfill()
        }

        manager.processBatteryInfo(batteryInfo(
            pluggedIn: true,
            charging: true,
            capacity: 43,
            timeToDischarge: 0
        ))

        await fulfillment(of: [snapshotExpectation, legacyEventsExpectation], timeout: 1)
        XCTAssertEqual(receivedSnapshots.count, 1)
        XCTAssertTrue(receivedSnapshots[0].isPluggedIn)
        XCTAssertTrue(receivedSnapshots[0].isCharging)
        XCTAssertEqual(receivedSnapshots[0].currentCapacity, 43)
        XCTAssertEqual(receivedEvents.count, 6)
    }

    private func batteryInfo(
        pluggedIn: Bool,
        charging: Bool,
        capacity: Float,
        timeToDischarge: Int
    ) -> BatteryInfo {
        BatteryInfo(
            isPluggedIn: pluggedIn,
            isCharging: charging,
            currentCapacity: capacity,
            maxCapacity: 95,
            isInLowPowerMode: false,
            timeToFullCharge: charging ? 40 : 0,
            timeToDischarge: timeToDischarge,
            maxAdapterWatts: pluggedIn ? 67 : 0
        )
    }
}
