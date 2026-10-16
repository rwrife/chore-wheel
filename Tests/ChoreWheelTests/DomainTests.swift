#if canImport(ChoreWheelCore)
import ChoreWheelCore
#elseif canImport(ChoreWheel)
@testable import ChoreWheel
#endif
import Foundation
import Testing

private let ana = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let bo = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let cy = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
private let dishes = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
private let floors = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
private let unknown = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
private func day(_ n: Int) -> ChoreDay { ChoreDay(daysSinceEpoch: n) }
private func person(_ id: UUID, active: Bool = true) -> Member {
    Member(id: id, name: id == ana ? "Ana" : id == bo ? "Bo" : "Cy", isActive: active)
}
private func task(_ id: UUID, effort: Int = 10, eligible: Set<UUID> = [ana, bo, cy]) -> Chore {
    Chore(id: id, title: id == dishes ? "Dishes" : "Floors", area: "Home",
          effortMinutes: effort, cadence: .daily, eligibleMemberIDs: eligible, isActive: true)
}
private func seed() throws -> ChoreLedger {
    var ledger = ChoreLedger()
    try ledger.append(.memberAdded(person(ana)))
    try ledger.append(.memberAdded(person(bo)))
    try ledger.append(.memberAdded(person(cy)))
    try ledger.append(.choreAdded(task(dishes)))
    return ledger
}

@Suite("Chore domain")
struct DomainTests {
    @Test("cadence and model round-trip, interval is explicit")
    func model() throws {
        for cadence in [Cadence.daily, .weekly, .monthly, .everyDays(14), .adHoc] {
            #expect(try JSONDecoder().decode(Cadence.self, from: JSONEncoder().encode(cadence)) == cadence)
        }
        #expect(Cadence.everyDays(14).intervalDays == 14)
        #expect(Cadence.adHoc.intervalDays == nil)
        #expect(day(1).adding(2) == day(3))
        let chore = Chore(id: dishes, title: "Dishes", area: "Kitchen", effortMinutes: 25,
                          cadence: .weekly, eligibleMemberIDs: [ana, bo], isActive: false)
        #expect(try JSONDecoder().decode(Chore.self, from: JSONEncoder().encode(chore)) == chore)
        #expect(chore.effortMinutes == 25 && chore.eligibleMemberIDs == [ana, bo])
    }

    @Test("empty ledger has no members, chores, or assignment")
    func emptyState() {
        let state = ChoreLedger().boardState()
        #expect(state.members.isEmpty && state.chores.isEmpty)
        #expect(RotationEngine.nextAssignee(chore: task(dishes), state: state) == nil)
    }

    @Test("append/replay is deterministic across JSON restarts")
    func replay() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        try ledger.append(.completed(choreID: dishes, memberID: ana, on: day(2)))
        try ledger.append(.assigned(choreID: dishes, memberID: bo, on: day(3)))
        try ledger.append(.missed(choreID: dishes, memberID: bo, on: day(4)))
        let data = try JSONEncoder().encode(ledger.events)
        let copy = try ChoreLedger(events: JSONDecoder().decode([ChoreEvent].self, from: data))
        #expect(copy.events == ledger.events)
        #expect(copy.boardState() == ledger.boardState())
        #expect(copy.boardState().fairness[ana]?.completedEffortMinutes == 10)
        #expect(copy.boardState().fairness[bo]?.completedCount == 0)
        #expect(copy.boardState().fairness[bo]?.missedCount == 1)
        #expect(copy.boardState().openAssignments.isEmpty)
    }

    @Test("invalid references, duplicate event IDs, and duplicate entities are rejected")
    func validation() throws {
        var ledger = try seed()
        let event = ledger.events[0]
        #expect(throws: LedgerError.duplicateEventID(event.id)) { try ledger.append(event) }
        #expect(throws: LedgerError.memberAlreadyExists(ana)) {
            try ledger.append(.memberAdded(person(ana)))
        }
        #expect(throws: LedgerError.choreAlreadyExists(dishes)) {
            try ledger.append(.choreAdded(task(dishes)))
        }
        #expect(throws: LedgerError.unknownMember(unknown)) {
            try ledger.append(.assigned(choreID: dishes, memberID: unknown, on: day(1)))
        }
        #expect(throws: LedgerError.unknownChore(unknown)) {
            try ledger.append(.assigned(choreID: unknown, memberID: ana, on: day(1)))
        }
        try ledger.append(.memberUpdated(person(bo, active: false)))
        #expect(throws: LedgerError.inactiveMember(bo)) {
            try ledger.append(.assigned(choreID: dishes, memberID: bo, on: day(1)))
        }
        #expect(throws: LedgerError.memberNotEligible(choreID: floors, memberID: cy)) {
            try ledger.append(.choreAdded(task(floors, eligible: [ana, bo])))
            try ledger.append(.assigned(choreID: floors, memberID: cy, on: day(1)))
        }
    }

    @Test("swap accept requires recipient's consent, reassigns; decline preserves assignee")
    func swaps() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        let request = ChoreEvent(payload: .swapRequested(choreID: dishes, fromMemberID: ana, toMemberID: bo))
        try ledger.append(request)
        #expect(ledger.boardState().pendingSwaps.count == 1)
        #expect(throws: LedgerError.swapAlreadyPending(choreID: dishes)) {
            try ledger.append(.swapRequested(choreID: dishes, fromMemberID: ana, toMemberID: cy))
        }
        #expect(throws: LedgerError.wrongSwapRecipient(ana)) {
            try ledger.append(.swapAccepted(requestEventID: request.id, byMemberID: ana, on: day(1)))
        }
        try ledger.append(.swapAccepted(requestEventID: request.id, byMemberID: bo, on: day(1)))
        #expect(ledger.boardState().openAssignments[dishes]?.memberID == bo)
        #expect(ledger.boardState().pendingSwaps.isEmpty)
        try ledger.append(.completed(choreID: dishes, memberID: bo, on: day(2)))
        #expect(ledger.boardState().fairness[ana]?.completedCount == 0)
        #expect(ledger.boardState().fairness[ana]?.missedCount == 0)
        #expect(ledger.boardState().fairness[bo]?.completedEffortMinutes == 10)
        try ledger.append(.assigned(choreID: dishes, memberID: bo, on: day(3)))
        let declined = ChoreEvent(payload: .swapRequested(choreID: dishes, fromMemberID: bo, toMemberID: ana))
        try ledger.append(declined)
        try ledger.append(.swapDeclined(requestEventID: declined.id, byMemberID: ana))
        #expect(ledger.boardState().openAssignments[dishes]?.memberID == bo)
        #expect(ledger.boardState().pendingSwaps.isEmpty)
        #expect(throws: LedgerError.unknownSwapRequest(declined.id)) {
            try ledger.append(.swapAccepted(requestEventID: declined.id, byMemberID: ana, on: day(3)))
        }
    }

    @Test("least completed-plus-open effort wins; least-recent assignment breaks equal load ties")
    func rotation() throws {
        var ledger = try seed()
        #expect(RotationEngine.nextAssignee(chore: task(dishes), state: ledger.boardState()) == ana)
        try ledger.append(.choreAdded(task(floors, effort: 30)))
        try ledger.append(.assigned(choreID: floors, memberID: ana, on: day(1)))
        try ledger.append(.completed(choreID: floors, memberID: ana, on: day(1)))
        try ledger.append(.assigned(choreID: dishes, memberID: bo, on: day(1)))
        try ledger.append(.completed(choreID: dishes, memberID: bo, on: day(1)))
        #expect(RotationEngine.nextAssignee(chore: task(dishes), state: ledger.boardState()) == cy)
        #expect(RotationEngine.nextAssignee(chore: task(dishes, eligible: [ana, bo]), state: ledger.boardState()) == bo)
        try ledger.append(.assigned(choreID: dishes, memberID: cy, on: day(2)))
        // Cy's uncompleted 10 minutes count toward load, no auto-completion credit.
        #expect(ledger.boardState().fairness[cy]?.completedEffortMinutes == 0)
        #expect(RotationEngine.nextAssignee(chore: task(floors), state: ledger.boardState()) == bo)
        try ledger.append(.completed(choreID: dishes, memberID: cy, on: day(2)))
        // Bo and Cy each completed 10; Bo assigned earlier, so Bo breaks tie.
        #expect(RotationEngine.nextAssignee(chore: task(dishes), state: ledger.boardState()) == bo)
    }

    @Test("new members join with zero load; deactivated ones retain history but never selected")
    func membership() throws {
        var ledger = ChoreLedger()
        try ledger.append(.memberAdded(person(ana)))
        try ledger.append(.choreAdded(task(dishes, eligible: [ana])))
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        try ledger.append(.completed(choreID: dishes, memberID: ana, on: day(1)))
        // Bo joins mid-history with zero load and wins the next rotation.
        try ledger.append(.memberAdded(person(bo)))
        try ledger.append(.choreUpdated(task(dishes, eligible: [ana, bo])))
        #expect(RotationEngine.nextAssignee(chore: task(dishes, eligible: [ana, bo]), state: ledger.boardState()) == bo)
        // Deactivating Bo removes him from selection without erasing history.
        try ledger.append(.assigned(choreID: dishes, memberID: bo, on: day(2)))
        try ledger.append(.completed(choreID: dishes, memberID: bo, on: day(2)))
        try ledger.append(.memberUpdated(person(bo, active: false)))
        #expect(RotationEngine.nextAssignee(chore: task(dishes, eligible: [ana, bo]), state: ledger.boardState()) == ana)
        try ledger.append(.memberUpdated(person(ana, active: false)))
        #expect(RotationEngine.nextAssignee(chore: task(dishes, eligible: [ana, bo]), state: ledger.boardState()) == nil)
        #expect(ledger.boardState().fairness[ana]?.completedEffortMinutes == 10)
        #expect(ledger.boardState().fairness[bo]?.completedEffortMinutes == 10)
    }

    @Test("replay rejects an invalid tail instead of returning partial state")
    func replayRejectsInvalidTail() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        var events = ledger.events
        events.append(ChoreEvent(payload: .assigned(choreID: unknown, memberID: ana, on: day(2))))
        #expect(throws: LedgerError.unknownChore(unknown)) {
            _ = try ChoreLedger(events: events)
        }
    }

    @Test("cannot overwrite an open assignment or accept swap after chore completes")
    func assignmentGuards() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        #expect(throws: LedgerError.alreadyAssigned(dishes)) {
            try ledger.append(.assigned(choreID: dishes, memberID: bo, on: day(2)))
        }
        let request = ChoreEvent(payload: .swapRequested(choreID: dishes, fromMemberID: ana, toMemberID: bo))
        try ledger.append(request)
        try ledger.append(.completed(choreID: dishes, memberID: ana, on: day(2)))
        #expect(ledger.boardState().pendingSwaps.isEmpty)
        #expect(throws: LedgerError.unknownSwapRequest(request.id)) {
            try ledger.append(.swapAccepted(requestEventID: request.id, byMemberID: bo, on: day(2)))
        }
    }

    @Test("effort is frozen on assignment, not rewritten by later chore edits")
    func effortSnapshot() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        try ledger.append(.choreUpdated(task(dishes, effort: 50)))
        #expect(RotationEngine.nextAssignee(chore: task(floors), state: ledger.boardState()) == bo)
        try ledger.append(.completed(choreID: dishes, memberID: ana, on: day(2)))
        #expect(ledger.boardState().fairness[ana]?.completedEffortMinutes == 10)
    }

    @Test("swap consent fails if recipient became inactive")
    func inactiveRecipient() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        let request = ChoreEvent(payload: .swapRequested(choreID: dishes, fromMemberID: ana, toMemberID: bo))
        try ledger.append(request)
        try ledger.append(.memberUpdated(person(bo, active: false)))
        #expect(throws: LedgerError.inactiveMember(bo)) {
            try ledger.append(.swapAccepted(requestEventID: request.id, byMemberID: bo, on: day(2)))
        }
    }

    @Test("completion undo restores frozen assignment and fairness within five seconds")
    func undoCompletion() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        let completion = ChoreEvent(id: UUID(), timestamp: Date(timeIntervalSince1970: 100),
                                    payload: .completed(choreID: dishes, memberID: ana, on: day(1)))
        try ledger.append(completion)
        let undo = ChoreEvent(timestamp: Date(timeIntervalSince1970: 103),
                              payload: .completionUndone(completionEventID: completion.id))
        try ledger.append(undo)
        let state = ledger.boardState()
        #expect(state.openAssignments[dishes]?.memberID == ana)
        #expect(state.openAssignments[dishes]?.effortMinutes == 10)
        #expect(state.fairness[ana]?.completedCount == 0)
        #expect(state.fairness[ana]?.completedEffortMinutes == 0)
        #expect(try ChoreLedger(events: ledger.events).boardState() == state)
        #expect(throws: LedgerError.undoUnavailable(completion.id)) {
            try ledger.append(ChoreEvent(timestamp: Date(timeIntervalSince1970: 104),
                payload: .completionUndone(completionEventID: completion.id)))
        }
    }

    @Test("undo rejects expiry and cannot alter completed history on failure")
    func undoExpiry() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(1)))
        let completion = ChoreEvent(id: UUID(), timestamp: Date(timeIntervalSince1970: 100),
                                    payload: .completed(choreID: dishes, memberID: ana, on: day(1)))
        try ledger.append(completion)
        let count = ledger.events.count
        #expect(throws: LedgerError.undoExpired(completion.id)) {
            try ledger.append(ChoreEvent(timestamp: Date(timeIntervalSince1970: 106),
                payload: .completionUndone(completionEventID: completion.id)))
        }
        #expect(ledger.events.count == count)
        #expect(ledger.boardState().fairness[ana]?.completedCount == 1)
    }

    @Test("same event stream replays to the same rotation winner")
    func stableReplay() throws {
        var ledger = try seed()
        try ledger.append(.assigned(choreID: dishes, memberID: ana, on: day(2)))
        let copy = try ChoreLedger(events: ledger.events)
        #expect(RotationEngine.nextAssignee(chore: task(floors), state: copy.boardState()) == bo)
        #expect(RotationEngine.nextAssignee(chore: task(floors), state: copy.boardState()) ==
                RotationEngine.nextAssignee(chore: task(floors), state: ledger.boardState()))
    }
}
