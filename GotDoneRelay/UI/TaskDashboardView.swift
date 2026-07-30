import SwiftUI
import UIKit

struct TaskDashboardView: View {
    @ObservedObject var model: SyncAppModel
    @Binding var isResetConfirmationPresented: Bool
    @Binding var isUnlinkConfirmationPresented: Bool
    let joinAction: () -> Void
    @State private var draftTitle = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var deleteCommitTask: Task<Void, Never>?
    @State private var isSupportStatusPresented = false
    @FocusState private var composerIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !model.isPaired {
                localTasksNotice
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            } else {
                if model.showsLinkCompleteCelebration {
                    LinkCompleteBanner()
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                } else if let notice = model.syncNotice {
                    SyncNoticeView(
                        notice: notice,
                        repairAction: {
                            isUnlinkConfirmationPresented = true
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                } else if let cue = model.inboundArrivalCue {
                    SoftCueBanner(
                        text: cue,
                        systemImage: "iphone.badge.play"
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                } else if let confidence = model.lastSyncConfidenceText {
                    SoftCueBanner(
                        text: confidence,
                        systemImage: "checkmark.circle"
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }
            }

            if visibleTasks.isEmpty {
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
                    if model.isPaired {
                        Button(
                            "Sync status",
                            systemImage: "info.circle"
                        ) {
                            isSupportStatusPresented = true
                        }

                        Button(
                            "Unlink and Keep Tasks",
                            systemImage: "link.badge.minus"
                        ) {
                            isUnlinkConfirmationPresented = true
                        }

                        #if DEBUG
                        Menu("Diagnostics") {
                            Text("End-to-end encrypted")
                            Text("Live relay: \(model.relayURL.host() ?? "local")")
                            Text("Offline mailbox: \(model.mailboxURL.host() ?? "local")")
                            if let roundTrip = model.lastRoundTripMilliseconds {
                                Text(
                                    "Live round trip: \(roundTrip, specifier: "%.1f") ms"
                                )
                            }
                            if let error = model.mailboxErrorMessage {
                                Text("Last sync error: \(error)")
                            }
                        }
                        #endif
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
        .sheet(isPresented: $isSupportStatusPresented) {
            SupportStatusSheet(model: model)
        }
        .onChange(of: model.tasks.map(\.id)) {
            reconcilePendingDeletion()
        }
        .onChange(of: model.syncNotice) { previous, current in
            announceActionableNotice(current, previousKind: previous?.kind)
        }
        .onAppear {
            announceActionableNotice(model.syncNotice, previousKind: nil)
        }
        .onDisappear {
            deleteCommitTask?.cancel()
            deleteCommitTask = nil
        }
    }

    private var taskList: some View {
        List {
            Section {
                ForEach(visibleTasks) { task in
                    RelayTaskRow(
                        task: task,
                        isEditable: model.canEditLocalTasks,
                        toggleAction: {
                            model.toggleTask(task)
                        },
                        deleteAction: {
                            stageDeletion(taskIDs: [task.id])
                        }
                    )
                    .listRowInsets(
                        EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .deleteDisabled(!model.canEditLocalTasks)
                }
                .onDelete(perform: stageDeletion)
            } header: {
                HStack {
                    Text(model.isPaired ? "Shared tasks" : "Local tasks")
                    Spacer()
                    Text("\(visibleTasks.count)")
                }
            } footer: {
                Label(
                    model.isPaired
                        ? ProductSyncPolicy.deliverySummary
                        : "New edits are not syncing and stay on this iPhone until you create a new private sync.",
                    systemImage: model.isPaired ? "lock.fill" : "iphone"
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
        .accessibilityLabel(model.isPaired ? "Synced tasks" : "Local tasks")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                model.isPaired ? "Nothing to sync yet" : "No visible tasks",
                systemImage: "checkmark.circle"
            )
        } description: {
            Text(
                model.isPaired
                    ? "Add a task below. It is saved on this iPhone first, then appears on the other iPhone the next time that phone opens Got Done."
                    : model.canEditLocalTasks
                        ? "Add a local task below or create Private Sync for a replacement iPhone."
                        : "Restart Got Done or erase local data to recover from the storage error."
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private var taskComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pendingDeletion {
                HStack(spacing: 12) {
                    Label(
                        pendingDeletion.taskIDs.count == 1
                            ? "Task removed"
                            : "\(pendingDeletion.taskIDs.count) tasks removed",
                        systemImage: "trash"
                    )
                    .font(.subheadline.weight(.semibold))

                    Spacer()

                    Button("Undo") {
                        undoDeletion()
                    }
                    .font(.subheadline.weight(.bold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(
                        model.isPaired
                            ? "Prevents this deletion from syncing to the other iPhone."
                            : "Keeps this task in the local list."
                    )
                }
                .padding(.horizontal, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                TextField(
                    model.isPaired ? "Add a shared task" : "Add a local task",
                    text: $draftTitle,
                    axis: .vertical
                )
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
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(normalizedDraft.isEmpty)
                .accessibilityLabel("Add task")
                .accessibilityIdentifier("add-task")
            }
            .disabled(!model.canEditLocalTasks)

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

    private var localTasksNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                model.phase == .failed
                    ? "Private Sync needs attention"
                    : "Not syncing",
                systemImage: model.phase == .failed
                    ? "exclamationmark.triangle.fill"
                    : "iphone"
            )
                .font(.headline)

            if model.phase == .failed {
                Text(model.errorMessage ?? "Private Sync could not continue.")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                model.canEditLocalTasks
                    ? "Link ended or never started — tasks stay on this iPhone. Create Private Sync for a replacement phone, or join an invitation from your other iPhone."
                    : "Local storage is unavailable, so these tasks cannot be edited right now. Restart Got Done or erase local data to start over."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.canEditLocalTasks {
                Button {
                    if model.pairingRecoveryResetRequired {
                        isUnlinkConfirmationPresented = true
                    } else {
                        model.createPrivateSync()
                    }
                } label: {
                    Label(
                        model.pairingRecoveryResetRequired
                            ? "Keep Tasks · Reset Link"
                            : model.phase == .failed
                                ? "Create Private Sync for Replacement"
                                : "Create Private Sync",
                        systemImage: "qrcode"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pendingDeletion != nil)
                .accessibilityHint(
                    pendingDeletion == nil
                        ? model.pairingRecoveryResetRequired
                            ? "Keeps local tasks and asks before clearing damaged or unfinished sync recovery data."
                            : "Creates a one-time invitation for a replacement iPhone."
                        : "Undo the pending deletion or wait for it to finish first."
                )

                Button(action: joinAction) {
                    Label("Join Existing Sync", systemImage: "viewfinder")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(
                    pendingDeletion != nil || !model.canJoinExistingSync
                )
                .accessibilityHint(
                    pendingDeletion == nil
                        ? "Opens the phrase and QR code join options. If the task lists differ, local tasks stay here until you confirm how to combine them."
                        : "Undo the pending deletion or wait for it to finish first."
                )
            }

            if model.phase == .failed {
                Button("Erase Local Data…", role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard()
        .accessibilityElement(children: .contain)
    }

    private func announceActionableNotice(
        _ notice: SyncNotice?,
        previousKind: SyncNoticeKind?
    ) {
        guard
            let notice,
            notice.kind != .saving,
            notice.kind != previousKind
        else {
            return
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(notice.title). \(notice.detail)"
        )
    }

    private var visibleTasks: [ReplicatedTask] {
        guard let pendingDeletion else {
            return model.tasks
        }
        let hidden = Set(pendingDeletion.taskIDs)
        return model.tasks.filter { !hidden.contains($0.id) }
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

    private func stageDeletion(at offsets: IndexSet) {
        let ids = offsets.compactMap {
            visibleTasks.indices.contains($0) ? visibleTasks[$0].id : nil
        }
        stageDeletion(taskIDs: ids)
    }

    private func stageDeletion(taskIDs: [UUID]) {
        guard model.canEditLocalTasks, !taskIDs.isEmpty else {
            return
        }
        let current = Set(pendingDeletion?.taskIDs ?? [])
        let combined = Array(current.union(taskIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        let pending = PendingDeletion(taskIDs: combined)
        pendingDeletion = pending
        deleteCommitTask?.cancel()
        deleteCommitTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard pendingDeletion?.id == pending.id else {
                return
            }
            commitPendingDeletion()
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: "Task removed. Undo is available for five seconds."
        )
    }

    private func undoDeletion() {
        deleteCommitTask?.cancel()
        deleteCommitTask = nil
        pendingDeletion = nil
        UIAccessibility.post(
            notification: .announcement,
            argument: "Deletion undone."
        )
    }

    private func commitPendingDeletion() {
        guard let pendingDeletion else {
            return
        }
        let visibleModelIDs = Set(model.tasks.map(\.id))
        let ids = pendingDeletion.taskIDs.filter(visibleModelIDs.contains)
        deleteCommitTask = nil
        self.pendingDeletion = nil
        model.deleteTasks(ids: ids)
    }

    private func reconcilePendingDeletion() {
        guard let pendingDeletion else {
            return
        }
        let visibleModelIDs = Set(model.tasks.map(\.id))
        let remaining = pendingDeletion.taskIDs.filter(
            visibleModelIDs.contains
        )
        guard remaining != pendingDeletion.taskIDs else {
            return
        }
        if remaining.isEmpty {
            deleteCommitTask?.cancel()
            deleteCommitTask = nil
            self.pendingDeletion = nil
        } else {
            self.pendingDeletion = PendingDeletion(
                id: pendingDeletion.id,
                taskIDs: remaining
            )
        }
    }
}

private struct RelayTaskRow: View {
    let task: ReplicatedTask
    let isEditable: Bool
    let toggleAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleAction) {
                completionIndicator
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCompleted ? "Mark \(title) incomplete" : "Mark \(title) complete"
            )
            .disabled(!isEditable)

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
        .accessibilityAction(named: "Delete") {
            if isEditable {
                deleteAction()
            }
        }
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

private struct PendingDeletion: Equatable, Identifiable {
    let id: UUID
    let taskIDs: [UUID]

    init(id: UUID = UUID(), taskIDs: [UUID]) {
        self.id = id
        self.taskIDs = taskIDs
    }
}

private struct LinkCompleteBanner: View {
    var body: some View {
        Label("Private Sync is on", systemImage: "checkmark.seal.fill")
            .font(.headline)
            .foregroundStyle(RelayTheme.success)
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayCard()
            .accessibilityIdentifier("link-complete-banner")
    }
}

private struct SoftCueBanner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(RelayTheme.card)
            )
            .accessibilityIdentifier("soft-sync-cue")
    }
}

struct SupportStatusSheet: View {
    @ObservedObject var model: SyncAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let summary = model.supportStatusSummary
            List {
                Section("Status") {
                    Text(summary.linkStatusLine)
                    Text(summary.lastUpdateLine)
                    Text(summary.pendingLine)
                    Text(summary.localEditLine)
                }
                Section("When does the other iPhone see edits?") {
                    Text(summary.deliveryDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text(ProductSyncPolicy.twoDeviceBoundary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sync status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
