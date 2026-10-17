import Foundation

// MARK: - Entities

public struct Member: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var isActive: Bool

    public init(id: UUID, name: String, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.isActive = isActive
    }
}

public enum Cadence: Codable, Sendable, Equatable, Hashable {
    case daily
    case weekly
    /// Weekly repeat pinned to ISO weekday numbers (1 = Monday ... 7 = Sunday).
    case weeklyOn(days: Set<Int>)
    case monthly
    case everyDays(Int)
    case adHoc

    /// Repeat interval in days; nil for one-off (ad-hoc) chores.
    public var intervalDays: Int? {
        switch self {
        case .daily: 1
        case .weekly: 7
        case .weeklyOn: 7
        case .monthly: 30
        case .everyDays(let days): days
        case .adHoc: nil
        }
    }

    /// ISO weekdays for `.weeklyOn`, else nil.
    public var weekdays: Set<Int>? {
        if case .weeklyOn(let days) = self { days } else { nil }
    }
}

public struct Chore: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var area: String
    public var effortMinutes: Int
    public var cadence: Cadence
    public var eligibleMemberIDs: Set<UUID>
    public var isActive: Bool

    public init(
        id: UUID,
        title: String,
        area: String,
        effortMinutes: Int,
        cadence: Cadence,
        eligibleMemberIDs: Set<UUID>,
        isActive: Bool = true
    ) {
        self.id = id
        self.title = title
        self.area = area
        self.effortMinutes = effortMinutes
        self.cadence = cadence
        self.eligibleMemberIDs = eligibleMemberIDs
        self.isActive = isActive
    }
}

/// A calendar day expressed as whole days since the Unix epoch, so rotation
/// math never depends on a device time zone or calendar.
public struct ChoreDay: Codable, Sendable, Equatable, Hashable, Comparable, Strideable {
    public var daysSinceEpoch: Int

    public init(daysSinceEpoch: Int) { self.daysSinceEpoch = daysSinceEpoch }

    public func adding(_ days: Int) -> ChoreDay { ChoreDay(daysSinceEpoch: daysSinceEpoch + days) }
    public func daysSince(_ earlier: ChoreDay) -> Int { daysSinceEpoch - earlier.daysSinceEpoch }
    public func distance(to other: ChoreDay) -> Int { other.daysSinceEpoch - daysSinceEpoch }
    public func advanced(by n: Int) -> ChoreDay { adding(n) }
    public static func < (lhs: ChoreDay, rhs: ChoreDay) -> Bool { lhs.daysSinceEpoch < rhs.daysSinceEpoch }
}

// MARK: - Events

public enum ChoreEventPayload: Codable, Sendable, Equatable {
    case memberAdded(Member)
    case memberUpdated(Member)
    case choreAdded(Chore)
    case choreUpdated(Chore)
    case assigned(choreID: UUID, memberID: UUID, on: ChoreDay)
    case completed(choreID: UUID, memberID: UUID, on: ChoreDay)
    case completionUndone(completionEventID: UUID)
    case missed(choreID: UUID, memberID: UUID, on: ChoreDay)
    /// Editor-released open assignment (pause, member deactivation, or an
    /// edit that orphaned the assignee). Deliberately NOT `missed`: the work
    /// was never judged undone, so fairness counts stay honest.
    case assignmentReleased(choreID: UUID)
    case swapRequested(choreID: UUID, fromMemberID: UUID, toMemberID: UUID)
    case swapAccepted(requestEventID: UUID, byMemberID: UUID, on: ChoreDay)
    case swapDeclined(requestEventID: UUID, byMemberID: UUID)
}

public struct ChoreEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let payload: ChoreEventPayload

    public init(id: UUID = UUID(), timestamp: Date = Date(timeIntervalSince1970: 0),
                payload: ChoreEventPayload) {
        self.id = id
        self.timestamp = timestamp
        self.payload = payload
    }
}

// MARK: - State

public struct FairnessSummary: Codable, Sendable, Equatable {
    public var completedEffortMinutes: Int = 0
    public var completedCount: Int = 0
    public var missedCount: Int = 0
    public var lastAssignedOn: ChoreDay?

    public init() {}
}

public struct Assignment: Codable, Sendable, Equatable {
    public let choreID: UUID
    public let memberID: UUID
    public let assignedOn: ChoreDay
    /// Effort frozen at assignment time so later chore edits cannot rewrite
    /// fairness history.
    public let effortMinutes: Int

    public init(choreID: UUID, memberID: UUID, assignedOn: ChoreDay, effortMinutes: Int = 0) {
        self.choreID = choreID
        self.memberID = memberID
        self.assignedOn = assignedOn
        self.effortMinutes = effortMinutes
    }
}

public struct UndoableCompletion: Codable, Sendable, Equatable {
    public let assignment: Assignment
    public let completedAt: Date
}

public struct PendingSwap: Codable, Sendable, Equatable {
    public let requestEventID: UUID
    public let choreID: UUID
    public let fromMemberID: UUID
    public let toMemberID: UUID
}

/// Pure projection of the event log. `memberOrder` preserves ledger insertion
/// order so rotation ties break deterministically (UUID dictionaries are not
/// order-stable across processes).
public struct BoardState: Codable, Sendable, Equatable {
    public var members: [UUID: Member] = [:]
    public var memberOrder: [UUID] = []
    public var chores: [UUID: Chore] = [:]
    public var openAssignments: [UUID: Assignment] = [:]
    public var pendingSwaps: [UUID: PendingSwap] = [:]
    /// Latest completion eligible for undo; cleared when a new assignment begins.
    public var undoableCompletions: [UUID: UndoableCompletion] = [:]
    public var fairness: [UUID: FairnessSummary] = [:]

    public init() {}
}

public enum LedgerError: Error, Equatable {
    case duplicateEventID(UUID)
    case memberAlreadyExists(UUID)
    case choreAlreadyExists(UUID)
    case unknownMember(UUID)
    case unknownChore(UUID)
    case inactiveMember(UUID)
    case alreadyAssigned(UUID)
    case memberNotEligible(choreID: UUID, memberID: UUID)
    case swapAlreadyPending(choreID: UUID)
    case unknownSwapRequest(UUID)
    case wrongSwapRecipient(UUID)
    case undoUnavailable(UUID)
    case undoExpired(UUID)
    case invalidEventTimestamp
    case undoAlreadyPending(UUID)
}

// MARK: - Ledger

/// Append-only event log. Board state is always a pure fold over `events`,
/// so replays are bit-for-bit reproducible across restarts and platforms.
// ponytail: pure fold stays in memory; ChoreStore persists/replays events locally.
// If history grows large, cache a verified checkpoint rather than rewriting events.
public struct ChoreLedger: Sendable, Equatable {
    public private(set) var events: [ChoreEvent] = []

    public init() {}

    /// All-or-nothing replay: a single invalid event rejects the whole log.
    public init(events: [ChoreEvent]) throws {
        var state = BoardState()
        var seen = Set<UUID>()
        for event in events {
            guard seen.insert(event.id).inserted else {
                throw LedgerError.duplicateEventID(event.id)
            }
            state = try Self.apply(event, to: state)
        }
        self.events = events
    }

    public mutating func append(_ payload: ChoreEventPayload) throws {
        try append(ChoreEvent(payload: payload))
    }

    /// Validates against current state, then appends. A throwing append
    /// leaves the ledger unchanged.
    public mutating func append(_ event: ChoreEvent) throws {
        if events.contains(where: { $0.id == event.id }) {
            throw LedgerError.duplicateEventID(event.id)
        }
        _ = try Self.apply(event, to: boardState())
        events.append(event)
    }

    public func boardState() -> BoardState {
        var state = BoardState()
        for event in events {
            // Events in the log already passed validation; fold is total here.
            state = (try? Self.apply(event, to: state)) ?? state
        }
        return state
    }

    private static func apply(_ event: ChoreEvent, to state: BoardState) throws -> BoardState {
        var s = state
        switch event.payload {
        case .memberAdded(let added):
            guard s.members[added.id] == nil else { throw LedgerError.memberAlreadyExists(added.id) }
            s.members[added.id] = added
            s.memberOrder.append(added.id)
            s.fairness[added.id] = s.fairness[added.id] ?? FairnessSummary()
        case .memberUpdated(let updated):
            guard s.members[updated.id] != nil else { throw LedgerError.unknownMember(updated.id) }
            s.members[updated.id] = updated
            s.fairness[updated.id] = s.fairness[updated.id] ?? FairnessSummary()
        case .choreAdded(let added):
            guard s.chores[added.id] == nil else { throw LedgerError.choreAlreadyExists(added.id) }
            try validateEligibility(of: added, in: s)
            s.chores[added.id] = added
        case .choreUpdated(let updated):
            guard s.chores[updated.id] != nil else { throw LedgerError.unknownChore(updated.id) }
            try validateEligibility(of: updated, in: s)
            s.chores[updated.id] = updated
        case .assigned(let choreID, let memberID, let date):
            try validateAssignment(choreID: choreID, memberID: memberID, in: s)
            guard s.openAssignments[choreID] == nil else { throw LedgerError.alreadyAssigned(choreID) }
            s.openAssignments[choreID] = Assignment(choreID: choreID, memberID: memberID, assignedOn: date,
                                                    effortMinutes: s.chores[choreID]?.effortMinutes ?? 0)
            s.undoableCompletions = s.undoableCompletions.filter { $0.value.assignment.choreID != choreID }
            s.pendingSwaps = s.pendingSwaps.filter { $0.value.choreID != choreID }
            var summary = s.fairness[memberID] ?? FairnessSummary()
            summary.lastAssignedOn = date
            s.fairness[memberID] = summary
        case .completed(let choreID, let memberID, _):
            guard let open = s.openAssignments[choreID] else { throw LedgerError.unknownChore(choreID) }
            guard open.memberID == memberID else {
                throw LedgerError.memberNotEligible(choreID: choreID, memberID: memberID)
            }
            s.openAssignments[choreID] = nil
            s.undoableCompletions = s.undoableCompletions.filter { $0.value.assignment.choreID != choreID }
            s.undoableCompletions[event.id] = UndoableCompletion(assignment: open, completedAt: event.timestamp)
            s.pendingSwaps = s.pendingSwaps.filter { $0.value.choreID != choreID }
            var summary = s.fairness[memberID] ?? FairnessSummary()
            summary.completedCount += 1
            summary.completedEffortMinutes += open.effortMinutes
            s.fairness[memberID] = summary
        case .completionUndone(let completionID):
            guard let undo = s.undoableCompletions[completionID] else { throw LedgerError.undoUnavailable(completionID) }
            let elapsed = event.timestamp.timeIntervalSince(undo.completedAt)
            guard elapsed.isFinite, elapsed >= 0 else { throw LedgerError.invalidEventTimestamp }
            guard elapsed <= 5 else { throw LedgerError.undoExpired(completionID) }
            let open = undo.assignment
            guard s.openAssignments[open.choreID] == nil else { throw LedgerError.undoAlreadyPending(open.choreID) }
            s.openAssignments[open.choreID] = open
            s.undoableCompletions[completionID] = nil
            var summary = s.fairness[open.memberID] ?? FairnessSummary()
            summary.completedCount -= 1
            summary.completedEffortMinutes -= open.effortMinutes
            s.fairness[open.memberID] = summary
        case .missed(let choreID, let memberID, _):
            guard let open = s.openAssignments[choreID] else { throw LedgerError.unknownChore(choreID) }
            guard open.memberID == memberID else {
                throw LedgerError.memberNotEligible(choreID: choreID, memberID: memberID)
            }
            s.openAssignments[choreID] = nil
            s.pendingSwaps = s.pendingSwaps.filter { $0.value.choreID != choreID }
            var summary = s.fairness[memberID] ?? FairnessSummary()
            summary.missedCount += 1
            s.fairness[memberID] = summary
        case .assignmentReleased(let choreID):
            guard s.openAssignments[choreID] != nil else { throw LedgerError.unknownChore(choreID) }
            s.openAssignments[choreID] = nil
            s.pendingSwaps = s.pendingSwaps.filter { $0.value.choreID != choreID }
        case .swapRequested(let choreID, let fromMemberID, let toMemberID):
            guard s.openAssignments[choreID]?.memberID == fromMemberID else {
                throw LedgerError.memberNotEligible(choreID: choreID, memberID: fromMemberID)
            }
            try validateAssignment(choreID: choreID, memberID: toMemberID, in: s)
            guard !s.pendingSwaps.values.contains(where: { $0.choreID == choreID }) else {
                throw LedgerError.swapAlreadyPending(choreID: choreID)
            }
            s.pendingSwaps[event.id] = PendingSwap(requestEventID: event.id, choreID: choreID,
                                                   fromMemberID: fromMemberID, toMemberID: toMemberID)
        case .swapAccepted(let requestEventID, let byMemberID, let date):
            guard let request = s.pendingSwaps[requestEventID] else {
                throw LedgerError.unknownSwapRequest(requestEventID)
            }
            // Consent: only the requested member may accept.
            guard request.toMemberID == byMemberID else { throw LedgerError.wrongSwapRecipient(byMemberID) }
            // Consent is only valid while the recipient can still do the chore.
            try validateAssignment(choreID: request.choreID, memberID: byMemberID, in: s)
            s.pendingSwaps[requestEventID] = nil
            s.openAssignments[request.choreID] = Assignment(
                choreID: request.choreID, memberID: byMemberID, assignedOn: date,
                effortMinutes: s.openAssignments[request.choreID]?.effortMinutes
                    ?? s.chores[request.choreID]?.effortMinutes ?? 0)
            var summary = s.fairness[byMemberID] ?? FairnessSummary()
            summary.lastAssignedOn = date
            s.fairness[byMemberID] = summary
        case .swapDeclined(let requestEventID, let byMemberID):
            guard let request = s.pendingSwaps[requestEventID] else {
                throw LedgerError.unknownSwapRequest(requestEventID)
            }
            guard request.toMemberID == byMemberID else { throw LedgerError.wrongSwapRecipient(byMemberID) }
            s.pendingSwaps[requestEventID] = nil
        }
        return s
    }

    private static func validateEligibility(of chore: Chore, in state: BoardState) throws {
        for memberID in chore.eligibleMemberIDs where state.members[memberID] == nil {
            throw LedgerError.unknownMember(memberID)
        }
    }

    private static func validateAssignment(choreID: UUID, memberID: UUID, in state: BoardState) throws {
        guard let chore = state.chores[choreID] else { throw LedgerError.unknownChore(choreID) }
        guard state.members[memberID] != nil else { throw LedgerError.unknownMember(memberID) }
        guard chore.isActive else { throw LedgerError.unknownChore(choreID) }
        guard state.members[memberID]?.isActive == true else { throw LedgerError.inactiveMember(memberID) }
        guard chore.eligibleMemberIDs.contains(memberID) else {
            throw LedgerError.memberNotEligible(choreID: choreID, memberID: memberID)
        }
    }
}

// MARK: - Rotation

public enum RotationEngine {
    /// Deterministic effort-weighted rotation:
    /// 1. least (completed effort + open assigned effort) minutes wins;
    /// 2. tie → least-recent assignment (never-assigned beats assigned);
    /// 3. still tied → earliest memberAdded order (stable across replays).
    /// Inactive or ineligible members are never selected. Returns nil when no
    /// candidate exists — an empty board stays empty, nothing is auto-assigned.
    public static func nextAssignee(chore: Chore, state: BoardState) -> UUID? {
        var openEffort: [UUID: Int] = [:]
        for assignment in state.openAssignments.values {
            openEffort[assignment.memberID, default: 0] += assignment.effortMinutes
        }
        var best: (id: UUID, load: Int, last: ChoreDay?)?
        for position in state.memberOrder {
            guard let member = state.members[position], member.isActive,
                  chore.eligibleMemberIDs.contains(position) else { continue }
            let load = (state.fairness[position]?.completedEffortMinutes ?? 0) + (openEffort[position] ?? 0)
            let last = state.fairness[position]?.lastAssignedOn
            guard let current = best else { best = (position, load, last); continue }
            // Strict "<" keeps the earliest memberOrder entry on full ties.
            if load < current.load
                || (load == current.load
                    && (last ?? ChoreDay(daysSinceEpoch: .min)) <
                       (current.last ?? ChoreDay(daysSinceEpoch: .min))) {
                best = (position, load, last)
            }
        }
        return best?.id
    }
}
