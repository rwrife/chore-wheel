import Foundation

public enum ArchiveError: Error, Equatable, LocalizedError {
    case unsupportedVersion
    case invalidHistory

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Backup version is not supported. No data was replaced."
        case .invalidHistory: "Backup history is invalid. No data was replaced."
        }
    }
}

/// Portable, unencrypted snapshot. Member/chore definitions and all audit events
/// live in the ordered ledger; no derived totals are serialized separately.
public struct BoardArchive: Codable, Sendable {
    public let version: Int
    public let events: [ChoreEvent]

    public init(events: [ChoreEvent]) {
        self.version = 1
        self.events = events
    }

    public func validatedEvents() throws -> [ChoreEvent] {
        guard version == 1 else { throw ArchiveError.unsupportedVersion }
        guard (try? ChoreLedger(events: events)) != nil else { throw ArchiveError.invalidHistory }
        return events
    }
}

public enum FairnessWindow: String, CaseIterable, Identifiable, Sendable {
    case week = "Week", month = "Month", year = "Year", allTime = "All time"
    public var id: String { rawValue }

    /// Calendar boundaries, not a rolling 7/30/365-day approximation. UTC
    /// matches the epoch-day representation used by completed events.
    public func contains(_ day: ChoreDay, asOf now: Date) -> Bool {
        let date = Date(timeIntervalSince1970: Double(day.daysSinceEpoch) * 86_400)
        guard date <= now else { return false }
        guard self != .allTime else { return true }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let component: Calendar.Component = switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .allTime: .era
        }
        guard let interval = calendar.dateInterval(of: component, for: now) else { return false }
        return interval.contains(date)
    }
}

public struct FairnessRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let completedEffortMinutes: Int
    public let completedCount: Int
}

public enum FairnessReport {
    /// Credit only explicit, non-undone completions. Snapshot assignment effort
    /// when assigned, so later edits do not rewrite history. Attribute to the
    /// completing profile, including after a consented swap.
    public static func rows(events: [ChoreEvent], asOf now: Date, window: FairnessWindow) throws -> [FairnessRow] {
        let state = try ChoreLedger(events: events).boardState()
        // Ids are fixed UUID strings; deterministic regardless of Dictionary order.
        var effort: [UUID: Int] = [:]
        var requests: [UUID: UUID] = [:]
        var open: [UUID: (member: UUID, effort: Int)] = [:]
        var completions: [UUID: (member: UUID, effort: Int, day: ChoreDay)] = [:]
        var completedChores: [UUID: UUID] = [:]
        for event in events {
            switch event.payload {
            case .memberAdded, .memberUpdated:
                break
            case .choreAdded(let chore), .choreUpdated(let chore):
                effort[chore.id] = chore.effortMinutes
            case .assigned(let chore, let member, _):
                open[chore] = (member, effort[chore] ?? 0)
            case .swapRequested(let chore, _, _):
                requests[event.id] = chore
            case .swapAccepted(let request, let by, _):
                if let chore = requests[request], let assignment = open[chore] {
                    open[chore] = (by, assignment.effort)
                }
            case .completed(let chore, let member, let day):
                if let assignment = open.removeValue(forKey: chore) {
                    completions[event.id] = (member, assignment.effort, day)
                    completedChores[event.id] = chore
                }
            case .completionUndone(let completion):
                if let original = completions.removeValue(forKey: completion),
                   let chore = completedChores[completion] {
                    // Ledger validates undo. A restored assignment can complete again.
                    open[chore] = (original.member, original.effort)
                }
            case .missed(let chore, _, _), .assignmentReleased(let chore):
                open[chore] = nil
            case .swapCancelled, .swapDeclined:
                break
            }
        }
        var totals: [UUID: (count: Int, effort: Int)] = [:]
        for completion in completions.values where window.contains(completion.day, asOf: now) {
            var total = totals[completion.member] ?? (0, 0)
            total.count += 1
            total.effort += completion.effort
            totals[completion.member] = total
        }
        return state.memberOrder.compactMap { id in
            guard let member = state.members[id] else { return nil }
            let total = totals[id] ?? (0, 0)
            return FairnessRow(id: id, name: member.name,
                               completedEffortMinutes: total.effort, completedCount: total.count)
        }
    }
}

/// Redacted by default. No UUIDs, audit events, timestamps, areas or private
/// swap requests leave this renderer; user sees and confirms text before sharing.
public enum BoardShare {
    public static func text(state: BoardState, redactNames: Bool) -> String {
        var lines = ["Chore Wheel — open chores", "Only recorded assignments; not a completion record."]
        let members = Dictionary(uniqueKeysWithValues: state.memberOrder.enumerated().map {
            ($0.element, "Member \($0.offset + 1)")
        })
        for assignment in state.openAssignments.values.sorted(by: {
            let a = state.chores[$0.choreID]?.title ?? ""
            let b = state.chores[$1.choreID]?.title ?? ""
            return a == b ? $0.choreID.uuidString < $1.choreID.uuidString : a < b
        }) {
            guard let chore = state.chores[assignment.choreID],
                  let member = state.members[assignment.memberID] else { continue }
            lines.append("\(chore.title.replacingOccurrences(of: "\n", with: " ")) — \(redactNames ? members[member.id] ?? "Member" : member.name.replacingOccurrences(of: "\n", with: " "))")
        }
        if lines.count == 2 { lines.append("No open chores.") }
        return lines.joined(separator: "\n")
    }
}
