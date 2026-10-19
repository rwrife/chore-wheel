import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum ChoreStoreError: Error, Equatable {
    case database(String)
    case unsupportedSchema(Int)
    case corruptLedger
}

/// Local SQLite event store. Projections are cached in memory after validated replay;
/// history uses a SQLite index. No network or shared app-group container.
public final class ChoreStore {
    private var db: OpaquePointer?
    private var ledger: ChoreLedger
    private var state: BoardState

    public static func applicationSupportURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        return directory.appendingPathComponent("ChoreWheel.sqlite")
    }

    /// Open sandboxed app data. A corrupt store throws; never replace it with an empty board.
    public static func openApplicationStore() throws -> ChoreStore {
        try ChoreStore(url: applicationSupportURL())
    }

    /// Pass nil for isolated in-memory tests; production uses openApplicationStore().
    public init(url: URL? = nil) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        let path = url?.path ?? ":memory:"
        let existingFile = url.map {
            ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) > 0
        } ?? false
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(path, &connection,
                                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if connection != nil { sqlite3_close(connection) }
            throw ChoreStoreError.database(message)
        }
        db = connection
        ledger = ChoreLedger()
        state = BoardState()
        do {
            try execute("PRAGMA foreign_keys = ON")
            let integrity = try scalar("PRAGMA integrity_check")
            guard integrity == "ok" else { throw ChoreStoreError.corruptLedger }
            let version = Int(try scalar("PRAGMA user_version") ?? "-1") ?? -1
            guard version == 0 || version == 1 else { throw ChoreStoreError.unsupportedSchema(version) }
            // Existing unversioned files might belong to another app. Do not overwrite them.
            guard version != 0 || !existingFile || url == nil else { throw ChoreStoreError.unsupportedSchema(0) }
            if version == 0 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("""
                        CREATE TABLE events (
                            sequence INTEGER PRIMARY KEY,
                            id TEXT NOT NULL UNIQUE,
                            chore_id TEXT,
                            payload BLOB NOT NULL
                        )
                        """)
                    try execute("CREATE INDEX events_chore ON events(chore_id, sequence)")
                    try execute("CREATE TRIGGER events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'immutable event'); END")
                    try execute("CREATE TRIGGER events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'immutable event'); END")
                    try execute("PRAGMA user_version = 1")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
            let rows = try readRows(choreID: nil)
            let events = rows.map(\.event)
            do { ledger = try ChoreLedger(events: events) }
            catch { throw ChoreStoreError.corruptLedger }
            // The chore_id index must agree with each payload's own identity;
            // a rewritten index would silently misattribute history.
            var openSwapChores: [UUID: UUID] = [:]
            for row in rows {
                let expectedID: UUID?
                switch row.event.payload {
                case .choreAdded(let chore), .choreUpdated(let chore): expectedID = chore.id
                case .assigned(let id, _, _), .completed(let id, _, _), .missed(let id, _, _),
                     .swapRequested(let id, _, _), .assignmentReleased(let id): expectedID = id
                case .completionUndone(let id):
                    expectedID = rows.first(where: { $0.event.id == id })?.choreID
                case .swapAccepted(let id, _, _), .swapDeclined(let id, _), .swapCancelled(let id, _):
                    expectedID = openSwapChores[id]
                default: expectedID = nil
                }
                guard row.choreID == expectedID else { throw ChoreStoreError.corruptLedger }
                switch row.event.payload {
                case .swapRequested(let choreID, _, _): openSwapChores[row.event.id] = choreID
                case .swapAccepted(let id, _, _), .swapDeclined(let id, _), .swapCancelled(let id, _): openSwapChores[id] = nil
                default: break
                }
            }
            state = ledger.boardState()
        } catch {
            sqlite3_close(connection)
            db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func boardState() -> BoardState { state }

    /// Due or overdue open assignments; sorted by day then stable chore title/id.
    public func today(on day: ChoreDay) -> [Assignment] {
        state.openAssignments.values.filter { $0.assignedOn <= day }.sorted {
            if $0.assignedOn != $1.assignedOn { return $0.assignedOn < $1.assignedOn }
            let a = state.chores[$0.choreID]?.title ?? ""
            let b = state.chores[$1.choreID]?.title ?? ""
            return a == b ? $0.choreID.uuidString < $1.choreID.uuidString : a < b
        }
    }

    public func fairness() -> [UUID: FairnessSummary] { state.fairness }

    public func history(choreID: UUID) throws -> [ChoreEvent] {
        try readEvents(choreID: choreID)
    }

    /// Read the complete append-only audit trail in durable insertion order.
    public func allEvents() throws -> [ChoreEvent] {
        try readEvents(choreID: nil)
    }

    /// Replacement is a single SQLite transaction. Invalid archives never
    /// touch disk; any insert failure rolls back both rows and in-memory state.
    public func replace(with archive: BoardArchive) throws {
        let events = try archive.validatedEvents()
        let previousLedger = ledger
        let previousState = state
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DROP TRIGGER events_no_delete")
            try execute("DELETE FROM events")
            try execute("CREATE TRIGGER events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'immutable event'); END")
            ledger = ChoreLedger()
            state = BoardState()
            for event in events { try appendToCurrentTransaction(event) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            ledger = previousLedger
            state = previousState
            throw error
        }
    }

    public func exportArchive() throws -> Data {
        try JSONEncoder().encode(BoardArchive(events: allEvents()))
    }

    public func append(_ event: ChoreEvent) throws {
        try appendToCurrentTransaction(event)
    }

    private func appendToCurrentTransaction(_ event: ChoreEvent) throws {
        var next = ledger
        try next.append(event) // Reject invalid transitions before any disk mutation.

        let data = try JSONEncoder().encode(event)
        let choreID: UUID?
        switch event.payload {
        case .choreAdded(let chore), .choreUpdated(let chore): choreID = chore.id
        case .assigned(let id, _, _), .completed(let id, _, _), .missed(let id, _, _),
             .swapRequested(let id, _, _), .assignmentReleased(let id): choreID = id
        case .completionUndone(let id): choreID = state.undoableCompletions[id]?.assignment.choreID
        case .swapAccepted(let requestID, _, _), .swapDeclined(let requestID, _), .swapCancelled(let requestID, _):
            choreID = state.pendingSwaps[requestID]?.choreID
        default: choreID = nil
        }
        let stmt = try prepare("INSERT INTO events(id, chore_id, payload) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        try bind(event.id.uuidString, to: stmt, at: 1)
        if let choreID { try bind(choreID.uuidString, to: stmt, at: 2) }
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw databaseError() }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        ledger = next
        state = next.boardState()
    }

    private func readEvents(choreID: UUID?) throws -> [ChoreEvent] {
        try readRows(choreID: choreID).map(\.event)
    }

    private func readRows(choreID: UUID?) throws -> [(event: ChoreEvent, choreID: UUID?)] {
        let stmt = try prepare(choreID == nil
            ? "SELECT id, chore_id, payload FROM events ORDER BY sequence"
            : "SELECT id, chore_id, payload FROM events WHERE chore_id = ? ORDER BY sequence")
        defer { sqlite3_finalize(stmt) }
        if let choreID { try bind(choreID.uuidString, to: stmt, at: 1) }
        var result: [(event: ChoreEvent, choreID: UUID?)] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let idPtr = sqlite3_column_text(stmt, 0),
                  let pointer = sqlite3_column_blob(stmt, 2) else { throw databaseError() }
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 2)))
            guard let event = try? JSONDecoder().decode(ChoreEvent.self, from: data),
                  String(cString: idPtr) == event.id.uuidString else {
                throw ChoreStoreError.corruptLedger
            }
            let rawChoreID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let indexedChoreID = rawChoreID.flatMap(UUID.init(uuidString:))
            guard rawChoreID == nil || indexedChoreID != nil else { throw ChoreStoreError.corruptLedger }
            result.append((event, indexedChoreID))
        }
        return result
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func scalar(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private func databaseError() -> ChoreStoreError {
        .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed database")
    }
}
