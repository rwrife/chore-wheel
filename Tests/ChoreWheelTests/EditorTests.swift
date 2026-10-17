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

private func seedStore() throws -> ChoreStore {
    let store = try ChoreStore()
    try store.append(ChoreEvent(payload: .memberAdded(Member(id: ana, name: "Ana"))))
    try store.append(ChoreEvent(payload: .memberAdded(Member(id: bo, name: "Bo"))))
    try store.append(ChoreEvent(payload: .memberAdded(Member(id: cy, name: "Cy"))))
    return store
}

@Suite("Board editor & validation")
struct EditorTests {
    @Test("member input validation rejects empty names and duplicates, allows valid renames")
    func memberValidation() throws {
        let store = try seedStore()
        #expect(throws: ManagementError.emptyName) {
            try BoardEditor.addMember(named: "   \n\t", to: store)
        }
        #expect(throws: ManagementError.memberNameTaken("Ana")) {
            try BoardEditor.addMember(named: "Ana", to: store)
        }
        let dan = try BoardEditor.addMember(named: "Dan", to: store)
        #expect(store.boardState().members[dan]?.name == "Dan")
        #expect(throws: ManagementError.emptyName) {
            try BoardEditor.renameMember(dan, to: "", in: store)
        }
        #expect(throws: ManagementError.memberNameTaken("Bo")) {
            try BoardEditor.renameMember(dan, to: "Bo", in: store)
        }
        try BoardEditor.renameMember(dan, to: "Danny", in: store)
        #expect(store.boardState().members[dan]?.name == "Danny")
    }

    @Test("chore input validation guards title, area, effort, interval, and eligible members")
    func choreValidation() throws {
        let store = try seedStore()
        let missing = UUID()

        var draft = BoardEditor.ChoreDraft(title: "", area: "Kitchen", effortMinutes: 15,
                                           cadence: .daily, eligibleMemberIDs: [ana])
        #expect(throws: ManagementError.emptyTitle) { try BoardEditor.addChore(draft, to: store) }

        draft.title = "Dishes"
        draft.area = "  "
        #expect(throws: ManagementError.emptyArea) { try BoardEditor.addChore(draft, to: store) }

        draft.area = "Kitchen"
        draft.effortMinutes = 0
        #expect(throws: ManagementError.nonPositiveEffort) { try BoardEditor.addChore(draft, to: store) }

        draft.effortMinutes = 15
        draft.cadence = .everyDays(0)
        #expect(throws: ManagementError.zeroDayInterval) { try BoardEditor.addChore(draft, to: store) }

        draft.cadence = .weekly
        draft.eligibleMemberIDs = []
        #expect(throws: ManagementError.noEligibleMembers) { try BoardEditor.addChore(draft, to: store) }

        draft.eligibleMemberIDs = [missing]
        #expect(throws: ManagementError.unknownEligibleMember(missing)) { try BoardEditor.addChore(draft, to: store) }

        draft.eligibleMemberIDs = [ana, bo]
        let id = try BoardEditor.addChore(draft, to: store)
        #expect(store.boardState().chores[id]?.title == "Dishes")
        // Newly added active chore was automatically assigned to the rotation winner.
        #expect(store.boardState().openAssignments[id]?.memberID == ana)

        // Days-of-week cadence round-trips and survives validation.
        let weeklyOn = BoardEditor.ChoreDraft(title: "Recycling", area: "Patio", effortMinutes: 5,
                                              cadence: .weeklyOn(days: [3, 7]), eligibleMemberIDs: [cy])
        let recycling = try BoardEditor.addChore(weeklyOn, to: store)
        let stored = store.boardState().chores[recycling]!
        #expect(stored.cadence.weekdays == [3, 7])
        #expect(try JSONDecoder().decode(Cadence.self, from: JSONEncoder().encode(stored.cadence)) == stored.cadence)
    }

    @Test("deactivating a member releases held chores and refuses if they are the sole eligible person")
    func memberDeactivation() throws {
        let store = try seedStore()
        let yardDraft = BoardEditor.ChoreDraft(title: "Yard", area: "Outside", effortMinutes: 45,
                                               cadence: .weekly, eligibleMemberIDs: [ana])
        let yard = try BoardEditor.addChore(yardDraft, to: store)
        #expect(store.boardState().openAssignments[yard]?.memberID == ana)

        // Cannot deactivate Ana while she is the sole eligible person for Yard.
        #expect(throws: ManagementError.memberNotEligibleForChores(memberID: ana, choreIDs: [yard])) {
            try BoardEditor.setMemberActive(ana, active: false, in: store)
        }

        // Add Bo to eligibility, then Ana can be deactivated; the released
        // chore re-enters rotation and lands on Bo with an honest audit trail.
        let widened = BoardEditor.ChoreDraft(title: "Yard", area: "Outside", effortMinutes: 45,
                                             cadence: .weekly, eligibleMemberIDs: [ana, bo])
        try BoardEditor.applyEdit(to: yard, draft: widened, in: store)
        try BoardEditor.setMemberActive(ana, active: false, in: store)

        let state = store.boardState()
        #expect(state.members[ana]?.isActive == false)
        #expect(state.openAssignments[yard]?.memberID == bo)
        // Release is not counted as a miss and the reassignment is auditable.
        #expect(state.fairness[ana]?.missedCount == 0)
        let payloads = try store.allEvents().map(\.payload)
        #expect(payloads.contains(.assignmentReleased(choreID: yard)))
        // History survives a reopen-equal replay.
        #expect(try ChoreLedger(events: store.allEvents()).boardState() == state)
    }

    @Test("editing an active chore re-evaluates assignment and retains audit logs")
    func choreEditing() throws {
        let store = try seedStore()
        let draft = BoardEditor.ChoreDraft(title: "Trash", area: "Outside", effortMinutes: 10,
                                           cadence: .weekly, eligibleMemberIDs: [ana, bo])
        let choreID = try BoardEditor.addChore(draft, to: store)
        let firstWinner = store.boardState().openAssignments[choreID]!.memberID
        #expect(firstWinner == ana)

        // Complete the chore once to prove history is retained on deactivation.
        let today = ChoreDay(daysSinceEpoch: 100)
        try store.append(ChoreEvent(payload: .completed(choreID: choreID, memberID: ana, on: today)))
        #expect(store.boardState().fairness[ana]?.completedCount == 1)

        // Deactivating the chore retains its completions in the ledger.
        try BoardEditor.setChoreActive(choreID, active: false, in: store)
        #expect(store.boardState().chores[choreID]?.isActive == false)
        #expect(store.boardState().fairness[ana]?.completedCount == 1)
        #expect(store.boardState().openAssignments[choreID] == nil)

        // Reactivating it re-assigns to the next rotation candidate (Bo, who has 0 effort).
        try BoardEditor.setChoreActive(choreID, active: true, in: store)
        #expect(store.boardState().chores[choreID]?.isActive == true)
        #expect(store.boardState().openAssignments[choreID]?.memberID == bo)
    }

    @Test("cadence next-due math: intervals, weekday pins, ad-hoc stays unassigned")
    func nextDueMath() {
        let d = ChoreDay(daysSinceEpoch: 0) // epoch day = ISO Thursday (4)
        #expect(BoardEditor.nextDueDay(after: d, cadence: .daily) == ChoreDay(daysSinceEpoch: 1))
        #expect(BoardEditor.nextDueDay(after: d, cadence: .everyDays(10)) == ChoreDay(daysSinceEpoch: 10))
        #expect(BoardEditor.nextDueDay(after: d, cadence: .adHoc) == nil)
        // Pin to Thursday: next Thursday after day 0 is day 7.
        #expect(BoardEditor.nextDueDay(after: d, cadence: .weeklyOn(days: [4])) == ChoreDay(daysSinceEpoch: 7))
        // Pin to Friday (5): day 1.
        #expect(BoardEditor.nextDueDay(after: d, cadence: .weeklyOn(days: [5])) == ChoreDay(daysSinceEpoch: 1))
        // Empty pin set never schedules.
        #expect(BoardEditor.nextDueDay(after: d, cadence: .weeklyOn(days: [])) == nil)
    }

    @Test("repeat materializes only once due, rotates, and leaves the undo window intact")
    func recurrence() throws {
        let store = try seedStore()
        let draft = BoardEditor.ChoreDraft(title: "Dishes", area: "Kitchen", effortMinutes: 10,
                                           cadence: .daily, eligibleMemberIDs: [ana, bo])
        let choreID = try BoardEditor.addChore(draft, to: store)
        let assigned = ChoreDay(daysSinceEpoch: 5)
        // Force the assignment day for deterministic cadence math.
        try store.append(ChoreEvent(payload: .assignmentReleased(choreID: choreID)))
        try store.append(ChoreEvent(payload: .assigned(choreID: choreID, memberID: ana, on: assigned)))

        let completion = ChoreEvent(id: UUID(), timestamp: Date(timeIntervalSince1970: 0),
                                    payload: .completed(choreID: choreID, memberID: ana, on: assigned))
        try store.append(completion)

        // Same day: not due yet, so nothing is invented and undo stays open.
        #expect(try BoardEditor.materializeDue(on: assigned, in: store) == 0)
        #expect(store.boardState().openAssignments[choreID] == nil)
        let undo = ChoreEvent(timestamp: Date(timeIntervalSince1970: 2),
                              payload: .completionUndone(completionEventID: completion.id))
        try store.append(undo) // undo window survived the refresh-equivalent
        #expect(store.boardState().openAssignments[choreID]?.memberID == ana)

        // Complete again cleanly, then the next day the rotation re-enters on Bo.
        try store.append(ChoreEvent(payload: .completed(choreID: choreID, memberID: ana, on: assigned)))
        #expect(try BoardEditor.materializeDue(on: assigned.adding(1), in: store) == 1)
        let open = store.boardState().openAssignments[choreID]
        #expect(open?.memberID == bo)
        #expect(open?.assignedOn == assigned.adding(1))

        // A paused chore is not re-scheduled, even though its cadence is due.
        try store.append(ChoreEvent(payload: .completed(choreID: choreID, memberID: bo, on: assigned.adding(1))))
        try BoardEditor.setChoreActive(choreID, active: false, in: store)
        #expect(try BoardEditor.materializeDue(on: assigned.adding(2), in: store) == 0)
        #expect(store.boardState().openAssignments[choreID] == nil)
    }
}
