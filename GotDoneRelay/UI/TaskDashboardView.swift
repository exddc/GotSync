import SwiftUI

struct TaskDashboardView: View {
    @ObservedObject var model: SyncAppModel
    @Binding var isResetConfirmationPresented: Bool
    @State private var draftTitle = ""
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SyncStatusView(
                phase: model.phase,
                title: model.statusTitle,
                detail: model.statusDetail,
                roundTripMilliseconds: model.phase == .synced
                    ? model.lastRoundTripMilliseconds
                    : nil,
                lastSyncedAt: model.lastSyncedAt,
                mailboxAvailable: model.isMailboxAvailable,
                mailboxNeedsAttention: model.mailboxNeedsAttention,
                showsDetail: model.showsStatusDetail
            )
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if model.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .safeAreaInset(edge: .bottom) {
            taskComposer
        }
        .navigationTitle("Got Done")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Text("End-to-end encrypted")
                        Text("Live relay: \(model.relayURL.host() ?? "local")")
                        Text("Offline mailbox: \(model.mailboxURL.host() ?? "local")")
                    }

                    Button(
                        "Erase Link and Local Tasks",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        isResetConfirmationPresented = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Private sync options")
            }
        }
    }

    private var taskList: some View {
        List {
            Section {
                ForEach(model.tasks) { task in
                    RelayTaskRow(task: task) {
                        model.toggleTask(task)
                    }
                    .listRowInsets(
                        EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: model.deleteTasks)
            } header: {
                HStack {
                    Text("Shared tasks")
                    Spacer()
                    Text("\(model.tasks.count)")
                }
            } footer: {
                Label(
                    "Encrypted edits wait for the other iPhone, then the relay deletes them.",
                    systemImage: "lock.fill"
                )
                .font(.footnote)
                .textCase(nil)
                .padding(.top, 6)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.defaultMinListRowHeight, 1)
        .accessibilityLabel("Synced tasks")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to sync yet", systemImage: "checkmark.circle")
        } description: {
            Text("Add a task below. It syncs live or waits encrypted until the other iPhone opens.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private var taskComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Add a shared task", text: $draftTitle, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused($composerIsFocused)
                    .onSubmit(addTask)
                    .onChange(of: draftTitle) {
                        model.clearLocalEditError()
                    }
                    .accessibilityIdentifier("task-title-field")

                Button(action: addTask) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(normalizedDraft.isEmpty)
                .accessibilityLabel("Add task")
                .accessibilityIdentifier("add-task")
            }

            if let message = model.localEditErrorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var normalizedDraft: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTask() {
        let title = normalizedDraft
        guard !title.isEmpty else {
            return
        }
        if model.addTask(title: title) {
            draftTitle = ""
        }
        composerIsFocused = true
    }
}

private struct RelayTaskRow: View {
    let task: ReplicatedTask
    let toggleAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleAction) {
                completionIndicator
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCompleted ? "Mark \(title) incomplete" : "Mark \(title) complete"
            )

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(isCompleted ? .secondary : .primary)
                .strikethrough(isCompleted, color: .secondary.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RelayTheme.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RelayTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id.uuidString)")
    }

    @ViewBuilder
    private var completionIndicator: some View {
        if isCompleted {
            ZStack {
                Circle()
                    .fill(RelayTheme.success)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else {
            Circle()
                .strokeBorder(.secondary, lineWidth: 1.6)
        }
    }

    private var title: String {
        task.titleValue ?? "Untitled"
    }

    private var isCompleted: Bool {
        task.isCompleted ?? false
    }
}
