import SwiftUI

/// Honest scaffold placeholder. The Today board arrives with issue #4;
/// this view deliberately promises no unshipped features.
/// (Scaffold version assertion lives in ChoreWheelTests, Linux-gated.)
struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "Chore Wheel",
            systemImage: "arrow.triangle.2.circlepath",
            description: Text("The chore board is under construction.")
        )
    }
}

#Preview {
    ContentView()
}
