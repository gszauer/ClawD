import SwiftUI

struct ContentView: View {
    @Bindable private var state = AppState.shared
    @Bindable private var core = CoreBridge.shared
    @State private var selectedTab: Tab = .general

    private enum Tab: Int, Identifiable, CaseIterable {
        case general, prompts, chat, notes, meals, chores, reminders, calendar, errors

        var id: Int { rawValue }

        /// Tabs that don't require the core to be running.
        var worksOffline: Bool {
            self == .general || self == .prompts || self == .errors
        }

        var title: String {
            switch self {
            case .general:   return "General"
            case .prompts:   return "Prompts"
            case .chat:      return "Chat"
            case .notes:     return "Notes"
            case .meals:     return "Meals"
            case .chores:    return "Chores"
            case .reminders: return "Reminders"
            case .calendar:  return "Calendar"
            case .errors:    return "Errors"
            }
        }

        var icon: String {
            switch self {
            case .general:   return "gear"
            case .prompts:   return "text.book.closed"
            case .chat:      return "bubble.left.and.bubble.right"
            case .notes:     return "note.text"
            case .meals:     return "fork.knife"
            case .chores:    return "checklist"
            case .reminders: return "bell"
            case .calendar:  return "calendar"
            case .errors:    return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationSplitView {
                List(Tab.allCases, selection: tabBinding) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                        .foregroundStyle(tab.worksOffline || core.isRunning ? .primary : .secondary)
                        .allowsHitTesting(tab.worksOffline || core.isRunning)
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
        case .prompts:   PromptsTab()
        case .chat:      ChatTab()
        case .notes:     NotesTab()
        case .meals:     MealsTab()
        case .chores:    ChoresTab()
        case .reminders: RemindersTab()
        case .calendar:  CalendarTab()
        case .errors:    ErrorsTab()
        }
    }

    private var tabBinding: Binding<Tab?> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard let newTab else { return }
                if state.isEditing {
                    state.showToast("Finish editing first")
                } else if !newTab.worksOffline && !core.isRunning {
                    state.showToast("Start the assistant first")
                } else {
                    selectedTab = newTab
                }
            }
        )
    }
}
