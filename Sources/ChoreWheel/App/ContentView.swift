import SwiftUI

struct ContentView: View {
    private let store: Result<ChoreStore, Error>

    init() {
        store = Result { try ChoreStore.openApplicationStore() }
    }

    var body: some View {
        switch store {
        case .success(let store):
            TodayBoardRoot(store: store)
        case .failure:
            ContentUnavailableView("Board unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Could not read local chores. Your data was not replaced."))
        }
    }
}

private struct TodayBoardRoot: View {
    @StateObject private var model: TodayBoardModel

    init(store: ChoreStore) {
        let day = ChoreDay(daysSinceEpoch: Int(Date().timeIntervalSince1970 / 86400))
        _model = StateObject(wrappedValue: TodayBoardModel(store: store, currentDay: day))
    }

    var body: some View { TodayBoardView(model: model) }
}

#Preview { ContentView() }
