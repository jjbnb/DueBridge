import SwiftUI

@MainActor struct MultiSourceView: View {
    @ObservedObject var model: MultiSourceAppModel
    let clock: PreviewClock
    var body: some View {
        TabView {
            DeadlineOverview(model: model, clock: clock)
                .tabItem { Label("全部截止事项", systemImage: "list.bullet") }
            ScrollView {
                MainView(controller: model.bb, previewClock: clock)
            }.tabItem { Text("BB") }
            ForEach(model.nativeSources, id: \.platform.rawValue) { source in
                ScrollView {
                    NativeSourceView(controller: source, clock: clock)
                }.tabItem { Text(source.platform.displayName) }
            }
            ReminderDestinationView(model: model.destination, busy: model.isBusy)
                .tabItem { Label("提醒事项列表", systemImage: "checklist") }
            CalendarDestinationView(model: model.calendarDestination,
                                    hasPreview: model.bb.preview != nil || model.nativeSources.contains { $0.preview != nil },
                                    sourceBusy: model.bb.busy || model.nativeSources.contains(where: \.busy))
                .tabItem { Label("苹果日历", systemImage: "calendar") }
        }.padding(8)
    }
}

@MainActor struct NativeSourceView: View {
    @ObservedObject var controller: NativeSourceController
    let clock: PreviewClock
    private var tasks: [NativeDeadlineTask] {
        (try? NativeTaskSelection.select(controller.preview?.candidates ?? []).tasks) ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.platform.displayName).font(.title2.bold())
                    Text("先预览有明确截止时间的任务，再选择提醒事项列表或苹果日历。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(controller.anyEnabled ? "同步已启用" : "未启用 / 已暂停")
                    .font(.caption.bold()).padding(7)
                    .background(controller.anyEnabled ? Color.green.opacity(0.13) : Color.gray.opacity(0.12), in: Capsule())
            }
            Text("连接会在本机保存本平台的登录状态，用于以后检查。请只在学校登录窗口输入密码。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(controller.connected ? "重新连接 / 登录" : "连接并保存本机登录状态") { controller.beginConnect() }
                    .disabled(controller.busy)
                if controller.waitingForLogin {
                    Button("登录完成，读取课程") { Task { await controller.finishConnect() } }
                        .buttonStyle(.borderedProminent).disabled(controller.busy)
                } else if controller.connected {
                    Button("刷新预览") { Task { await controller.readPreview() } }.disabled(controller.busy)
                }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Text("截止事项预览").font(.headline)
                if let preview = controller.preview {
                    Text("\(preview.courseCount) 门课程 · \(tasks.count) 项有截止时间")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Group {
                if controller.preview == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.checkmark").font(.largeTitle).foregroundStyle(.secondary)
                        Text(controller.waitingForLogin ? "完成学校登录后，点击上方读取课程" : "连接后可在这里核对课程和截止时间")
                        Text("读取预览不会写入。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tasks.isEmpty {
                    Text("本次未读取到有明确截止时间的任务。")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tasks, id: \.identity) { task in
                                NativeDeadlineRow(task: task, clock: clock)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            Text("按截止时间先后显示；无截止时间的任务跳过。首次不新增往日任务；提醒事项的完成状态和个人备注保留。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Label("提醒事项", systemImage: "checklist").font(.headline)
            Text(controller.status).font(.callout).textSelection(.enabled)
            Text(controller.lastSync).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("启用同步到提醒事项") { Task { await controller.enable() } }
                    .buttonStyle(.borderedProminent).disabled(!controller.canEnable)
                Button("立即同步提醒事项") { Task { await controller.manualSync() } }
                    .disabled(!controller.enabled || controller.busy)
                Button(controller.waitingForLogin ? "取消连接" : "暂停提醒事项") { controller.pause() }
                    .disabled(!controller.enabled && !controller.waitingForLogin)
                Spacer()
            }
            if let calendar = controller.calendar {
                CalendarSourceControls(calendar: calendar, busy: controller.busy, canEnable: !controller.busy && controller.preview != nil,
                                       enable: controller.enableCalendar, sync: controller.manualSyncCalendar, pause: controller.pauseCalendar)
            }
            HStack {
                Button(controller.restoreEnabled ? "关闭本平台登录恢复" : "开启本平台登录恢复") {
                    Task { await controller.setRestore(!controller.restoreEnabled) }
                }.disabled(controller.busy || (!controller.restoreEnabled && !controller.anyEnabled))
                Spacer()
            }
            Text(controller.restoreStatus).font(.caption).foregroundStyle(.secondary)
            Text("启用后每天北京时间 00:00 检查，错过时唤醒补查。登录过期会提示重新登录。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 680, minHeight: 660)
    }
}

@MainActor private struct NativeDeadlineRow: View {
    let task: NativeDeadlineTask
    let clock: PreviewClock
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(task.title).font(.body.weight(.medium)).textSelection(.enabled)
            Text("课程：" + (CourseAssignments.normalizedName(task.courseName) ?? task.courseName))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            NativeDeadlineLabel(title: task.title, deadline: task.deadline!, clock: clock)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private struct NativeDeadlineLabel: View {
    let title: String
    let deadline: Deadline
    @ObservedObject var clock: PreviewClock
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.format.string(from: deadline.date) + " · 北京时间").foregroundStyle(.secondary)
            if let detail = CountdownPresentation.detail(for: event, now: clock.now) {
                Text(detail).foregroundStyle(detail.hasPrefix("已逾期") ? .red : .primary)
            }
        }.font(.caption)
    }
    private var event: FeedEvent {
        FeedEvent(uid: "", title: title, details: "", deadline: deadline, sequence: 0, modified: nil, cancelled: false)
    }
    private static let format: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "zh_CN"); value.timeZone = DailySchedule.timeZone
        value.dateFormat = "yyyy-MM-dd HH:mm"; return value
    }()
}

@MainActor private struct DeadlineOverview: View {
    @ObservedObject var model: MultiSourceAppModel
    private var bb: SyncController { model.bb }
    let clock: PreviewClock
    private struct Row: Identifiable {
        let id: String; let source: String; let course: String; let title: String; let deadline: Deadline
    }
    private var rows: [Row] {
        var values = (bb.preview?.events ?? []).compactMap { event -> Row? in
            guard !event.cancelled, let deadline = event.deadline else { return nil }
            return Row(id: "bb:" + event.uid, source: "BB", course: bb.courseName(for: event) ?? "课程待确认", title: event.title, deadline: deadline)
        }
        for controller in model.nativeSources {
            values += (controller.preview?.candidates ?? []).compactMap { task -> Row? in
                guard let deadline = task.deadline else { return nil }
                return Row(id: task.identity.stableHash, source: controller.platform.displayName, course: task.courseName,
                           title: task.title, deadline: deadline)
            }
        }
        return values.sorted { $0.deadline.date != $1.deadline.date ? $0.deadline.date < $1.deadline.date : $0.id < $1.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("先做最早到期的任务").font(.title2.bold())
            Text("汇总各平台本次读取的预览，按截止时间排序。请在各平台页完成连接和启用。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                sourceStatus("BB", enabled: bb.anyEnabled, busy: bb.busy)
                ForEach(model.nativeSources, id: \.platform.rawValue) { source in
                    sourceStatus(source.platform.displayName, enabled: source.anyEnabled, busy: source.busy)
                }
            }
            if rows.isEmpty {
                Text("尚无已读取的截止事项，请先打开对应平台页。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.title).font(.body.weight(.medium)).textSelection(.enabled)
                                Text(row.source + " · " + row.course).font(.caption).foregroundStyle(.secondary)
                                NativeDeadlineLabel(title: row.title, deadline: row.deadline, clock: clock)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("提醒事项中的排序由该列表的“排序方式”控制；选择“截止日期”可保持先到期在前。预览倒计时每分钟更新，提醒事项文字随每日同步更新。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 680, minHeight: 660)
    }
    private func sourceStatus(_ name: String, enabled: Bool, busy: Bool) -> some View {
        Text(name + "：" + (busy ? "正在处理" : enabled ? "已启用" : "未启用 / 暂停"))
            .font(.caption).padding(8).background(Color.gray.opacity(0.1), in: Capsule())
    }
}
