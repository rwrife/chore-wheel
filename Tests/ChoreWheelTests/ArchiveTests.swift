#if canImport(ChoreWheelCore)
import ChoreWheelCore
#elseif canImport(ChoreWheel)
@testable import ChoreWheel
#endif
import Foundation
import Testing

private let ana = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let bo = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let dishes = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
private func day(_ n: Int) -> ChoreDay { ChoreDay(daysSinceEpoch: n) }
private func event(_ payload: ChoreEventPayload, at time: TimeInterval = 0) -> ChoreEvent {
    ChoreEvent(timestamp: Date(timeIntervalSince1970: time), payload: payload)
}
private func seeded() throws -> ChoreStore {
    let store = try ChoreStore()
    try store.append(event(.memberAdded(Member(id: ana, name: "Ana"))))
    try store.append(event(.memberAdded(Member(id: bo, name: "Bo"))))
    try store.append(event(.choreAdded(Chore(id: dishes, title: "Dishes", area: "Kitchen",
        effortMinutes: 20, cadence: .daily, eligibleMemberIDs: [ana, bo]))))
    return store
}

private func tempDatabase() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("board.sqlite")
}

@Suite("Fairness and portable archive")
struct ArchiveTests {
    @Test("time windows respect UTC ISO week/month/year and include all members")
    func windows() throws {
        let store = try seeded()
        let jan31 = day(20484) // 2026-01-31 UTC
        let feb2 = day(20486) // 2026-02-02 UTC, new ISO week
        try store.append(event(.assigned(choreID: dishes, memberID: ana, on: jan31)))
        try store.append(event(.completed(choreID: dishes, memberID: ana, on: jan31)))
        try store.append(event(.assigned(choreID: dishes, memberID: bo, on: feb2)))
        try store.append(event(.completed(choreID: dishes, memberID: bo, on: feb2)))
        let now = Date(timeIntervalSince1970: Double(feb2.daysSinceEpoch) * 86400 + 3600)
        let events = try store.allEvents()
        let week = try FairnessReport.rows(events: events, asOf: now, window: .week)
        #expect(week.map(\.completedCount) == [0, 1])
        #expect(week.map(\.completedEffortMinutes) == [0, 20])
        let year = try FairnessReport.rows(events: events, asOf: now, window: .year)
        #expect(year.map(\.completedCount) == [1, 1])
        let month = try FairnessReport.rows(events: events, asOf: now, window: .month)
        #expect(month.map(\.completedCount) == [0, 1])
        #expect(try FairnessReport.rows(events: events, asOf: now, window: .allTime).map(\.completedCount) == [1, 1])
    }

    @Test("renames and effort edits do not rewrite credit; undo cancels credit; swaps credit recipient")
    func credit() throws {
        let store = try seeded()
        try store.append(event(.assigned(choreID: dishes, memberID: ana, on: day(1))))
        try store.append(event(.choreUpdated(Chore(id: dishes, title: "Dishes", area: "Kitchen",
            effortMinutes: 50, cadence: .daily, eligibleMemberIDs: [ana, bo]))))
        let request = event(.swapRequested(choreID: dishes, fromMemberID: ana, toMemberID: bo))
        try store.append(request)
        try store.append(event(.swapAccepted(requestEventID: request.id, byMemberID: bo, on: day(1))))
        let completed = event(.completed(choreID: dishes, memberID: bo, on: day(1)), at: 100)
        try store.append(completed)
        let now = Date(timeIntervalSince1970: 200_000)
        let first = try FairnessReport.rows(events: store.allEvents(), asOf: now, window: .allTime)
        #expect(first.map(\.completedEffortMinutes) == [0, 20])
        try store.append(event(.completionUndone(completionEventID: completed.id), at: 102))
        let afterUndo = try FairnessReport.rows(events: store.allEvents(), asOf: now, window: .allTime)
        #expect(afterUndo.map(\.completedCount) == [0, 0])
        try store.append(event(.completed(choreID: dishes, memberID: bo, on: day(2)), at: 103))
        #expect(try FairnessReport.rows(events: store.allEvents(), asOf: now, window: .allTime)
            .map(\.completedEffortMinutes) == [0, 20])
    }

    @Test("round trip replaces in one transaction; corrupt version/history keep original state")
    func importExport() throws {
        let original = try seeded()
        let data = try original.exportArchive()
        let archive = try JSONDecoder().decode(BoardArchive.self, from: data)
        #expect(archive.version == 1)
        #expect(archive.events == (try original.allEvents()))
        let url = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = try ChoreStore(url: url)
        let previous = event(.memberAdded(Member(id: UUID(), name: "Old")))
        try target.append(previous)
        #expect(throws: ArchiveError.invalidHistory) {
            _ = try BoardArchive(events: [event(.assigned(choreID: dishes, memberID: ana, on: day(1)))]).validatedEvents()
        }
        let bad = BoardArchive(events: [event(.assigned(choreID: dishes, memberID: ana, on: day(1)))])
        #expect(throws: ArchiveError.invalidHistory) { try target.replace(with: bad) }
        #expect(try target.allEvents() == [previous])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var changed = json
        changed["version"] = 999
        let future = try JSONDecoder().decode(BoardArchive.self, from: JSONSerialization.data(withJSONObject: changed))
        #expect(throws: ArchiveError.unsupportedVersion) { try target.replace(with: future) }
        #expect(try target.allEvents() == [previous])
        try target.replace(with: archive)
        #expect(try target.allEvents() == archive.events)
        #expect(target.boardState() == original.boardState())
        #expect(try ChoreStore(url: url).allEvents() == archive.events)
        // Replace again: trigger and sequence both remain valid after reopen.
        try target.replace(with: archive)
        #expect(try ChoreStore(url: url).allEvents() == archive.events)
        try FileManager.default.removeItem(at: url)
    }

    @Test("redacted share excludes names, audit metadata, and edit history")
    func share() throws {
        let store = try seeded()
        try store.append(event(.assigned(choreID: dishes, memberID: ana, on: day(1))))
        let redacted = BoardShare.text(state: store.boardState(), redactNames: true)
        #expect(redacted.contains("Dishes — Member 1"))
        #expect(!redacted.contains("Ana"))
        #expect(!redacted.contains(ana.uuidString))
        #expect(!redacted.contains("Kitchen"))
        #expect(BoardShare.text(state: store.boardState(), redactNames: false).contains("Dishes — Ana"))
    }
}
