import Foundation
import SQLite3

@main struct NotificationCaptureChecks {
    static func main() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let suite="boring-notification-capture-tests." + UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("db")
        var database:OpaquePointer?
        precondition(sqlite3_open(url.path,&database)==SQLITE_OK)
        defer { sqlite3_close(database) }
        precondition(sqlite3_exec(database,"PRAGMA journal_mode=WAL; CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier TEXT); CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,data BLOB); INSERT INTO app VALUES(1,'net.whatsapp.WhatsApp');",nil,nil,nil)==SQLITE_OK)
        let watcher=NotificationWatcher(storeURL:url,defaults:defaults)
        await withCheckedContinuation { continuation in watcher.configureFilter(bundleIDs:[],allApps:true,ignored:[],completion:{continuation.resume()}) }
        let stream=AsyncStream<NotificationSourceEvent>.makeStream()
        let started:Bool=await withCheckedContinuation { continuation in
            watcher.start(onEvent:{ stream.continuation.yield($0) },completion:{ continuation.resume(returning:$0) })
        }
        precondition(started)
        let receive=Task { () -> [String] in
            var ids:[String]=[]
            for await event in stream.stream {
                if let item=event.notification { ids.append(item.id) }
                if ids.count==5 { break }
            }
            return ids
        }
        for index in 1...5 {
            let data=try PropertyListSerialization.data(fromPropertyList:["date":Date().timeIntervalSinceReferenceDate,"req":["titl":"Test","body":"Repeated identical message"]],format:.binary,options:0)
            let hex=data.map { String(format:"%02x",$0) }.joined()
            precondition(sqlite3_exec(database,"INSERT INTO record VALUES(\(index),1,x'0\(index)',x'\(hex)');",nil,nil,nil)==SQLITE_OK)
            try await Task.sleep(for:.milliseconds(40))
        }
        let timeout=Task {
            try? await Task.sleep(for:.seconds(5))
            stream.continuation.finish()
        }
        let ids=await receive.value
        timeout.cancel(); precondition(ids.count==5 && Set(ids).count==5,"WAL capture must preserve five identical occurrences")
        watcher.stop()
        try await Task.sleep(for:.milliseconds(100))
        let restarted=AsyncStream<NotificationSourceEvent>.makeStream()
        let again:Bool=await withCheckedContinuation { continuation in
            watcher.start(onEvent:{restarted.continuation.yield($0)},completion:{continuation.resume(returning:$0)})
        }
        precondition(again)
        let noReplay=Task { () -> Int in
            var count=0
            for await event in restarted.stream { if event.kind == .upsert { count += 1 } }
            return count
        }
        try await Task.sleep(for:.milliseconds(250)); restarted.continuation.finish()
        let replayCount=await noReplay.value; precondition(replayCount==0)
        watcher.stop()
        try await Task.sleep(for:.milliseconds(100))
        print("PASS real SQLite/WAL burst: five identical notifications, five stable IDs")
        print("PASS source stop/restart: zero stale replay; no Accessibility dependency")
    }
}
