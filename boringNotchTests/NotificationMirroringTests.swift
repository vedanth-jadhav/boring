import AppKit
import Combine
import Defaults
import SQLite3
import SwiftUI
import XCTest
@testable import boringNotch

final class NotificationMirroringTests: XCTestCase {
    func testEarlyBannerParsesRolesAndGeometryWithoutChildIndexes() throws {
        let snapshot=NotificationBannerSnapshot(appName:"WhatsApp",bundleID:"net.whatsapp.WhatsApp",texts:[
            .init(value:"Longer message preview",identifier:"body",x:50,y:80),
            .init(value:"now",identifier:"time",x:280,y:40),
            .init(value:"WhatsApp",identifier:"app",x:50,y:10),
            .init(value:"Sender",identifier:"title",x:50,y:40)
        ],sourceKey:"first",observedAt:Date())
        let parsed=try XCTUnwrap(NotificationBannerParser.parse(snapshot))
        XCTAssertEqual(parsed.title,"Sender"); XCTAssertEqual(parsed.body,"Longer message preview")
    }
    func testFastAndStoreCaptureMergeOneToOneDuringIdenticalBursts() {
        var dedup=NotificationCaptureDeduplicator(), captured:[MirroredNotification]=[]
        for i in 0..<5 { if let notification=dedup.ingest(item("banner:\(i)")) { captured.append(notification) } }
        for i in 0..<5 { if let notification=dedup.ingest(item("store:\(i)")) { captured.append(notification) } }
        XCTAssertEqual(captured.count,5); XCTAssertEqual(Set(captured.map(\.id)).count,5)
        let sixth=dedup.ingest(item("store:new")); XCTAssertNotNil(sixth)
    }
    private func item(_ id: String, bundle: String = "net.whatsapp.WhatsApp", body: String = "Hello", seconds: TimeInterval = 0) -> MirroredNotification {
        .init(id: id, appName: "WhatsApp", bundleID: bundle, title: "Mia", subtitle: nil, body: body, receivedAt: Date().addingTimeInterval(seconds))
    }
    func testStorePayloadHasCleanSemanticsAndStableUUID() throws {
        let date = Date()
        let payload: [String: Any] = ["date": date.timeIntervalSinceReferenceDate, "req": ["titl":"Mia", "subt":"Group", "body":"Hello", "thre":"thread-42", "iden":"request-1"]]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        let first = try XCTUnwrap(NotificationStoreReader.decode(data: data, uuid: Data([1,2,3]), bundleID: "net.whatsapp.WhatsApp", recordID: 1, storeIdentity: "A"))
        let second = try XCTUnwrap(NotificationStoreReader.decode(data: data, uuid: Data([1,2,3]), bundleID: "net.whatsapp.WhatsApp", recordID: 99, storeIdentity: "B"))
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(first.title, "Mia"); XCTAssertEqual(first.subtitle, "Group")
        XCTAssertLessThan(abs(first.receivedAt.timeIntervalSince(date)), 0.001)
        let json = String(data: try JSONEncoder().encode(first), encoding: .utf8)!
        for forbidden in ["capability", "AXPress", "Target:", "Selector:", "isSourceAvailable"] { XCTAssertFalse(json.contains(forbidden)) }
    }
    func testMalformedStoreRecordFailsClosed() {
        XCTAssertNil(NotificationStoreReader.decode(data: Data(), uuid: nil, bundleID: "app", recordID: 1, storeIdentity: "A"))
    }
    func testReadOnlyStoreCursorAndRepeatedMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE app(app_id INTEGER,identifier TEXT); CREATE TABLE record(rec_id INTEGER,app_id INTEGER,uuid BLOB,data BLOB); INSERT INTO app VALUES(1,'net.whatsapp.WhatsApp');", nil, nil, nil), SQLITE_OK)
        let payload = try PropertyListSerialization.data(fromPropertyList: ["date":Date().timeIntervalSinceReferenceDate,"req":["titl":"Mia","body":"Hello"]], format: .binary, options: 0)
        let hex = payload.map { String(format:"%02x",$0) }.joined()
        for id in 1...5 { XCTAssertEqual(sqlite3_exec(database,"INSERT INTO record VALUES(\(id),1,x'0\(id)',x'\(hex)');",nil,nil,nil),SQLITE_OK) }
        let reader = NotificationStoreReader(path:path)
        let batch = try reader.read(after:0)
        XCTAssertEqual(batch.notifications.count,5); XCTAssertEqual(batch.cursor,5)
        XCTAssertEqual(Set(batch.notifications.map(\.id)).count,5)
        let empty = try reader.read(after:5); XCTAssertTrue(empty.notifications.isEmpty)
    }
    func testMissingAndUnsupportedStoresDoNotInventNotifications() throws {
        let missing = NotificationStoreReader(path:URL(fileURLWithPath:"/no-such-boring-store/"))
        do { _ = try missing.maximumID(); XCTAssertTrue(false) } catch { }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:path) }
        var database: OpaquePointer?; sqlite3_open(path.path,&database); sqlite3_close(database)
        do { _ = try NotificationStoreReader(path:path).maximumID(); XCTAssertTrue(false) } catch ProtectedStoreError.schema { } catch { XCTAssertTrue(false) }
    }
    func testLatestFirstBurstStableUpdatesAndQueueCap() {
        var state = NotificationQueueState()
        for id in 0..<5 { state.upsert(item("\(id)",seconds:Double(id))) }
        XCTAssertEqual(state.notifications.map(\.id),["4","3","2","1","0"])
        state.upsert(item("2",body:"Updated",seconds:2))
        XCTAssertEqual(state.notifications.map(\.id),["4","3","2","1","0"])
        for id in 5..<50 { state.upsert(item("\(id)",seconds:Double(id))) }
        XCTAssertEqual(state.notifications.count,32); XCTAssertFalse(state.notifications.contains { $0.id == "0" })
        state.remove("0"); XCTAssertEqual(state.notifications.count,32)
    }
    func testRetiredMirroredRowCannotReappearFromStaleStoreReplay() {
        var state = NotificationQueueState(); state.upsert(item("one")); state.remove("one"); state.upsert(item("one"))
        XCTAssertTrue(state.notifications.isEmpty)
    }
    func testFilteringAndPresentationPriority() {
        let filter = NotificationFilter(allApps:true,allowed:[],ignored:["net.whatsapp.WhatsApp"])
        XCTAssertFalse(filter.allows(appName:"WhatsApp",bundleID:"net.whatsapp.WhatsApp"))
        XCTAssertFalse(filter.allows(appName:"Boring Notch",bundleID:nil))
        XCTAssertTrue(filter.allows(appName:"Messages",bundleID:"com.apple.MobileSMS"))
        for (workspace,hud,drag) in [(true,false,false),(false,true,false),(false,false,true)] {
            XCTAssertEqual(NotificationPresentationPolicy.mode(hasNotifications:true,unavailable:false,hidden:false,onboarding:false,dragging:drag,workspaceOpen:workspace,systemHUD:hud),.deferred)
        }
    }
    func testSuppressorMatchesExactSemanticAppAndOnlyDismissLabels() {
        let message = item("one")
        XCTAssertTrue(NativeBannerMatch.matches(message,texts:["Mia","Hello"],appDescription:"WhatsApp, new message",bundleID:nil))
        XCTAssertTrue(NativeBannerMatch.matches(message,texts:["WhatsApp","Mia","Hello"],appDescription:nil,bundleID:nil))
        XCTAssertFalse(NativeBannerMatch.matches(message,texts:["Mia","Hello"],appDescription:"Telegram, new message",bundleID:nil))
        XCTAssertFalse(NativeBannerMatch.matches(message,texts:["Mia","Other"],appDescription:"WhatsApp",bundleID:nil))
        XCTAssertTrue(NativeBannerMatch.isDismissLabel("Close notification"))
        XCTAssertTrue(NativeBannerMatch.isDismissAction("Name:Close\nTarget:0x0\nSelector:(null)"))
        XCTAssertFalse(NativeBannerMatch.isDismissAction("Name:Hide Details\nTarget:0x0\nSelector:(null)"))
        XCTAssertFalse(NativeBannerMatch.isDismissAction("AXPress"))
        for label in ["Reply","Send","Name:Hide Details\nTarget:0x0\nSelector:(null)","Hide Details"] { XCTAssertFalse(NativeBannerMatch.isDismissLabel(label)) }
    }
    func testVersionTwoWireHasNoNativeActionTransport() throws {
        let event = NotificationSourceEvent(kind:.upsert,notification:item("wire"))
        let decoded = try JSONDecoder().decode(NotificationSourceEvent.self,from:JSONEncoder().encode(event))
        XCTAssertEqual(decoded.version,2); XCTAssertEqual(decoded.notification,event.notification)
    }
    @MainActor func testStorePermissionDeniedAndRecoveryWithoutAccessibility() async {
        let source = TestStoreSource(); source.started = false
        let manager = makeManager(source:source)
        await manager.start(); manager.receive(.init(kind:.unavailable,failure:.fullDiskAccess))
        XCTAssertEqual(manager.availability,.fullDiskAccessRequired)
        source.started = true; manager.receive(.init(kind:.ready)); XCTAssertEqual(manager.availability,.observing)
        manager.setSuspended(true); XCTAssertEqual(manager.availability,.suspended)
        manager.setSuspended(false); await Task.yield(); await manager.start()
        XCTAssertEqual(manager.availability,.observing); manager.stop()
    }
    @MainActor func testClickAlwaysOpensNativeAppAndKeepsOtherNotifications() async throws {
        let previous=Defaults[.notificationsFromAllApps]; Defaults[.notificationsFromAllApps]=true
        defer { Defaults[.notificationsFromAllApps]=previous }
        var opened:[String]=[]
        let manager=NotificationManager(source:TestStoreSource(),suppressor:TestSuppressor(),enabled:{true},openApplication:{ item in opened.append(item.bundleID!); return true })
        await manager.start()
        manager.receive(.init(kind:.upsert,notification:item("one")))
        manager.receive(.init(kind:.upsert,notification:item("two",bundle:"org.telegram.desktop",seconds:1)))
        try await Task.sleep(for:.milliseconds(60))
        let first=try XCTUnwrap(manager.activeNotification)
        let success=await manager.open(first)
        XCTAssertTrue(success); XCTAssertEqual(opened.count,1)
        XCTAssertEqual(manager.state.notifications.map(\.id),["one"])
        manager.stop()
    }
    @MainActor func testBurstUpdatesQueueAndRetriesNativeDismissal() async throws {
        let previous=Defaults[.notificationsFromAllApps]; Defaults[.notificationsFromAllApps]=true
        let priorSuppression=Defaults[.notificationSuppressNativeBanners]; Defaults[.notificationSuppressNativeBanners]=true
        defer { Defaults[.notificationsFromAllApps]=previous; Defaults[.notificationSuppressNativeBanners]=priorSuppression }
        let suppressor=TestSuppressor(); suppressor.succeedsOnAttempt=2
        let manager=makeManager(suppressor:suppressor); await manager.start(); manager.holdActive()
        for i in 0..<5 { manager.receive(.init(kind:.upsert,notification:item("burst-\(i)",seconds:Double(i)/100))) }
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(manager.state.notifications.map(\.id),["burst-4","burst-3","burst-2","burst-1","burst-0"])
        XCTAssertTrue(manager.isPresented); XCTAssertEqual(suppressor.items.count,10)
        manager.stop()
    }
    @MainActor func testRenderLatestHoverQueueAndMusicWithFixedWindow() async throws {
        let previous=Defaults[.notificationsFromAllApps]; Defaults[.notificationsFromAllApps]=true; defer { Defaults[.notificationsFromAllApps]=previous }
        let manager=makeManager(); await manager.start(); manager.holdActive()
        let model=NotificationCaptureState(manager:manager)
        let host=NSHostingView(rootView:NotificationCaptureView(model:model))
        host.frame=NSRect(x:0,y:0,width:640,height:350)
        let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.isOpaque=false; window.backgroundColor = .clear
        window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); window.contentView=host; window.orderFront(nil)
        let initial=window.frame
        let directory=URL(fileURLWithPath:"/tmp/boring-notifications-rebuild"); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for frame in 0..<32 {
            if frame % 3 == 0, frame <= 12 { manager.receive(.init(kind:.upsert,notification:item("render-\(frame)",seconds:Double(frame)/100))) }
            if frame == 15 { model.expanded=true }
            if frame == 25 { model.expanded=false }
            if frame == 28 { model.music=true }
            try await Task.sleep(for:.milliseconds(60))
            // Offscreen AppKit windows can suppress observation-driven display
            // commits. Drive the same root value explicitly for layout capture.
            host.rootView=NotificationCaptureView(model:model); host.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame,initial); XCTAssertTrue(window.contentView === host)
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
            let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try png.write(to:directory.appendingPathComponent(String(format:"frame-%02d.png",frame)))
        }
        XCTAssertEqual(manager.state.notifications.count,5); window.close(); manager.stop()
    }
    @MainActor private func makeManager(source:TestStoreSource?=nil,suppressor:TestSuppressor?=nil) -> NotificationManager {
        NotificationManager(source:source ?? TestStoreSource(),suppressor:suppressor ?? TestSuppressor(),enabled:{true})
    }
    @MainActor private func withAllApps(_ action:()->Void) {
        let previous=Defaults[.notificationsFromAllApps]; Defaults[.notificationsFromAllApps]=true; action()
        // Batch filtering already happened synchronously on receive.
        Defaults[.notificationsFromAllApps]=previous
    }
}
@MainActor private final class TestStoreSource: NotificationSource {
    let subject=PassthroughSubject<NotificationSourceEvent,Never>(); var started=true
    var events:AnyPublisher<NotificationSourceEvent,Never> { subject.eraseToAnyPublisher() }
    func start() async -> Bool { started }
    func stop() {}
    func configure(allowed:Set<String>,allApps:Bool,ignored:Set<String>) async {}
}
@MainActor private final class TestSuppressor:NativeBannerSuppressing {
    var items:[String]=[], succeedsOnAttempt=99
    func suppress(_ item:MirroredNotification) async -> Bool { items.append(item.id); return items.filter { $0 == item.id }.count >= succeedsOnAttempt }
}
@MainActor private final class NotificationCaptureState:ObservableObject {
    let manager:NotificationManager
    @Published var expanded=false
    @Published var music=false
    init(manager:NotificationManager) { self.manager=manager }
}
private struct NotificationCaptureView:View {
    @ObservedObject var model:NotificationCaptureState
    @ObservedObject var manager:NotificationManager
    init(model:NotificationCaptureState) { self.model=model; manager=model.manager }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                if model.music { Image(systemName:"music.note").foregroundStyle(.white) }
                Color.clear.frame(width:210,height:38)
                if model.music { Image(systemName:"waveform").foregroundStyle(.cyan) }
            }
            if !manager.state.notifications.isEmpty { NotificationQueueView(manager:manager,musicIsPlaying:model.music,expanded:model.expanded) }
        }
        .padding(.horizontal,12).background(NotchShape(topCornerRadius:12,bottomCornerRadius:24).fill(Color(white:0.04)))
        .clipShape(NotchShape(topCornerRadius:12,bottomCornerRadius:24))
        .animation(StandardAnimations.interactive,value:NotificationSurfaceTransition(state:manager.state,presented:true,expanded:model.expanded))
        .frame(width:640,height:350,alignment:.top).environment(\.colorScheme,.dark)
    }
}
