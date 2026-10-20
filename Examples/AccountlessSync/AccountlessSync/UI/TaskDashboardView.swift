import GotSync
import SwiftUI
import UIKit

struct TaskDashboardView: View {
    @ObservedObject var model: SyncAppModel
    @Binding var isResetConfirmationPresented: Bool
    @Binding var isUnlinkConfirmationPresented: Bool
    let joinAction: () -> Void
    var settingsAction: (() -> Void)? = nil
    @State private var draftTitle = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var deleteCommitTask: Task<Void, Never>?
    @State private var isSupportStatusPresented = false
    @State private var isManageSyncPresented = false
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
                                : .opacity.combined(with: .offset(y: -6))
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
                }
            }

            if visibleTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .background(SoftFieldBackground())
        .safeAreaInset(edge: .bottom) {
            taskComposer
        }
        .navigationTitle(RelayTheme.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.isPaired {
                        Button(
                            ProductSyncPolicy.manageSyncTitle,
                            systemImage: "person.2"
                        ) {
                            isManageSyncPresented = true
                        }

                        Button(
                            "Sync status",
                            systemImage: "info.circle"
                        ) {
                            isSupportStatusPresented = true
                        }

                        Button(
                            ProductSyncPolicy.leaveSyncTitle,
                            systemImage: "link.badge.minus"
                        ) {
                            isUnlinkConfirmationPresented = true
                        }

                        #if DEBUG
                        Menu("Diagnostics") {
                            Text("End-to-end encrypted with MLS")
                            Text(
                                "Linked iPhones: \(model.linkedMemberCount)"
                            )
                            Text("Sync service: \(model.mailboxURL.host() ?? "local")")
                            if let error = model.mailboxErrorMessage {
                                Text("Last sync error: \(error)")
                            }
                        }
                        #endif
                    }

                    if let settingsAction {
                        Button("Settings", systemImage: "gearshape") {
                            settingsAction()
                        }
                    }

                    Button(
                        "Erase all local data",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        isResetConfirmationPresented = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(RelayTheme.inkMuted)
                }
                .accessibilityLabel("Sync options")
            }
        }
        .sheet(isPresented: $isManageSyncPresented) {
            ManageSyncView(
                model: model,
                isUnlinkConfirmationPresented: $isUnlinkConfirmationPresented
            )
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
                        EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .deleteDisabled(!model.canEditLocalTasks)
                }
                .onDelete(perform: stageDeletion)
            } header: {
                HStack {
                    Text(model.isPaired ? "Shared demo tasks" : "On this phone")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayTheme.inkMuted)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Spacer()
                    Text("\(visibleTasks.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RelayTheme.inkMuted)
                        .monospacedDigit()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.defaultMinListRowHeight, 1)
        .accessibilityLabel(model.isPaired ? "Synced tasks" : "Local tasks")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)

            Image(systemName: model.isPaired ? "link" : "checklist")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(RelayTheme.accent)
                .symbolRenderingMode(.monochrome)
                .frame(width: 48, height: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(RelayTheme.border, lineWidth: 1)
                }
                .accessibilityHidden(true)

            Text(model.isPaired ? "READY TO SYNC" : "NO DEMO TASKS")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(RelayTheme.ink)

            Text(
                model.isPaired
                    ? "Add a demo task. Appears on linked phones when in sync."
                    : model.canEditLocalTasks
                        ? "Thin task list. The sync engine is the product. Add a task, or create a link."
                        : "Restart Accountless Sync or erase local data to recover from the storage error."
            )
            .font(.footnote)
            .foregroundStyle(RelayTheme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RelayTheme.ink)

                    Spacer()

                    Button("Undo") {
                        undoDeletion()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RelayTheme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(
                        model.isPaired
                            ? "Prevents this deletion from syncing to the other iPhone."
                            : "Keeps this task in the local list."
                    )
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            }

            HStack(spacing: 10) {
                TextField(
                    model.isPaired ? "New shared demo task" : "New demo task",
                    text: $draftTitle,
                    axis: .vertical
                )
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused($composerIsFocused)
                    .foregroundStyle(RelayTheme.ink)
                    .onSubmit(addTask)
                    .onChange(of: draftTitle) {
                        model.clearLocalEditError()
                    }
                    .accessibilityIdentifier("task-title-field")

                Button(action: addTask) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(
                            canSubmitDraft
                                ? RelayTheme.onAccent
                                : RelayTheme.inkMuted
                        )
                        .frame(width: 36, height: 36)
                        .background {
                            Circle()
                                .fill(
                                    canSubmitDraft
                                        ? RelayTheme.accent
                                        : RelayTheme.field
                                )
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            canSubmitDraft
                                                ? Color.clear
                                                : RelayTheme.border,
                                            lineWidth: 1
                                        )
                                }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitDraft)
                .accessibilityLabel("Add task")
                .accessibilityIdentifier("add-task")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(
                GlassSurfaceModifier(
                    cornerRadius: RelayTheme.cornerControl,
                    interactive: true
                )
            )
            .disabled(!model.canEditLocalTasks)

            if let message = model.localEditErrorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var normalizedDraft: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitDraft: Bool {
        !normalizedDraft.isEmpty && model.canEditLocalTasks
    }

    private var localTasksNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase != .failed, let reason = model.linkEndedReason {
                LinkEndedNotice(reason: reason)
            } else {
                Label(
                    model.phase == .failed
                        ? "Link needs attention"
                        : "Not syncing",
                    systemImage: model.phase == .failed
                        ? "exclamationmark.triangle.fill"
                        : "iphone"
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RelayTheme.ink)
            }

            if model.phase == .failed {
                Text(model.errorMessage ?? "Linking could not continue.")
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                model.canEditLocalTasks
                    ? model.linkEndedReason == nil
                        ? "Link ended or never started. Tasks stay on this phone. Create a link for a replacement, or join from your other iPhone."
                        : "Create a new link, or join from a phone that is still linked."
                    : "Local storage is unavailable. Restart Accountless Sync or erase local data to start over."
            )
            .font(.footnote)
            .foregroundStyle(RelayTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)

            if model.canEditLocalTasks {
                Button {
                    model.createPrivateSync()
                } label: {
                    Text(
                        model.phase == .failed
                            ? "Create link for replacement"
                            : "Create link"
                    )
                    .frame(maxWidth: .infinity)
                }
                .pocPrimaryButtonStyle()
                .controlSize(.large)
                .disabled(pendingDeletion != nil)

                Button(action: joinAction) {
                    Text("Join link")
                        .frame(maxWidth: .infinity)
                }
                .pocSecondaryButtonStyle()
                .controlSize(.large)
                .disabled(
                    pendingDeletion != nil || !model.canJoinExistingSync
                )
            }

            if model.phase == .failed {
                Button("Erase local data…", role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .pocSecondaryButtonStyle()
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard(padding: 14)
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
        HStack(spacing: 14) {
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
                .foregroundStyle(isCompleted ? RelayTheme.inkMuted : RelayTheme.ink)
                .strikethrough(isCompleted, color: RelayTheme.inkMuted.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .modifier(
            GlassSurfaceModifier(
                cornerRadius: RelayTheme.cornerRow,
                interactive: isEditable
            )
        )
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
                    .fill(RelayTheme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(RelayTheme.onAccent)
            }
            .frame(width: 24, height: 24)
        } else {
            Circle()
                .strokeBorder(RelayTheme.inkMuted.opacity(0.55), lineWidth: 1.5)
                .frame(width: 24, height: 24)
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
        Label("Link is live", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RelayTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayCard(padding: 14)
            .accessibilityIdentifier("link-complete-banner")
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
                Section("When do other phones see edits?") {
                    Text(summary.deliveryDetail)
                        .font(.subheadline)
                        .foregroundStyle(RelayTheme.inkMuted)
                }
                Section {
                    Text(ProductSyncPolicy.multiDeviceBoundary)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                    if model.isPaired {
                        Text(model.manageSyncStatusLine)
                            .font(.footnote)
                            .foregroundStyle(RelayTheme.inkMuted)
                    }
                    Text(RelayTheme.proofLabel)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RelayTheme.inkMuted)
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

#if DEBUG
#Preview("Dashboard empty") {
    @Previewable @StateObject var model = PreviewSupport.model()
    NavigationStack {
        TaskDashboardView(
            model: model,
            isResetConfirmationPresented: .constant(false),
            isUnlinkConfirmationPresented: .constant(false),
            joinAction: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Dashboard with tasks") {
    @Previewable @StateObject var model = PreviewSupport.model(
        seedTaskTitles: ["Buy milk", "Ship update", "Review design"]
    )
    NavigationStack {
        TaskDashboardView(
            model: model,
            isResetConfirmationPresented: .constant(false),
            isUnlinkConfirmationPresented: .constant(false),
            joinAction: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Dashboard linked") {
    @Previewable @StateObject var model = PreviewSupport.model(
        seedTaskTitles: ["Shared task"]
    )
    NavigationStack {
        TaskDashboardView(
            model: model,
            isResetConfirmationPresented: .constant(false),
            isUnlinkConfirmationPresented: .constant(false),
            joinAction: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Support status") {
    @Previewable @StateObject var model = PreviewSupport.model()
    SupportStatusSheet(model: model)
        .preferredColorScheme(.dark)
}
#endif

