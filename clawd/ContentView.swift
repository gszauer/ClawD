import SwiftUI

struct ContentView: View {
    @Bindable private var state = AppState.shared
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: tabBinding) {
                GeneralTab()
                    .tabItem { Label("General", systemImage: "gear") }
                    .tag(0)

                ChatTab()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(1)

                NotesTab()
                    .tabItem { Label("Notes", systemImage: "note.text") }
                    .tag(2)

                MealsTab()
                    .tabItem { Label("Meals", systemImage: "fork.knife") }
                    .tag(3)

                ChoresTab()
                    .tabItem { Label("Chores", systemImage: "checklist") }
                    .tag(4)

                RemindersTab()
                    .tabItem { Label("Reminders", systemImage: "bell") }
                    .tag(5)

                CalendarTab()
                    .tabItem { Label("Calendar", systemImage: "calendar") }
                    .tag(6)
            }
            .padding()

            // Toast overlay
            if !state.toastMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: state.toastIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    Text(state.toastMessage)
                        .lineLimit(2)
                }
                .font(.callout)
                .foregroundStyle(state.toastIsError ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    (state.toastIsError ? Color.red : Color(.windowBackgroundColor))
                        .shadow(.drop(radius: 4))
                )
                .cornerRadius(8)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { state.toastMessage = "" }
                .animation(.easeInOut(duration: 0.25), value: state.toastMessage)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.toastMessage.isEmpty)
    }

    private var tabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if state.isEditing {
                    state.showToast("Finish editing first")
                } else {
                    selectedTab = newTab
                }
            }
        )
    }
}
