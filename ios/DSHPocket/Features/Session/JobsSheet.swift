import DSHKit
import SwiftUI

/// 后台任务面板。
///
/// **这是唯一一类"跑起来就彻底看不见"的东西** —— 桌面端有专门的面板，
/// 手机上没有的话，后台 bash 跑着既看不到输出也停不掉。
struct JobsSheet: View {
    let session: SessionModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if session.jobs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "没有后台任务",
                            systemImage: "clock.badge.checkmark",
                            description: Text("让电脑跑一个后台命令时，它会出现在这里，输出也能实时看。")
                        )
                    }
                } else {
                    ForEach(session.jobs) { job in
                        NavigationLink {
                            JobDetailView(session: session, job: job)
                        } label: {
                            row(job)
                        }
                    }
                }
            }
            .navigationTitle("后台任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable { await session.refreshJobs() }
            .task { await session.refreshJobs() }
        }
    }

    private func row(_ job: BackgroundJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Token.Spacing.tight) {
                Text(job.label.isEmpty ? job.kind : job.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if job.isRunning {
                    StatusBadge("运行中", symbol: "circle.dotted", tone: .info)
                } else {
                    Text(job.statusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Token.Spacing.tight) {
                if let progress = job.progress, !progress.isEmpty {
                    Text(progress).font(.caption2).foregroundStyle(.secondary)
                }
                if let duration = job.duration ?? (job.isRunning ? Date().timeIntervalSince(job.startedAt) : nil),
                   let formatted = Format.duration(duration) {
                    Text(formatted).font(.caption2).foregroundStyle(.tertiary)
                }
                if job.outputTotal > 0 {
                    Text(String(format: String(localized: "%@ 输出"), Format.tokens(job.outputTotal) ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
    }
}

/// 一个后台任务的实时输出。
struct JobDetailView: View {
    let session: SessionModel
    let job: BackgroundJob

    @State private var text = ""
    @State private var cursor = 0
    @State private var isLossy = false
    @State private var status: BackgroundJob?
    @State private var followTask: Task<Void, Never>?
    @State private var confirmingKill = false

    private var current: BackgroundJob { status ?? job }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                if isLossy {
                    Text("前面的输出已经被丢掉了（超出上限），下面是能拿到的部分。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if text.isEmpty {
                    Text(current.isRunning ? String(localized: "还没有输出…") : String(localized: "没有输出。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Token.Spacing.gutter)
        }
        .navigationTitle(current.label.isEmpty ? current.kind : current.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if current.isRunning {
                    Button(role: .destructive) { confirmingKill = true } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                }
            }
        }
        .confirmationDialog("停止这个后台任务？", isPresented: $confirmingKill, titleVisibility: .visible) {
            Button("停止", role: .destructive) {
                Task {
                    await session.killJob(current)
                    followTask?.cancel()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .task { startFollowing() }
        .onDisappear { followTask?.cancel() }
    }

    private func startFollowing() {
        followTask?.cancel()
        followTask = Task {
            do {
                for try await frame in session.followJob(job) {
                    if Task.isCancelled { return }
                    switch frame {
                    case .opened(let opened, let from):
                        status = opened
                        cursor = from
                    case .output(let chunks, let next, let lossy):
                        for chunk in chunks { text += chunk.text }
                        cursor = next
                        if lossy { isLossy = true }
                    case .status(let updated):
                        status = updated
                    }
                }
            } catch {
                // 断流不弹错 —— 已经拿到的输出还留着，用户可以退出重进。
            }
        }
    }
}
