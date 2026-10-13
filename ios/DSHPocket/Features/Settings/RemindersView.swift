import DSHKit
import SwiftUI

/// 定时提醒。
///
/// 桌面端是官方实验性 bundle（`dsh-experimental-schedule-bundle`），
/// 手机上"让电脑到点干件事"其实更自然 —— 人不在电脑前才需要它。
///
/// 新建仍然走 `/schedule` 命令（服务端的 `schedule/update` 要传完整记录 +
/// 乐观并发的 `expected`，比命令脆弱得多）；这一页负责**看和删**。
struct RemindersView: View {
    @Environment(AppModel.self) private var model

    @State private var reminders: [Reminder] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var pendingDelete: Reminder?

    var body: some View {
        List {
            if let error {
                Section {
                    ContentUnavailableView {
                        Label("读不到提醒", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                }
            } else if isLoading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if reminders.isEmpty {
                Section {
                    ContentUnavailableView(
                        "没有提醒",
                        systemImage: "bell.slash",
                        description: Text("在会话里用 `/schedule` 让电脑到点干件事，之后会出现在这里。")
                    )
                }
            } else {
                Section {
                    ForEach(reminders) { reminder in
                        row(reminder)
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = reminder }
                            }
                    }
                } footer: {
                    Text("左滑删除。新建要在会话里发 `/schedule` —— 服务端的写接口要求传完整记录和乐观并发版本，比命令脆弱得多。")
                }
            }
        }
        .navigationTitle("定时提醒")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("删除这条提醒？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let reminder = pendingDelete { Task { await delete(reminder) } }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private func row(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reminder.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: Token.Spacing.tight) {
                Text(reminder.cadence).font(.caption2).foregroundStyle(.secondary)
                if let at = reminder.scheduledAt {
                    Text(Format.absoluteTime(at)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !reminder.prompt.isEmpty {
                Text(reminder.prompt)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // 提醒可以挂在具体会话上，也可以全局 —— 先拿当前会话的，
            // 拿不到就退回到全局（`schedule/catalog`）。
            var items: [Reminder] = []
            if let sessionId = model.activeSessionId {
                items = try await model.client.listSchedules(sessionId: sessionId)
            }
            if items.isEmpty {
                items = try await model.client.scheduleCatalog()
            }
            reminders = items
            error = nil
        } catch {
            self.error = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            reminders = []
        }
    }

    private func delete(_ reminder: Reminder) async {
        do {
            _ = try await model.client.deleteSchedule(id: reminder.id, expected: reminder.raw)
            await load()
        } catch {
            self.error = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }
}
