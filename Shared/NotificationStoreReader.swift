import Foundation
import SQLite3
import Darwin

struct NotificationStoreBatch: Sendable {
    let notifications: [MirroredNotification]
    let cursor: Int64
    let storeIdentity: String
}
enum ProtectedStoreError: Error { case permission, missing, schema, read }

/// Read-only database access. This lives in the unsandboxed existing helper so
/// Full Disk Access is sufficient even when the app target uses App Sandbox.
final class NotificationStoreReader {
    let path: URL
    private var database: OpaquePointer?
    private var openedIdentity: String?
    init(path: URL) { self.path = path }
    deinit { if let database { sqlite3_close(database) } }
    func open() throws {
        if database != nil { return }
        guard FileManager.default.fileExists(atPath: path.path) else {
            // TCC can hide existence; the open result is the authoritative probe.
            var probe: OpaquePointer?
            let result = sqlite3_open_v2(path.path, &probe, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            let systemError = errno
            if let probe { sqlite3_close(probe) }
            throw result == SQLITE_CANTOPEN && (systemError == EPERM || systemError == EACCES) ? ProtectedStoreError.permission : ProtectedStoreError.missing
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }; throw ProtectedStoreError.permission
        }
        database = handle
        openedIdentity = currentIdentity
        sqlite3_busy_timeout(handle, 150)
        guard columns("record").isSuperset(of: ["rec_id", "app_id", "uuid", "data"]),
              columns("app").isSuperset(of: ["app_id", "identifier"]) else { sqlite3_close(handle); database = nil; throw ProtectedStoreError.schema }
    }
    private func columns(_ table: String) -> Set<String> {
        guard let database else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let name = sqlite3_column_text(statement, 1) { result.insert(String(cString: name)) } }
        return result
    }
    var identity: String { openedIdentity ?? currentIdentity }
    var isCurrent: Bool { identity == currentIdentity }
    private var currentIdentity: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        return path.path + ":" + String(describing: attributes?[.systemFileNumber] ?? "unknown")
    }
    func maximumID() throws -> Int64 {
        try open(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(MAX(rec_id),0) FROM record", -1, &statement, nil) == SQLITE_OK else { throw ProtectedStoreError.read }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ProtectedStoreError.read }
        return sqlite3_column_int64(statement, 0)
    }
    func read(after cursor: Int64, through maximum: Int64 = .max) throws -> NotificationStoreBatch {
        try open(); var statement: OpaquePointer?
        let sql = "SELECT r.rec_id, a.identifier, r.uuid, r.data FROM record r JOIN app a ON a.app_id=r.app_id WHERE r.rec_id>? AND r.rec_id<=? ORDER BY r.rec_id ASC LIMIT 128"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ProtectedStoreError.read }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int64(statement, 2, maximum)
        var latest = cursor, items: [MirroredNotification] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            latest = sqlite3_column_int64(statement, 0)
            if let name = sqlite3_column_text(statement, 1), let payload = sqlite3_column_blob(statement, 3) {
                let data = Data(bytes: payload, count: Int(sqlite3_column_bytes(statement, 3)))
                let uuid = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 2))) }
                if let item = Self.decode(data: data, uuid: uuid, bundleID: String(cString: name), recordID: latest, storeIdentity: identity) { items.append(item) }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ProtectedStoreError.read }
        return .init(notifications: items, cursor: latest, storeIdentity: identity)
    }
    static func decode(data: Data, uuid: Data?, bundleID: String, recordID: Int64, storeIdentity: String) -> MirroredNotification? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = root["req"] as? [String: Any] else { return nil }
        let title = NotificationParser.clean(request["titl"] as? String), body = NotificationParser.clean(request["body"] as? String)
        guard title != nil || body != nil else { return nil }
        guard let seconds = root["date"] as? Double, seconds.isFinite else { return nil }
        let date = seconds > 1_200_000_000 ? Date(timeIntervalSince1970: seconds) : Date(timeIntervalSinceReferenceDate: seconds)
        let requestID = NotificationParser.clean(request["iden"] as? String)
        let id = uuid.map { $0.map { String(format: "%02x", $0) }.joined() }.flatMap { $0.isEmpty ? nil : $0 }
            ?? NotificationParser.fingerprint(fields: [storeIdentity, String(recordID), bundleID, requestID])
        return .init(id: "store:" + id, appName: nil, bundleID: bundleID, title: title,
                     subtitle: NotificationParser.clean(request["subt"] as? String), body: body, receivedAt: date)
    }
    static func locate() -> URL {
        let current = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
        if #available(macOS 15, *) { return current }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/getconf"); task.arguments = ["DARWIN_USER_DIR"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        if (try? task.run()) != nil {
            task.waitUntilExit()
            if let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("com.apple.notificationcenter/db2/db")
            }
        }
        return current
    }
}
