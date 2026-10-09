import RevuCore
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
        } detail: {
            DetailView()
        }
        .navigationTitle(state.windowTitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $state.mode) {
                    Text("Changes").tag(ViewMode.changes)
                    Text("File").tag(ViewMode.file)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Changes (⌘1) / File (⌘2)")
            }
            ToolbarItem(placement: .status) {
                if state.showUpdatedToast {
                    Text("Updated just now").font(.caption).foregroundStyle(.secondary).transition(.opacity)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $state.wrap) { Label("Wrap", systemImage: "text.word.spacing") }
                    .help("Wrap long lines")
                Button { state.refresh() } label: {
                    if state.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .help("Refresh (⌘R)")
                Button("Finish Review…") { state.openFinish() }
                    .buttonStyle(.borderedProminent)
                    .help("Finish Review (⇧⌘↩)")
            }
        }
        .animation(.default, value: state.showUpdatedToast)
        .sheet(isPresented: $state.showFinish) { FinishSheet() }
    }
}
