import AppKit
import Darwin
import SwiftUI

private let fixtureLines: [LyricLine] = (0..<8).map { lineIndex in
    let tokens = [
        ["Every", "little", "moment", "feels", "like", "coming", "home", "again"],
        ["Élévation", "ख़्वाबों", "में", "हूँ", "through", "the", "night", "again"],
        ["I", "can", "feel", "the", "rhythm", "moving", "through", "me"]
    ][lineIndex % 3]
    let start = Double(lineIndex) * 4
    let words = tokens.enumerated().map { index, text in
        let rapid = lineIndex % 3 == 2
        let onset = start + Double(index) * (rapid ? 0.12 : 0.38)
        let duration = rapid ? (index == 7 ? 1.8 : 0.10) : (index == 6 ? 0.6 : 0.32)
        return LyricLine.Word(text: text, start: onset, end: onset + duration)
    }
    return LyricLine(start: start, end: start + 3.5, text: tokens.joined(separator: " "), words: words)
}
private let fixtureTimeline = LyricTimeline(lines: fixtureLines)

private struct FixtureRow: View {
    let position: Double
    let date: Date
    let playing: Bool
    let width: CGFloat
    let pointSize: CGFloat
    let exact: Bool

    #if !LYRIC_MOTION_BASELINE
    func configuration() -> LyricCanvasView {
        let entry = fixtureTimeline.displayedPrimary(at: position)!
        let source = entry.vocalRows.primary!
        let row = exact ? source : LyricVocalFrame.Row(id: source.id + ":phrase", words: source.words,
            isBackground: false, hasExactTiming: false)
        let previous = fixtureTimeline.previousDisplayedPrimary(at: position)?.vocalRows.primary
        let layout = LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: false, pointSize: pointSize, width: width)
        return LyricCanvasView(row: row, previousRow: previous, layout: layout,
            previousLayout: previous.map { LyricTextLayout.cached(words: $0.words, rowID: $0.id,
                romanize: false, pointSize: pointSize, width: width) },
            displayStart: entry.line.start, elapsed: position, sampleDate: date, playbackRate: 1,
            isPlaying: playing, reduceMotion: false, pointSize: pointSize)
    }
    #endif

    var body: some View {
        let entry = fixtureTimeline.displayedPrimary(at: position)!
        let source = entry.vocalRows.primary!
        let row = exact ? source : LyricVocalFrame.Row(id: source.id + ":phrase", words: source.words,
            isBackground: false, hasExactTiming: false)
        #if LYRIC_MOTION_BASELINE
        KaraokeLyricLineView(row: row, elapsed: position, sampleDate: date,
            playbackRate: 1, isPlaying: playing, romanize: false, width: width, pointSize: pointSize)
        #else
        KaraokeLyricLineView(row: row,
            previousRow: fixtureTimeline.previousDisplayedPrimary(at: position)?.vocalRows.primary,
            displayStart: entry.line.start, elapsed: position, sampleDate: date,
            playbackRate: 1, isPlaying: playing, romanize: false, width: width, pointSize: pointSize)
        #endif
    }
}

private struct Fixture: View {
    let position: Double
    let date: Date
    let playing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FixtureRow(position: position, date: date, playing: playing, width: 430, pointSize: 13, exact: true)
            FixtureRow(position: position, date: date, playing: playing, width: 155, pointSize: 10, exact: true)
            FixtureRow(position: position, date: date, playing: playing, width: 430, pointSize: 13, exact: false)
        }
        .frame(width: 480, height: 135, alignment: .leading)
        .padding(.horizontal, 20)
        .background(Color.black)
    }
}

private struct LiveFixture: View {
    let anchor: Date
    let mode: String
    var body: some View {
        let active = mode == "active"
        let dates = active ? (0..<64).map { anchor.addingTimeInterval(Double($0) / 4) } : [anchor]
        TimelineView(.explicit(dates)) { context in
            let position = active ? context.date.timeIntervalSince(anchor) : (mode == "silence" ? 3.8 : 1.2)
            Fixture(position: position, date: context.date, playing: mode != "paused")
        }
    }
}

private final class RenderWindow: NSPanel {}

@main struct LyricRenderChecks {
    static func cpuTime() -> Double {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let arguments = CommandLine.arguments
        if arguments[1] == "render" {
            #if !LYRIC_MOTION_BASELINE
            let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for frame in 0..<720 {
                try autoreleasepool {
                    let context = CGContext(data: nil, width: 1040, height: 270, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.scaleBy(x: 2, y: 2)
                    context.setFillColor(NSColor.black.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: 520, height: 135))
                    for (width, size, y, exact) in [(430.0, 13.0, 103.0, true), (155, 10, 67, true), (430, 13, 31, false)] {
                        let configuration = FixtureRow(position: Double(frame) / 60, date: .now, playing: false,
                            width: width, pointSize: size, exact: exact).configuration()
                        context.saveGState()
                        context.translateBy(x: 20, y: y - size * 1.65 / 2)
                        context.clip(to: CGRect(x: 0, y: 0, width: width, height: size * 1.65))
                        configuration.draw(in: context, size: CGSize(width: width, height: size * 1.65), at: Double(frame) / 60)
                        context.restoreGState()
                    }
                    guard let image = context.makeImage() else { fatalError("Native lyric renderer returned no image") }
                    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    try data.write(to: output.appendingPathComponent(String(format: "%04d.png", frame)))
                }
            }
            print("PASS: 720 native frames: ordinary, held and rapid vocals, accents and Hindi, normal and compact sizes")
            #endif
            return
        }
        let mode = arguments[1]
        let screen = NSScreen.main!.visibleFrame
        let window = RenderWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 520, height: 135),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .floating
        window.contentView = NSHostingView(rootView: LiveFixture(anchor: .now, mode: mode))
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            #if !LYRIC_MOTION_BASELINE
            let startTicks = LyricPaintView.frameTicks, startPaints = LyricPaintView.paintCount
            #endif
            let startCPU = cpuTime(), startWall = Date()
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                let wall = Date().timeIntervalSince(startWall)
                let percent = 100 * (cpuTime() - startCPU) / wall
                var result: [String: Any] = ["mode": mode, "cpu_percent_one_core": percent,
                    "wall_seconds": wall, "rows": 3, "isolated_renderer": true, "on_screen": true]
                #if !LYRIC_MOTION_BASELINE
                result["frame_ticks"] = LyricPaintView.frameTicks - startTicks
                result["paints"] = LyricPaintView.paintCount - startPaints
                #endif
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
                window.close()
                Darwin.exit(0)
            }
        }
        NSApplication.shared.run()
    }
}
