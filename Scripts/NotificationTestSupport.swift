// Only used by test_notifications.sh when the Command Line Tools lack XCTest.
// Assertions fail the process. Production parsing, queue, manager, XPC client,
// controls and layout are compiled unchanged alongside the XCTest test methods.
import AppKit
import Defaults
import SwiftUI

class XCTestCase {}
func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(value(), message, file: file, line: line)
}
func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(!value(), message, file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "\(lhs) != \(rhs). \(message)", file: file, line: line)
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(lhs != rhs, message, file: file, line: line)
}
func XCTAssertLessThan<T: Comparable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(lhs < rhs, message, file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, file: file, line: line)
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { preconditionFailure("Unexpected nil", file: file, line: line) }
    return value
}

typealias ViewState<Value> = SwiftUI.State<Value>
// App preference declarations and window focus API; business logic is production.
extension Defaults.Keys {
    static let notificationLiveActivity = Key<Bool>("notificationLiveActivity", default: false)
    static let notificationsFromAllApps = Key<Bool>("notificationsFromAllApps", default: false)
    static let notificationAllowedApps = Key<Set<String>>("notificationAllowedApps", default: [])
    static let notificationBlockedApps = Key<Set<String>>("notificationBlockedApps", default: [])
    static let notificationSuppressNativeBanners = Key<Bool>("notificationSuppressNativeBanners", default: true)
    static let notificationPreviewPrivacy = Key<Bool>("notificationPreviewPrivacy", default: false)
}
extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
class BoringNotchSkyLightWindow: NSPanel {
    var wantsKeyForTextInput = false
    override var canBecomeKey: Bool { wantsKeyForTextInput }
}

enum Style { case notch, floating }
extension Defaults.Keys {
    static let enableOpeningAnimation = Key<Bool>("enableOpeningAnimation", default: true)
    static let reduceGlass = Key<Bool>("reduceGlass", default: false)
    static let animationSpeedMultiplier = Key<Double>("animationSpeedMultiplier", default: 1)
}
