import SwiftUI

/// Local household management. Profiles are names on this device, not accounts.
struct ManagementView: View {
    let store: ChoreStore
    let onChange: () -> Void

    @State private var state = BoardState()
    @State private var memberName = ""
    @State private var selectedMember: Member?
    @State private var editingChore: Chore?
    @State private var addingChore = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Household profiles") {
                    HStack {
                        TextField("New member name", text: $memberName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(addMember)
                            .accessibilityIdentifier("member.name")
                        Button("Add", action: addMember)
                            .disabled(BoardEditor.trimmed(memberName).isEmpty)
                            .accessibilityIdentifier("member.add")
                    }
                    ForEach(state.memberOrder.compactMap { state.members[$0] }) { member in
                        Button {
                            selectedMember = member
                        } label: {
                            HStack {
                                Text(member.name)
                                Spacer()
                                if !member.isActive { Text("Inactive").foregroundStyle(.secondary) }
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Edit profile \(member.name)\(member.isActive ? "" : ", inactive")")
                    }
                }
                Section("Chores") {
                    ForEach(state.chores.values.sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }) { chore in
                        Button {
                            editingChore = chore
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(chore.title)
                                    Text("\(chore.area) · \(chore.effortMinutes) min")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !chore.isActive { Text("Paused").foregroundStyle(.secondary) }
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Edit chore \(chore.title)\(chore.isActive ? "" : ", paused")")
                    }
                    Button("Add chore", systemImage: "plus") { addingChore = true }
                        .disabled(!state.members.values.contains(where: \.isActive))
                        .accessibilityIdentifier("chore.add")
                }
                Section {
                    Text("Profiles and chores stay on this iPhone. Pausing keeps completed history; no work is marked done automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Manage")
            .onAppear(perform: refresh)
            .sheet(item: $selectedMember) { member in
                MemberEditor(member: member, store: store) { reload() }
            }
            .sheet(item: $editingChore) { chore in
                ChoreEditor(chore: chore, store: store, members: activeMembers) { reload() }
            }
            .sheet(isPresented: $addingChore) {
                ChoreEditor(chore: nil, store: store, members: activeMembers) { reload() }
            }
            .alert("Could not save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "Unknown error")
            }
        }
    }

    private var activeMembers: [Member] {
        state.memberOrder.compactMap { state.members[$0] }.filter(\.isActive)
    }

    private func refresh() { state = store.boardState() }
    private func reload() { refresh(); onChange() }
    private func addMember() {
        do {
            _ = try BoardEditor.addMember(named: memberName, to: store)
            memberName = ""
            reload()
        } catch { failure = error.localizedDescription }
    }
}

private struct MemberEditor: View {
    let member: Member
    let store: ChoreStore
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?

    init(member: Member, store: ChoreStore, onChange: @escaping () -> Void) {
        self.member = member
        self.store = store
        self.onChange = onChange
        _name = State(initialValue: member.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Profile name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .accessibilityIdentifier("member.edit.name")
                Text("History is kept under this profile, even if renamed or deactivated.")
                    .font(.footnote).foregroundStyle(.secondary)
                if member.isActive {
                    Button("Deactivate profile", role: .destructive) {
                        apply { try BoardEditor.setMemberActive(member.id, active: false, in: store) }
                    }
                } else {
                    Button("Reactivate profile") {
                        apply { try BoardEditor.setMemberActive(member.id, active: true, in: store) }
                    }
                }
            }
            .navigationTitle("Edit profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { apply { try BoardEditor.renameMember(member.id, to: name, in: store) } }
                        .disabled(BoardEditor.trimmed(name).isEmpty)
                        .accessibilityIdentifier("member.edit.save")
                }
            }
            .alert("Could not save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Unknown error") }
        }
    }

    private func apply(_ action: () throws -> Void) {
        do { try action(); onChange(); dismiss() }
        catch { failure = error.localizedDescription }
    }
}

private struct ChoreEditor: View {
    let chore: Chore?
    let store: ChoreStore
    let members: [Member]
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var area: String
    @State private var effort: Int
    @State private var cadenceKind: CadenceKind
    @State private var days: Set<Int>
    @State private var interval: Int
    @State private var eligible: Set<UUID>
    @State private var failure: String?

    init(chore: Chore?, store: ChoreStore, members: [Member], onChange: @escaping () -> Void) {
        self.chore = chore
        self.store = store
        self.members = members
        self.onChange = onChange
        _title = State(initialValue: chore?.title ?? "")
        _area = State(initialValue: chore?.area ?? "")
        _effort = State(initialValue: chore?.effortMinutes ?? 15)
        _cadenceKind = State(initialValue: CadenceKind(chore?.cadence ?? .weekly))
        _days = State(initialValue: chore?.cadence.weekdays ?? [1])
        _interval = State(initialValue: chore?.cadence.editorIntervalDays ?? 7)
        _eligible = State(initialValue: chore?.eligibleMemberIDs ?? Set(members.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chore") {
                    TextField("Title", text: $title).accessibilityIdentifier("chore.title")
                    TextField("Room or area", text: $area).accessibilityIdentifier("chore.area")
                    Stepper("Estimated effort: \(effort) min", value: $effort, in: 1...480)
                        .accessibilityIdentifier("chore.effort")
                }
                Section("Repeat") {
                    Picker("Cadence", selection: $cadenceKind) {
                        ForEach(CadenceKind.allCases) { kind in Text(kind.label).tag(kind) }
                    }
                    if cadenceKind == .weeklyOn {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(weekdayName(day), isOn: Binding(
                                get: { days.contains(day) },
                                set: { if $0 { days.insert(day) } else { days.remove(day) } }
                            ))
                        }
                    }
                    if cadenceKind == .interval {
                        Stepper("Every \(interval) days", value: $interval, in: 1...365)
                    }
                }
                Section("Eligible profiles") {
                    ForEach(members) { member in
                        Toggle(member.name, isOn: Binding(
                            get: { eligible.contains(member.id) },
                            set: { if $0 { eligible.insert(member.id) } else { eligible.remove(member.id) } }
                        ))
                    }
                    if members.isEmpty { Text("Add an active profile first.").foregroundStyle(.secondary) }
                }
                if let chore {
                    Section {
                        if chore.isActive {
                            Button("Pause chore", role: .destructive) {
                                apply { try BoardEditor.setChoreActive(chore.id, active: false, in: store) }
                            }
                        } else {
                            Button("Reactivate chore") {
                                apply { try BoardEditor.setChoreActive(chore.id, active: true, in: store) }
                            }
                        }
                        Text("Pausing removes this chore from Today but keeps its completion history.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(chore == nil ? "Add chore" : "Edit chore")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(BoardEditor.trimmed(title).isEmpty || BoardEditor.trimmed(area).isEmpty
                                  || eligible.isEmpty || (cadenceKind == .weeklyOn && days.isEmpty))
                        .accessibilityIdentifier("chore.save")
                }
            }
            .alert("Could not save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Unknown error") }
        }
    }

    private func save() {
        let draft = BoardEditor.ChoreDraft(title: title, area: area, effortMinutes: effort,
                                           cadence: cadenceKind.value(days: days, interval: interval),
                                           eligibleMemberIDs: eligible)
        apply {
            if let chore { try BoardEditor.applyEdit(to: chore.id, draft: draft, in: store) }
            else { _ = try BoardEditor.addChore(draft, to: store) }
        }
    }

    private func apply(_ action: () throws -> Void) {
        do { try action(); onChange(); dismiss() }
        catch { failure = error.localizedDescription }
    }

    private func weekdayName(_ day: Int) -> String {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][day - 1]
    }
}

private enum CadenceKind: String, CaseIterable, Identifiable {
    case daily, weekly, weeklyOn, monthly, interval, adHoc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Every 7 days"
        case .weeklyOn: "Days of week"
        case .monthly: "Every 30 days"
        case .interval: "Every N days"
        case .adHoc: "Ad-hoc"
        }
    }
    init(_ cadence: Cadence) {
        switch cadence {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .weeklyOn: self = .weeklyOn
        case .monthly: self = .monthly
        case .everyDays: self = .interval
        case .adHoc: self = .adHoc
        }
    }
    func value(days: Set<Int>, interval: Int) -> Cadence {
        switch self {
        case .daily: .daily
        case .weekly: .weekly
        case .weeklyOn: .weeklyOn(days: days)
        case .monthly: .monthly
        case .interval: .everyDays(interval)
        case .adHoc: .adHoc
        }
    }
}
