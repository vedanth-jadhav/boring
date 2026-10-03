// CLI assertions and capture double for the CLT-only performance checks.
// The lyric, layout, image and AppKit visualizer implementations are production.
import AppKit
import Combine
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
func XCTAssertEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    precondition(abs(lhs - rhs) <= accuracy, "\(lhs) != \(rhs)", file: file, line: line)
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(lhs != rhs, message, file: file, line: line)
}
func XCTAssertLessThan<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs < rhs, file: file, line: line)
}
func XCTAssertGreaterThan<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs > rhs, file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, file: file, line: line)
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { preconditionFailure("Unexpected nil", file: file, line: line) }
    return value
}

extension Defaults.Keys {
    static let realtimeAudioWaveform = Key<Bool>("performanceTests.realtimeAudioWaveform", default: false)
}
protocol AudioCaptureLevelsConsumer: AnyObject {
    func audioCaptureManager(_ manager: AudioCaptureManager, didProduceLevels values: [Float])
}
final class AudioCaptureManager: ObservableObject {
    static let shared = AudioCaptureManager()
    static let barCount = 6
    @Published var isCapturing = false
    private(set) var consumers = Set<ObjectIdentifier>()
    func setLevelsConsumer(_ consumer: AudioCaptureLevelsConsumer) { consumers.insert(ObjectIdentifier(consumer)) }
    func clearLevelsConsumer(_ consumer: AudioCaptureLevelsConsumer) { consumers.remove(ObjectIdentifier(consumer)) }
    func latestLevelsSnapshot() -> [Float]? { nil }
}

// Observable inputs for testing the production shell subscription in isolation.
struct NowPlayingFallbackNotice: Equatable { let id = UUID() }
@MainActor final class MusicManager: ObservableObject {
    static let shared = MusicManager()
    @Published var isPlaying = false
    @Published var isPlayerIdle = true
    @Published var nowPlayingNotice: NowPlayingFallbackNotice?
    @Published var elapsedTime: Double = 0
    @Published var timestampDate = Date()
    @Published var volume: Double = 0.5
}
