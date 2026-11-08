import AppKit
import SwiftUI

@MainActor
struct MainView: View {
    @ObservedObject var controller: SyncController
    let previewClock: PreviewClock
    @State private var revealSource = false
    private var eligible: Int { SyncPlanner.plan(events: controller.preview?.events ?? [], existing: []).operations.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "calendar.badge.clock").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("归期 · DueBridge").font(.title2.bold())
                    Text("将课程截止事项同步到提醒事项或苹果日历").foregroundStyle(.secondary)
                }
                Spacer()
                Text(controller.anyEnabled ? "同步已启用" : "未启用 / 已暂停")
                    .font(.caption.bold()).padding(7)
                    .background(controller.anyEnabled ? Color.green.opacity(0.13) : Color.gray.opacity(0.12), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("BB 私人日历订阅链接").font(.headline)
                HStack {
                    Group {
                        if revealSource { TextField("粘贴BB“Get External Calendar Link”订阅链接", text: $controller.source) }
                        else { SecureField("粘贴BB“Get External Calendar Link”订阅链接", text: $controller.source) }
                    }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("BB 私人日历订阅链接")
                    .disabled(controller.busy)
                    Button(revealSource ? "隐藏" : "显示") { revealSource.toggle() }
                    Button("读取日历") { Task { await controller.readPreview() } }
                        .disabled(controller.busy || controller.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut("r", modifiers: .command)
                }
                Text("请从 BB 日历的“Get External Calendar Link”复制私人订阅链接；日历网页地址不能用于同步。读取仅预览。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("日历预览").font(.headline)
                if let feed = controller.preview {
                    Text("共 \(feed.events.count) 项 · 今天起可新增 \(eligible) 项").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
            }
            Group {
                if let feed = controller.preview {
                    if feed.events.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
                            Text("日历中没有可同步的单次事件")
                            Text("请检查下方提示和 BB 日历选择范围。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(feed.events, id: \.uid) { event in
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: event.cancelled ? "xmark.circle" : "calendar")
                                                .foregroundStyle(event.cancelled ? .orange : .blue).padding(.top, 3)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(event.title).font(.body.weight(.medium)).textSelection(.enabled)
                                                PreviewDeadlineLine(event: event, clock: previewClock)
                                                PreviewCourseField(controller: controller, event: event)
                                            }
                                            Spacer(minLength: 8)
                                            if event.cancelled { Text("已取消").font(.caption).foregroundStyle(.orange) }
                                        }.padding(.vertical, 10).padding(.horizontal, 12)
                                        Divider()
                                    }
                                }
                            }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                        Text(controller.enabled ? "自动同步已恢复" : "粘贴订阅链接，然后读取日历")
                        Text(controller.enabled ? "点“读取日历”查看预览；也可点“立即同步”手动检查。" : "先核对这里确实都是课程截止事项，再启用同步。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            if let warnings = controller.preview?.warnings, !warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 65)
            }
            Text("新增事件需确认课程，保存后点立即同步更新标题。")
                .font(.caption).foregroundStyle(.secondary)
            Text("首次只新增今天起的事项，旧事项仍会更新；手动完成后保持完成。\n倒计时每分钟本地更新，仅表示源截止时间，不反映提醒事项完成状态。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label("提醒事项", systemImage: "checklist").font(.headline)
                Text(controller.status).font(.callout).textSelection(.enabled)
                Text(controller.lastSync).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("启用同步到提醒事项") { Task { await controller.enable() } }
                    .buttonStyle(.borderedProminent).disabled(!controller.canEnable)
                Button("立即同步提醒事项") { Task { await controller.manualSync() } }
                    .disabled(!controller.enabled || controller.busy)
                Button("暂停提醒事项") { controller.pause() }.disabled(!controller.enabled)
                Spacer()
            }
            if let calendar = controller.calendar {
                CalendarSourceControls(calendar: calendar, busy: controller.busy, canEnable: !controller.busy && controller.preview != nil,
                                       enable: controller.enableCalendar, sync: controller.manualSyncCalendar, pause: controller.pauseCalendar)
            }
            HStack {
                Button("保存并开机恢复") { Task { await controller.saveForRestart() } }
                    .disabled(!controller.canSaveForRestart)
                if controller.restartConfigured {
                    Button("恢复已保存链接") { Task { await controller.recoverSavedSource() } }
                        .disabled(controller.busy)
                    Button("关闭开机恢复") { Task { await controller.disableRestartRestore() } }
                        .disabled(controller.busy)
                }
                if controller.loginAvailability == .requiresApproval {
                    Button("打开登录项设置") { controller.openLoginSettings() }
                }
                Spacer()
            }
            Text(controller.restoreStatus).font(.caption).foregroundStyle(.secondary)
            Text(controller.restartConfigured
                 ? "每天北京时间 00:00 检查；错过时唤醒补查，同日成功不重复补查。暂停会保留为暂停；退出保留恢复设置。"
                 : "默认仅本次运行。选择保存后，链接存入本机钥匙串并设置登录启动；系统可能需要你确认。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(minWidth: 680, minHeight: 660)
    }
    // The list and course draft fields do not subscribe to the minute clock.
}

@MainActor
private struct PreviewDeadlineLine: View {
    let event: FeedEvent
    @ObservedObject var clock: PreviewClock
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(deadlineText(event)).foregroundStyle(.secondary)
            if let detail = CountdownPresentation.detail(for: event, now: clock.now) {
                Text(detail)
                    .fontWeight(.medium)
                    .foregroundStyle(countdownColor(event, detail: detail, now: clock.now))
                    .accessibilityLabel("源日历截止状态：" + detail)
            }
        }.font(.caption)
    }
    private func countdownColor(_ event: FeedEvent, detail: String, now: Date) -> Color {
        if detail.hasPrefix("已逾期") { return .red }
        if detail == "已到期" || detail.hasPrefix("今天到期") { return .orange }
        if let deadline = event.deadline, !deadline.isAllDay,
           deadline.date.timeIntervalSince(now) < 86400 { return .orange }
        return .primary
    }
    private static let deadlineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter
    }()
    private func deadlineText(_ event: FeedEvent) -> String {
        guard let deadline = event.deadline else { return "取消通知（没有新的截止时间）" }
        if deadline.isAllDay {
            let p = deadline.components
            return String(format: "%04d-%02d-%02d · 全天", p.year ?? 0, p.month ?? 0, p.day ?? 0)
        }
        return Self.deadlineFormatter.string(from: deadline.date) + " · 本机时间"
    }
}

@MainActor
private struct PreviewCourseField: View {
    @ObservedObject var controller: SyncController
    let event: FeedEvent
    @State private var draft: String

    init(controller: SyncController, event: FeedEvent) {
        self.controller = controller
        self.event = event
        _draft = State(initialValue: controller.courseName(for: event) ?? "")
    }
    private var editable: Bool { !controller.busy && CourseAssignments.key(for: event) != nil }
    var body: some View {
        HStack(spacing: 7) {
            Text("课程").font(.caption).foregroundStyle(.secondary)
            TextField("课程待确认", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("课程：" + event.title)
                .onSubmit(save)
            Button("保存", action: save)
                .accessibilityLabel("保存课程：" + event.title)
        }
        .disabled(!editable)
        .onChange(of: controller.courseName(for: event)) { _, name in draft = name ?? "" }
    }
    private func save() {
        if controller.setCourseName(draft, for: event) {
            draft = controller.courseName(for: event) ?? ""
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = MultiSourceAppModel()
    private var controller: SyncController { model.bb }
    private var startupTask: Task<Void, Never>?
    private let previewClock = PreviewClock()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var wakeToken: NSObjectProtocol?
    private var clockChangeToken: NSObjectProtocol?
    private var syncMenu: NSMenuItem!
    private var pauseMenu: NSMenuItem!
    private var statusMenu: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingView(rootView: MultiSourceView(model: model, clock: previewClock))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = "归期 · DueBridge"
        window.contentView = hosting
        window.minSize = NSSize(width: 720, height: 700)
        window.isReleasedWhenClosed = false
        window.center()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusMenu = menu.addItem(withTitle: "尚未启用同步", action: nil, keyEquivalent: "")
        statusMenu.isEnabled = false
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "打开 归期 · DueBridge", action: #selector(showWindow), keyEquivalent: "o"); show.target = self
        syncMenu = menu.addItem(withTitle: "立即同步所有已启用目标", action: #selector(syncNow), keyEquivalent: ""); syncMenu.target = self
        pauseMenu = menu.addItem(withTitle: "暂停同步", action: #selector(pause), keyEquivalent: ""); pauseMenu.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 归期 · DueBridge", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = " DDL"
        statusItem.button?.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "归期 · DueBridge")
        statusItem.button?.toolTip = "归期 · DueBridge：每天北京时间 00:00 检查"
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 归期 · DueBridge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 归期 · DueBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.handleWake() }
        }
        // Foundation's clock-change notification is available since macOS 10.6;
        // use its SDK-imported name instead of the macOS 26-only message API.
        clockChangeToken = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.handleWake() }
        }
        startupTask = Task { await model.start() }
        showWindow()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func menuWillOpen(_ menu: NSMenu) {
        let busy = model.isBusy
        let enabled = model.isEnabled
        statusMenu.title = busy ? "正在处理…" : (enabled ? "每天北京时间零点同步已启用" : "同步已暂停 / 未启用")
        syncMenu.isEnabled = enabled && !busy
        pauseMenu.isEnabled = enabled
    }
    private func updatePreviewClock() {
        previewClock.setRunning(window != nil && window.isVisible && !window.isMiniaturized && !NSApp.isHidden && NSApp.isActive)
    }
    func applicationDidBecomeActive(_ notification: Notification) { updatePreviewClock(); model.refreshLoginStatus() }
    func applicationWillResignActive(_ notification: Notification) { previewClock.stop() }
    func applicationDidResignActive(_ notification: Notification) { previewClock.stop() }
    func applicationDidHide(_ notification: Notification) { previewClock.stop() }
    func applicationDidUnhide(_ notification: Notification) { updatePreviewClock() }
    func applicationWillTerminate(_ notification: Notification) {
        previewClock.stop(); startupTask?.cancel(); model.stop()
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
        wakeToken = nil
        if let clockChangeToken { NotificationCenter.default.removeObserver(clockChangeToken) }
        clockChangeToken = nil
    }
    func windowWillClose(_ notification: Notification) { previewClock.stop() }
    func windowDidMiniaturize(_ notification: Notification) { previewClock.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePreviewClock() }
    func windowDidBecomeKey(_ notification: Notification) { updatePreviewClock() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updatePreviewClock() }
    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updatePreviewClock()
    }
    @objc private func syncNow() { Task { await model.syncNow() } }
    @objc private func pause() { model.pause() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

@main
struct BBDeadlineApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
