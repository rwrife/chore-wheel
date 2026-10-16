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
                                    ChoreCardView(item: item) {
                                        model.completeChore(item: item)
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

public protocol FeedbackGenerator {
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

public final class TodayBoardModel: ObservableObject {
    @Published public private(set) var dueTodayOrOverdue: [ChoreItemDisplay] = []
    @Published public private(set) var undoNotice: UndoNotice?

    private let store: ChoreStore
    private var currentDay: ChoreDay
    private let hapticGenerator: FeedbackGenerator
    private var undoTimer: Timer?

    public init(store: ChoreStore, currentDay: ChoreDay, hapticGenerator: FeedbackGenerator = DefaultHapticGenerator()) {
        self.store = store
        self.currentDay = currentDay
        self.hapticGenerator = hapticGenerator
        refresh()
    }

    public func refresh() {
        let state = store.boardState()
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
            undoTimer?.invalidate()
            undoTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.undoNotice = nil
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
            undoTimer?.invalidate()
            refresh()
        } catch {
            // If expired or failed
        }
    }
}

public struct ChoreCardView: View {
    public let item: ChoreItemDisplay
    public let onComplete: () -> Void

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
            }

            Spacer(minLength: 8)

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
        .background(
            Color(.tertiarySystemBackground)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
