import SwiftUI

struct ContentView: View {
    @Bindable private var state = AppState.shared
    @State private var selectedTab: Tab = .general

    private enum Tab: Int, Identifiable, CaseIterable {
        case general, chat, notes, meals, chores, reminders, calendar, logs

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .general:   return "General"
            case .chat:      return "Chat"
            case .notes:     return "Notes"
            case .meals:     return "Meals"
            case .chores:    return "Chores"
            case .reminders: return "Reminders"
            case .calendar:  return "Calendar"
            case .logs:      return "Logs"
            }
        }

        var icon: String {
            switch self {
            case .general:   return "gear"
            case .chat:      return "bubble.left.and.bubble.right"
            case .notes:     return "note.text"
            case .meals:     return "fork.knife"
            case .chores:    return "checklist"
            case .reminders: return "bell"
            case .calendar:  return "calendar"
            case .logs:      return "doc.text.magnifyingglass"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationSplitView {
                List(Tab.allCases, selection: tabBinding) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            } detail: {
                detailView
                    .padding()
            }

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

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:   GeneralTab()
        case .chat:      ChatTab()
        case .notes:     NotesTab()
        case .meals:     MealsTab()
        case .chores:    ChoresTab()
        case .reminders: RemindersTab()
        case .calendar:  CalendarTab()
        case .logs:      LogsTab()
        }
    }

    private var tabBinding: Binding<Tab?> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard let newTab else { return }
                if state.isEditing {
                    state.showToast("Finish editing first")
                } else {
                    selectedTab = newTab
                }
            }
        )
    }
}
