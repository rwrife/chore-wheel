import SwiftUI
import UIKit
import Foundation

// ponytail: iPhone-only layout until public dual-screen APIs exist.

/// Represents high-level workspace layout seam.
/// Prepares for future unfolded dual-screen expansion while presenting cleanly on a single iPhone screen.
public enum ChoreWorkspaceLayout {
    case singleScreen
    // Future public dual-screen APIs may add a second layout.
}

public struct TodayBoardView: View {
    @ObservedObject public var model: TodayBoardModel
    private let layout: ChoreWorkspaceLayout = .singleScreen
    @State private var swapItem: ChoreItemDisplay?
    @State private var showAudit = false

    public init(model: TodayBoardModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.dueTodayOrOverdue.isEmpty {
                            ContentUnavailableView(
                                "All Chores Done",
                                systemImage: "checkmark.circle.fill",
                                description: Text("No chores due today or overdue.")
                            )
                            .padding(.top, 40)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Due Today & Overdue")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)

                                ForEach(model.dueTodayOrOverdue, id: \.choreID) { item in
                                    ChoreCardView(item: item, swap: model.swapSummary(for: item)) {
                                        model.completeChore(item: item)
                                    } onSwap: {
                                        swapItem = item
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .padding(.bottom, model.undoNotice != nil ? 70 : 16)
                }

                if let notice = model.undoNotice {
                    UndoBannerView(notice: notice) {
                        model.undoLastCompletion()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Today")
            .toolbar {
                Button("History", systemImage: "clock.arrow.circlepath") { showAudit = true }
                    .accessibilityLabel("Chore history")
            }
            .navigationDestination(isPresented: $showAudit) { AuditLogView(model: model) }
            .sheet(item: $swapItem) { item in
                SwapSheet(item: item, model: model)
            }
        }
    }
}

public struct ChoreItemDisplay: Equatable, Identifiable {
    public var id: UUID { choreID }
    public let choreID: UUID
    public let title: String
    public let area: String
    public let effortMinutes: Int
    public let assigneeID: UUID
    public let assigneeName: String
    public let isOverdue: Bool

    public init(
        choreID: UUID,
        title: String,
        area: String,
        effortMinutes: Int,
        assigneeID: UUID,
        assigneeName: String,
        isOverdue: Bool
    ) {
        self.choreID = choreID
        self.title = title
        self.area = area
        self.effortMinutes = effortMinutes
        self.assigneeID = assigneeID
        self.assigneeName = assigneeName
        self.isOverdue = isOverdue
    }
}

public struct UndoNotice: Equatable {
    public let completionEventID: UUID
    public let choreTitle: String
    public let assigneeName: String
}

@MainActor public protocol FeedbackGenerator {
    func triggerSuccess()
}

public final class DefaultHapticGenerator: FeedbackGenerator {
    public init() {}
    public func triggerSuccess() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }
}

@MainActor public final class TodayBoardModel: ObservableObject {
    @Published public private(set) var dueTodayOrOverdue: [ChoreItemDisplay] = []
    @Published public private(set) var board = BoardState()
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var undoNotice: UndoNotice?

    private let store: ChoreStore
    private var currentDay: ChoreDay
    private let hapticGenerator: FeedbackGenerator
    private var undoTask: Task<Void, Never>?

    public init(store: ChoreStore, currentDay: ChoreDay, hapticGenerator: FeedbackGenerator = DefaultHapticGenerator()) {
        self.store = store
        self.currentDay = currentDay
        self.hapticGenerator = hapticGenerator
        refresh()
    }

    public func refresh() {
        // Lazy recurrence: due repeating chores enter rotation before we read
        // the board. Failures leave the last-known board intact, never data.
        _ = try? BoardEditor.materializeDue(on: currentDay, in: store)
        let state = store.boardState()
        board = state
        let assignments = store.today(on: currentDay)
        dueTodayOrOverdue = assignments.compactMap { a in
            guard let chore = state.chores[a.choreID],
                  let member = state.members[a.memberID] else { return nil }
            return ChoreItemDisplay(
                choreID: a.choreID,
                title: chore.title,
                area: chore.area,
                effortMinutes: a.effortMinutes,
                assigneeID: member.id,
                assigneeName: member.name,
                isOverdue: a.assignedOn < currentDay
            )
        }
    }

    public func pendingSwap(for item: ChoreItemDisplay) -> PendingSwap? {
        board.pendingSwaps.values.first { $0.choreID == item.choreID }
    }

    public func swapSummary(for item: ChoreItemDisplay) -> String? {
        guard let pending = pendingSwap(for: item) else { return nil }
        if let target = pending.toMemberID {
            return "Swap pending with \(board.members[target]?.name ?? "unknown member")"
        }
        return "Open grab pending"
    }

    public func eligibleRecipients(for item: ChoreItemDisplay) -> [Member] {
        guard let chore = board.chores[item.choreID] else { return [] }
        return board.memberOrder.compactMap { board.members[$0] }.filter {
            $0.id != item.assigneeID && $0.isActive && chore.eligibleMemberIDs.contains($0.id)
        }
    }

    public func requestSwap(for item: ChoreItemDisplay, to memberID: UUID?) {
        record(.swapRequested(choreID: item.choreID, fromMemberID: item.assigneeID, toMemberID: memberID))
    }

    public func acceptSwap(_ request: PendingSwap, by memberID: UUID) {
        record(.swapAccepted(requestEventID: request.requestEventID, byMemberID: memberID, on: currentDay))
    }

    public func declineSwap(_ request: PendingSwap) {
        guard let recipient = request.toMemberID else { return }
        record(.swapDeclined(requestEventID: request.requestEventID, byMemberID: recipient))
    }

    public func withdrawSwap(_ request: PendingSwap) {
        record(.swapCancelled(requestEventID: request.requestEventID, byMemberID: request.fromMemberID))
    }

    public func clearError() { errorMessage = nil }

    private func record(_ payload: ChoreEventPayload) {
        do {
            try store.append(ChoreEvent(timestamp: Date(), payload: payload))
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    public func auditEntries() throws -> [AuditEntry] { AuditTrail.entries(try store.allEvents()) }

    public func completeChore(item: ChoreItemDisplay, date: Date = Date()) {
        let completionEvent = ChoreEvent(
            timestamp: date,
            payload: .completed(choreID: item.choreID, memberID: item.assigneeID, on: currentDay)
        )
        do {
            try store.append(completionEvent)
            hapticGenerator.triggerSuccess()
            undoNotice = UndoNotice(
                completionEventID: completionEvent.id,
                choreTitle: item.title,
                assigneeName: item.assigneeName
            )
            refresh()
            undoTask?.cancel()
            undoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self?.undoNotice = nil }
            }
        } catch {
            // Error handling: store error rejection
        }
    }

    public func undoLastCompletion(date: Date = Date()) {
        guard let notice = undoNotice else { return }
        let undoEvent = ChoreEvent(
            timestamp: date,
            payload: .completionUndone(completionEventID: notice.completionEventID)
        )
        do {
            try store.append(undoEvent)
            undoNotice = nil
            undoTask?.cancel()
            refresh()
        } catch {
            // If expired or failed
        }
    }
}

public struct ChoreCardView: View {
    public let item: ChoreItemDisplay
    public let swap: String?
    public let onComplete: () -> Void
    public let onSwap: () -> Void

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    if item.isOverdue {
                        Text("OVERDUE")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .accessibilityLabel("Overdue")
                    }
                }

                HStack(spacing: 8) {
                    Text(item.area)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text("\(item.effortMinutes)m")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(item.assigneeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let swap {
                    Label(swap, systemImage: "arrow.left.arrow.right")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("swap.pending.\(item.choreID.uuidString)")
                }
            }

            Spacer(minLength: 8)

            Button(action: onSwap) {
                Image(systemName: "arrow.left.arrow.right")
                    .frame(width: 28, height: 28)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityLabel(swap == nil ? "Swap \(item.title)" : "Manage swap for \(item.title)")
            .accessibilityIdentifier("swap.open.\(item.choreID.uuidString)")

            // Prominent one-thumb tap target: min 44x44
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.blue)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(item.title) as complete")
            .accessibilityHint("Completes the chore for \(item.assigneeName)")
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SwapSheet: View {
    let item: ChoreItemDisplay
    @ObservedObject var model: TodayBoardModel
    @Environment(\.dismiss) private var dismiss
    @State private var decision: Decision?

    private enum Decision {
        case request(UUID?)
        case accept(UUID)
        case decline
        case withdraw
    }

    private var pending: PendingSwap? { model.pendingSwap(for: item) }
    private var recipients: [Member] { model.eligibleRecipients(for: item) }

    private var prompt: String {
        switch decision {
        case .request: "Confirm you are \(item.assigneeName) requesting this handoff. Profiles are local names, not verified accounts."
        case .accept(let id): "Hand this phone to \(model.board.members[id]?.name ?? "recipient"). They must confirm taking \(item.title)."
        case .decline: "Hand this phone to the named recipient to confirm decline."
        case .withdraw: "Confirm you are \(item.assigneeName) withdrawing this request."
        case nil: ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(item.title) · assigned to \(item.assigneeName)")
                    Text("This phone holds local named profiles. Confirmations record the selected name, not verified identity.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let pending {
                    Section("Pending handoff") {
                        Text(model.swapSummary(for: item) ?? "Pending")
                        if let id = pending.toMemberID {
                            let name = model.board.members[id]?.name ?? "Recipient"
                            Button("Accept as \(name)") { decision = .accept(id) }
                                .disabled(!recipients.contains(where: { $0.id == id }))
                            Button("Decline as \(name)") { decision = .decline }
                        } else {
                            ForEach(recipients) { member in
                                Button("Accept as \(member.name)") { decision = .accept(member.id) }
                            }
                        }
                        Button("Withdraw as \(item.assigneeName)", role: .destructive) { decision = .withdraw }
                    }
                } else {
                    Section("Request handoff") {
                        ForEach(recipients) { member in
                            Button("Ask \(member.name) to take this chore") { decision = .request(member.id) }
                        }
                        Button("Offer to anyone eligible") { decision = .request(nil) }
                            .disabled(recipients.isEmpty)
                    }
                }
            }
            .navigationTitle("Handoff")
            .toolbar { Button("Done") { dismiss() } }
            .alert("Confirm handoff", isPresented: Binding(
                get: { decision != nil }, set: { if !$0 { decision = nil } }
            )) {
                Button("Confirm") {
                    switch decision {
                    case .request(let id): model.requestSwap(for: item, to: id)
                    case .accept(let id): if let pending { model.acceptSwap(pending, by: id) }
                    case .decline: if let pending { model.declineSwap(pending) }
                    case .withdraw: if let pending { model.withdrawSwap(pending) }
                    case nil: break
                    }
                    decision = nil
                    if model.errorMessage == nil { dismiss() }
                }
                Button("Cancel", role: .cancel) { decision = nil }
            } message: { Text(prompt) }
            .alert("Could not update handoff", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } }
            )) {
                Button("OK", role: .cancel) { model.clearError() }
            } message: { Text(model.errorMessage ?? "Unknown error") }
        }
    }
}

private struct AuditLogView: View {
    @ObservedObject var model: TodayBoardModel
    @State private var entries: [AuditEntry] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text("Could not load history: \(error)")
            } else if entries.isEmpty {
                ContentUnavailableView("No check-ins or handoffs yet", systemImage: "clock")
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.summary)
                        Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("History")
        .onAppear {
            do { entries = try model.auditEntries() }
            catch { self.error = error.localizedDescription }
        }
    }
}

public struct UndoBannerView: View {
    public let notice: UndoNotice
    public let onUndo: () -> Void

    public var body: some View {
        HStack(spacing: 12) {
            Text("Completed \(notice.choreTitle)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.blue)
                .accessibilityLabel("Undo completion of \(notice.choreTitle)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
    }
}
