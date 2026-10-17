import Foundation

// MARK: - Management validation errors

/// Input-validation failures surfaced by `BoardEditor`. These are rejected
/// before any event is appended, so the ledger never holds invalid edits.
public enum ManagementError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyTitle
    case emptyArea
    case nonPositiveEffort
    case noEligibleMembers
    case unknownEligibleMember(UUID)
    case zeroDayInterval
    case invalidWeekdays
    case memberNameTaken(String)
    case memberNotEligibleForChores(memberID: UUID, choreIDs: [UUID])

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Name cannot be empty."
        case .emptyTitle: "Chore title cannot be empty."
        case .emptyArea: "Room or area cannot be empty."
        case .nonPositiveEffort: "Estimated effort must be at least one minute."
        case .noEligibleMembers: "A chore needs at least one eligible member."
        case .unknownEligibleMember: "One of the selected members no longer exists."
        case .zeroDayInterval: "Repeat interval must be at least one day."
        case .invalidWeekdays: "Pick at least one weekday for a days-of-week repeat."
        case .memberNameTaken(let name): "A profile named \(name) already exists."
        case .memberNotEligibleForChores: "That member is still the only eligible person for some chores."
        }
    }
}

// MARK: - Cadence editor helpers

extension Cadence {
    /// Editor segment order for the cadence picker.
    public static let editorCases: [Cadence] = [.daily, .weekly, .monthly, .everyDays(1), .adHoc]

    /// Day count for `.everyDays`, else nil (picker exposes a stepper for it).
    public var editorIntervalDays: Int? {
        if case .everyDays(let days) = self { days } else { nil }
    }
}

// MARK: - Board editor

/// Write-side seam for management screens (issue #5). All validation happens
/// here, before any append, so the append-only ledger only ever receives
/// well-formed edits: no empty names, zero cadences, zero effort, or zero
/// eligible assignees. Deactivation never deletes history; open assignments
/// orphaned by an edit are immediately released back to the rotation engine
/// so the Today board and rotation reflect changes at once.
public enum BoardEditor {
    private static var whitespace: CharacterSet { .whitespacesAndNewlines }

    public static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: whitespace)
    }

    // MARK: Members

    public static func addMember(named name: String, to store: ChoreStore, now: Date = Date()) throws -> UUID {
        let clean = trimmed(name)
        guard !clean.isEmpty else { throw ManagementError.emptyName }
        let state = store.boardState()
        guard !state.members.values.contains(where: { $0.isActive && $0.name == clean }) else {
            throw ManagementError.memberNameTaken(clean)
        }
        let member = Member(id: UUID(), name: clean, isActive: true)
        try store.append(ChoreEvent(timestamp: now, payload: .memberAdded(member)))
        return member.id
    }

    public static func renameMember(_ memberID: UUID, to name: String, in store: ChoreStore, now: Date = Date()) throws {
        let clean = trimmed(name)
        guard !clean.isEmpty else { throw ManagementError.emptyName }
        let state = store.boardState()
        guard let current = state.members[memberID] else { throw LedgerError.unknownMember(memberID) }
        guard !state.members.values.contains(where: {
            $0.id != memberID && $0.isActive && $0.name == clean
        }) else {
            throw ManagementError.memberNameTaken(clean)
        }
        var updated = current
        updated.name = clean
        try store.append(ChoreEvent(timestamp: now, payload: .memberUpdated(updated)))
    }

    /// Activate/deactivate a profile. Deactivation keeps all fairness history
    /// and releases any open assignments (and their pending swaps) the member
    /// held so the chore can be reassigned; the member is validated out of
    /// being the sole eligible assignee of any active chore first.
    public static func setMemberActive(_ memberID: UUID, active: Bool, in store: ChoreStore, now: Date = Date()) throws {
        let before = store.boardState()
        guard let current = before.members[memberID] else { throw LedgerError.unknownMember(memberID) }
        if !active {
            let stranded = before.chores.values
                .filter { $0.isActive && $0.eligibleMemberIDs.contains(memberID) }
                .filter { chore in
                    !chore.eligibleMemberIDs.contains(where: {
                        $0 != memberID && before.members[$0]?.isActive == true
                    })
                }
                .map(\.id)
            guard stranded.isEmpty else {
                throw ManagementError.memberNotEligibleForChores(memberID: memberID, choreIDs: stranded.sorted { $0.uuidString < $1.uuidString })
            }
        }
        var updated = current
        updated.isActive = active
        try store.append(ChoreEvent(timestamp: now, payload: .memberUpdated(updated)))
        guard !active else { return }
        var state = store.boardState()
        let releasedIDs = Set(state.openAssignments.values.filter { $0.memberID == memberID }.map(\.choreID))
        for choreID in releasedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try release(choreID: choreID, store: store, state: &state, now: now)
        }
        try reassignAfterEdit(choreIDs: releasedIDs, store: store, state: &state, now: now)
    }

    // MARK: Chores

    public static func addChore(_ draft: ChoreDraft, to store: ChoreStore, now: Date = Date()) throws -> UUID {
        let state = store.boardState()
        try validate(draft: draft, against: state)
        let chore = draft.chore(id: UUID())
        try store.append(ChoreEvent(timestamp: now, payload: .choreAdded(chore)))
        // A newly added active chore enters rotation immediately.
        if let winner = RotationEngine.nextAssignee(chore: chore, state: store.boardState()) {
            try store.append(ChoreEvent(timestamp: now, payload: .assigned(choreID: chore.id, memberID: winner, on: day(now))))
        } 
        // ponytail: store appends are individually durable; if assignment fails,
        // the chore remains saved and can be assigned on next edit.
        return chore.id
    }

    /// Apply an edit to an existing chore. Inactive→active (reactivation)
    /// re-enters rotation; edits that orphan the current assignee release and
    /// immediately re-assign. A completed-then-paused chore is NOT dragged
    /// back onto the board by pausing/resuming alone... unless reactivated,
    /// which explicitly re-enters rotation.
    public static func applyEdit(to choreID: UUID, draft: ChoreDraft, in store: ChoreStore, now: Date = Date()) throws {
        let before = store.boardState()
        guard let previous = before.chores[choreID] else { throw LedgerError.unknownChore(choreID) }
        try validate(draft: draft, against: before)
        let edited = draft.chore(id: choreID, isActive: previous.isActive)
        try store.append(ChoreEvent(timestamp: now, payload: .choreUpdated(edited)))
        var state = store.boardState()

        var requiresAssignment = false
        if let open = state.openAssignments[choreID] {
            if !edited.isActive || !edited.eligibleMemberIDs.contains(open.memberID) {
                try release(choreID: choreID, store: store, state: &state, now: now)
                requiresAssignment = edited.isActive
            }
        } else if edited.isActive && !previous.isActive {
            // Reactivation re-enters rotation. A chore paused after its work
            // was completed does NOT reappear until explicitly reactivated.
            requiresAssignment = true
        }
        if requiresAssignment, edited.isActive,
           let winner = RotationEngine.nextAssignee(chore: edited, state: state) {
            try store.append(ChoreEvent(timestamp: now, payload: .assigned(choreID: choreID, memberID: winner, on: day(now))))
        }
    }

    /// Pause/archive a chore. Historical completions stay in the ledger and
    /// fairness totals; the open assignment (and any pending swap) is released.
    public static func setChoreActive(_ choreID: UUID, active: Bool, in store: ChoreStore, now: Date = Date()) throws {
        let before = store.boardState()
        guard let current = before.chores[choreID] else { throw LedgerError.unknownChore(choreID) }
        guard current.isActive != active else { return }
        var updated = current
        updated.isActive = active
        try store.append(ChoreEvent(timestamp: now, payload: .choreUpdated(updated)))
        var state = store.boardState()
        if !active, state.openAssignments[choreID] != nil {
            try release(choreID: choreID, store: store, state: &state, now: now)
        } else if active, let winner = RotationEngine.nextAssignee(chore: updated, state: state) {
            try store.append(ChoreEvent(timestamp: now, payload: .assigned(choreID: choreID, memberID: winner, on: day(now))))
        }
    }

    /// Lazy recurrence: for each active repeating chore with no open
    /// assignment, assign the next rotation winner once the cadence anchored to
    /// its last EXPLICIT completion has come due. Never invents completions,
    /// and runs on refresh (not at completion) so the five-second undo window,
    /// which a new `.assigned` would clear, stays intact.
    @discardableResult
    public static func materializeDue(on today: ChoreDay, in store: ChoreStore, now: Date = Date()) throws -> Int {
        var lastCompleted: [UUID: ChoreDay] = [:]
        var undone = Set<UUID>()
        let events = try store.allEvents()
        for event in events {
            if case .completionUndone(let id) = event.payload { undone.insert(id) }
        }
        for event in events {
            if case .completed(let choreID, _, let day) = event.payload, !undone.contains(event.id) {
                lastCompleted[choreID] = max(day, lastCompleted[choreID] ?? day)
            }
        }
        var created = 0
        for choreID in lastCompleted.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let state = store.boardState()
            guard let chore = state.chores[choreID], chore.isActive,
                  state.openAssignments[choreID] == nil,
                  let completed = lastCompleted[choreID],
                  let due = nextDueDay(after: completed, cadence: chore.cadence), due <= today,
                  let winner = RotationEngine.nextAssignee(chore: chore, state: state) else { continue }
            try store.append(ChoreEvent(timestamp: now,
                                       payload: .assigned(choreID: choreID, memberID: winner, on: due)))
            created += 1
        }
        return created
    }

    /// Cadence is anchored to the explicit completion day. ISO weekday 1 =
    /// Monday ... 7 = Sunday; the epoch (day 0) was a Thursday (weekday 4).
    public static func nextDueDay(after day: ChoreDay, cadence: Cadence) -> ChoreDay? {
        if case .weeklyOn(let days) = cadence {
            for offset in 1...7 {
                let candidate = day.adding(offset)
                let weekday = ((candidate.daysSinceEpoch + 3) % 7 + 7) % 7 + 1
                if days.contains(weekday) { return candidate }
            }
            return nil
        }
        guard let interval = cadence.intervalDays, interval > 0 else { return nil }
        return day.adding(interval)
    }

    // MARK: - Shared internals

    /// An edit-time snapshot of a chore as captured by the editor UI.
    public struct ChoreDraft: Equatable, Sendable {
        public var title: String
        public var area: String
        public var effortMinutes: Int
        public var cadence: Cadence
        public var eligibleMemberIDs: Set<UUID>

        public init(title: String, area: String, effortMinutes: Int, cadence: Cadence,
                    eligibleMemberIDs: Set<UUID>) {
            self.title = title
            self.area = area
            self.effortMinutes = effortMinutes
            self.cadence = cadence
            self.eligibleMemberIDs = eligibleMemberIDs
        }

        public func chore(id: UUID, isActive: Bool = true) -> Chore {
            Chore(id: id, title: BoardEditor.trimmed(title), area: BoardEditor.trimmed(area),
                  effortMinutes: effortMinutes, cadence: cadence,
                  eligibleMemberIDs: eligibleMemberIDs, isActive: isActive)
        }
    }

    private static func validate(draft: ChoreDraft, against state: BoardState) throws {
        guard !trimmed(draft.title).isEmpty else { throw ManagementError.emptyTitle }
        guard !trimmed(draft.area).isEmpty else { throw ManagementError.emptyArea }
        guard draft.effortMinutes > 0 else { throw ManagementError.nonPositiveEffort }
        if case .everyDays(let days) = draft.cadence {
            guard days >= 1 else { throw ManagementError.zeroDayInterval }
        }
        if case .weeklyOn(let days) = draft.cadence {
            guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else {
                throw ManagementError.invalidWeekdays
            }
        }
        guard !draft.eligibleMemberIDs.isEmpty else { throw ManagementError.noEligibleMembers }
        for memberID in draft.eligibleMemberIDs where state.members[memberID] == nil {
            throw ManagementError.unknownEligibleMember(memberID)
        }
    }

    /// Release the open assignment without judging it missed: pending swaps
    /// for the chore are declined first (no consent was ever given), then the
    /// assignment is released back to the rotation engine.
    private static func release(choreID: UUID, store: ChoreStore, state: inout BoardState, now: Date) throws {
        guard state.openAssignments[choreID] != nil else { return }
        for swap in state.pendingSwaps.values where swap.choreID == choreID {
            try store.append(ChoreEvent(timestamp: now,
                payload: .swapDeclined(requestEventID: swap.requestEventID, byMemberID: swap.toMemberID)))
        }
        try store.append(ChoreEvent(timestamp: now, payload: .assignmentReleased(choreID: choreID)))
        state = store.boardState()
    }

    /// Immediately re-offer chores freed by this edit to the rotation engine
    /// so the Today board reflects the change at once. Scoped deliberately to
    /// the touched chores: a plain deactivation must not sweep unrelated
    /// completed chores back onto the board (recurrence owns those).
    private static func reassignAfterEdit(choreIDs: Set<UUID>,
                                          store: ChoreStore, state: inout BoardState, now: Date) throws {
        for choreID in choreIDs.sorted(by: { $0.uuidString < $1.uuidString })
        where state.openAssignments[choreID] == nil {
            guard let chore = state.chores[choreID], chore.isActive,
                  let winner = RotationEngine.nextAssignee(chore: chore, state: state) else { continue }
            try store.append(ChoreEvent(timestamp: now, payload: .assigned(choreID: choreID, memberID: winner, on: day(now))))
            state = store.boardState()
        }
    }

    private static func day(_ date: Date) -> ChoreDay {
        ChoreDay(daysSinceEpoch: Int(date.timeIntervalSince1970 / 86_400))
    }
}
