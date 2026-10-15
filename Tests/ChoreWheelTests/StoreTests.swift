#if canImport(ChoreWheelCore)
import ChoreWheelCore
#elseif canImport(ChoreWheel)
@testable import ChoreWheel
#endif
import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private let memberID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let choreID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!

/// Runs raw SQL against a closed store file to simulate tampering/foreign files.
private func rawSQL(_ sql: String, at url: URL) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
}

private func tempStoreURL() throws -> (dir: URL, url: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("board.sqlite"))
}

@Suite("Local store")
struct StoreTests {
    @Test("in-memory databases are isolated")
    func isolated() throws {
        let first = try ChoreStore()
        try first.append(ChoreEvent(payload: .memberAdded(Member(id: memberID, name: "Ana"))))
        #expect(first.boardState().members.count == 1)
        #expect(try ChoreStore().boardState().members.isEmpty)
    }

    @Test("file survives reopen, replays projections and history")
    func reopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("board.sqlite")
        do {
            let store = try ChoreStore(url: url)
            try store.append(ChoreEvent(payload: .memberAdded(Member(id: memberID, name: "Ana"))))
            try store.append(ChoreEvent(payload: .choreAdded(Chore(id: choreID, title: "Dishes",
                area: "Kitchen", effortMinutes: 20, cadence: .daily, eligibleMemberIDs: [memberID]))))
            try store.append(ChoreEvent(payload: .assigned(choreID: choreID, memberID: memberID,
                                                           on: ChoreDay(daysSinceEpoch: 5))))
            #expect(store.today(on: ChoreDay(daysSinceEpoch: 4)).isEmpty)
            #expect(store.today(on: ChoreDay(daysSinceEpoch: 5)).count == 1)
        }
        let reopened = try ChoreStore(url: url)
        #expect(reopened.today(on: ChoreDay(daysSinceEpoch: 6)).count == 1)
        #expect(try reopened.history(choreID: choreID).count == 2)
        try reopened.append(ChoreEvent(payload: .completed(choreID: choreID, memberID: memberID,
                                                            on: ChoreDay(daysSinceEpoch: 6))))
        #expect(reopened.today(on: ChoreDay(daysSinceEpoch: 6)).isEmpty)
        #expect(reopened.fairness()[memberID]?.completedEffortMinutes == 20)
        #expect(try reopened.history(choreID: choreID).count == 3)
        #expect(try ChoreStore(url: url).fairness()[memberID]?.completedCount == 1)
    }

    @Test("unsupported schema and corrupted payload reject without replacing file")
    func corruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("board.sqlite")
        do { _ = try ChoreStore(url: url) }
        let original = try Data(contentsOf: url)
        // A truncated header is not a new/empty database; opening must fail closed.
        try Data("not a sqlite file".utf8).write(to: url, options: .atomic)
        #expect(throws: ChoreStoreError.self) { _ = try ChoreStore(url: url) }
        #expect(try Data(contentsOf: url) == Data("not a sqlite file".utf8))
        try original.write(to: url, options: .atomic)
        #expect(try ChoreStore(url: url).boardState().members.isEmpty)
    }

    @Test("events are append-only and a rewritten chore index is rejected")
    func tamper() throws {
        let (dir, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try ChoreStore(url: url)
            try store.append(ChoreEvent(payload: .memberAdded(Member(id: memberID, name: "Ana"))))
            try store.append(ChoreEvent(payload: .choreAdded(Chore(id: choreID, title: "Dishes",
                area: "Kitchen", effortMinutes: 20, cadence: .daily, eligibleMemberIDs: [memberID]))))
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "DELETE FROM events", nil, nil, nil) != SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE events SET chore_id = NULL", nil, nil, nil) != SQLITE_OK)
        sqlite3_close(db)
        // Bypass the triggers the way a damaged/edited file could.
        try rawSQL("DROP TRIGGER events_no_update; UPDATE events SET chore_id = '\(UUID().uuidString)' WHERE chore_id IS NOT NULL",
                   at: url)
        #expect(throws: ChoreStoreError.corruptLedger) { _ = try ChoreStore(url: url) }
    }

    @Test("pre-existing non-Chore-Wheel database is never adopted")
    func foreignDatabase() throws {
        let (dir, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try rawSQL("CREATE TABLE notes(x TEXT); INSERT INTO notes VALUES ('keep me')", at: url)
        #expect(throws: ChoreStoreError.unsupportedSchema(0)) { _ = try ChoreStore(url: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "SELECT x FROM notes", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "SELECT * FROM events", nil, nil, nil) != SQLITE_OK)
    }

    @Test("fresh database migrates to schema v1 and reopens without duplicating tables")
    func migration() throws {
        let (dir, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try ChoreStore(url: url) }
        do { _ = try ChoreStore(url: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)
    }

    @Test("future schema versions fail closed")
    func futureSchema() throws {
        let (dir, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try ChoreStore(url: url) }
        try rawSQL("PRAGMA user_version = 99", at: url)
        #expect(throws: ChoreStoreError.unsupportedSchema(99)) { _ = try ChoreStore(url: url) }
    }

    @Test("a rejected event never reaches disk")
    func rejectedEventNotPersisted() throws {
        let (dir, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ChoreStore(url: url)
        #expect(throws: LedgerError.self) {
            try store.append(ChoreEvent(payload: .assigned(choreID: choreID, memberID: memberID,
                                                           on: ChoreDay(daysSinceEpoch: 1))))
        }
        #expect(try ChoreStore(url: url).history(choreID: choreID).isEmpty)
    }
}
