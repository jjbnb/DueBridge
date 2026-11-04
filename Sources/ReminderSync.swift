import Foundation
import EventKit
import Combine

final class FeedFetcher: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let limit = FeedHTTPPolicy.maxBytes
    private var buffer = Data()
    private var completion: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var settled = false
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
    }()
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    static func fetch(_ address: String) async throws -> Feed {
        let url = try FeedAddress.validate(address)
        let loader = FeedFetcher()
        let bytes = try await loader.load(url)
        guard let text = String(data: bytes, encoding: .utf8) else { throw SafeError("日历不是有效的 UTF-8 文本，未同步。") }
        return try ICSParser.parse(text)
    }
    static func validateResponse(_ response: HTTPURLResponse) throws {
        guard let url = response.url else { throw SafeError("无法读取日历（服务器状态异常），未修改提醒事项。") }
        // Validate scope before considering HTTP retries: an unsafe redirect or
        // login-page URL must never become retryable just because it says 503.
        _ = try FeedAddress.validate(url.absoluteString)
        if [408, 429].contains(response.statusCode) || (500...599).contains(response.statusCode) {
            throw NetworkFailure()
        }
        try FeedHTTPPolicy.validate(status: response.statusCode, address: url.absoluteString, mimeType: response.mimeType, expectedBytes: response.expectedContentLength)
    }
    private func load(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.cancellationLock.lock()
                    let cancelled = self.cancellationRequested
                    self.cancellationLock.unlock()
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.completion = continuation
                    let config = URLSessionConfiguration.ephemeral
                    config.urlCache = nil
                    config.httpCookieStorage = nil
                    config.urlCredentialStorage = nil
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 45
                    config.httpMaximumConnectionsPerHost = 1
                    self.session = URLSession(configuration: config, delegate: self, delegateQueue: self.queue)
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("text/calendar, text/plain;q=0.8", forHTTPHeaderField: "Accept")
                    self.task = self.session!.dataTask(with: request)
                    self.task!.resume()
                }
            }
        } onCancel: {
            self.cancellationLock.lock(); self.cancellationRequested = true; self.cancellationLock.unlock()
            self.queue.addOperation { self.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !settled else { return }
        settled = true
        let callback = completion; completion = nil
        callback?.resume(with: result)
        session?.invalidateAndCancel()
        session = nil; task = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? FeedAddress.validate(url.absoluteString)) != nil else {
            completionHandler(nil)
            finish(.failure(SafeError("日历跳转到了登录页或学校日历范围之外，未同步。")))
            return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SafeError("无法读取日历（服务器状态异常），未修改提醒事项。")))
            return
        }
        do {
            try Self.validateResponse(response)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !settled else { return }
        guard buffer.count + data.count <= limit else { finish(.failure(SafeError("日历文件过大，未同步。"))); return }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !settled else { return }
        if error != nil { finish(.failure(NetworkFailure())) }
        else { finish(.success(buffer)) }
    }
}

struct SyncResult {
    var added: Int
    var updated: Int
    var skipped: Int
    var warnings: [String]
}

@MainActor
final class ReminderWriter {
    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private lazy var destinations = ReminderDestinationService.live(defaults: defaults, store: store)
    static var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func requestAccess() async throws {
        if Self.authorized { return }
        do {
            let allowed = try await store.requestFullAccessToReminders()
            guard allowed else { throw SafeError("未获得提醒事项权限。可在“系统设置 → 隐私与安全性 → 提醒事项”中允许后，再点启用同步。") }
        } catch let error as SafeError { throw error }
        catch { throw SafeError("无法取得提醒事项权限，请检查系统设置后重试。") }
    }
    private func destination() throws -> (EKCalendar, Bool, ReminderDestinationSelection) {
        let selection = destinations.selection()
        switch selection.identifier {
        case .saved, .invalid:
            do {
                let target = try destinations.resolve(expected: selection)
                guard let calendar = store.calendar(withIdentifier: target.id),
                      calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications else {
                    throw ReminderDestinationError.missing
                }
                return (calendar, false, selection)
            } catch let failure as ReminderDestinationError { throw SafeError(failure.message) }
        case .unset: break
        }
        // Preserve BB's legacy title lookup/create only when no ID was saved.
        let matches = store.calendars(for: .reminder).filter { $0.title == "BB DDL" }
        guard matches.count <= 1 else { throw SafeError("发现多个名为 BB DDL 的列表，请只保留一个该名称后重试。") }
        if let calendar = matches.first {
            guard calendar.allowsContentModifications else { throw SafeError("BB DDL 列表不可写。") }
            return (calendar, false, selection)
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "BB DDL"
        // Use a source already capable of holding reminders, normally the user's default.
        if let defaultSource = store.defaultCalendarForNewReminders()?.source { calendar.source = defaultSource }
        else if let source = store.calendars(for: .reminder).first(where: { $0.allowsContentModifications })?.source { calendar.source = source }
        else if let source = store.sources.first(where: { $0.sourceType == .local }) { calendar.source = source }
        else { throw SafeError("没有可用的提醒事项账户，请先在苹果提醒事项中创建一个列表。") }
        return (calendar, true, selection)
    }
    private func validateDestination(_ selection: ReminderDestinationSelection, calendar: EKCalendar, isNew: Bool) throws {
        do {
            if isNew {
                try destinations.validateUnchanged(selection)
            } else {
                try destinations.validate(selection, calendarID: calendar.calendarIdentifier)
                guard calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications else {
                    throw ReminderDestinationError.readOnly
                }
            }
        } catch let failure as ReminderDestinationError { throw SafeError(failure.message) }
    }
    func reconcile(_ feed: Feed, courseNames: [String: String], shouldContinue: () -> Bool) async throws -> SyncResult {
        guard Self.authorized else { throw SafeError("提醒事项权限已关闭；同步已停止。") }
        store.refreshSourcesIfNecessary()
        let (calendar, isNew, destinationSelection) = try destination()
        let reminders: [EKReminder]
        if isNew { reminders = [] }
        else {
            let predicate = store.predicateForReminders(in: [calendar])
            reminders = try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { values in
                    if let values { continuation.resume(returning: values) }
                    else { continuation.resume(throwing: SafeError("无法读取 BB DDL 列表，未同步。")) }
                }
            }
        }
        try validateDestination(destinationSelection, calendar: calendar, isNew: isNew)
        // Pause may arrive while EventKit fetches. No staged write has happened yet.
        guard shouldContinue() else { throw SafeError("已暂停；此次读取未写入提醒事项。") }
        let storedManaged = reminders.compactMap { reminder -> ManagedReminder? in
            guard let marker = ManagedNotes.identity(in: reminder.notes ?? "") else { return nil }
            let parts = reminder.dueDateComponents
            var calendar = parts?.calendar ?? Calendar(identifier: .gregorian)
            calendar.timeZone = parts?.timeZone ?? .current
            let due = parts.flatMap { calendar.date(from: $0) }
            return ManagedReminder(id: reminder.calendarItemIdentifier, marker: marker, isCompleted: reminder.isCompleted, notes: reminder.notes ?? "", identityVersion: ManagedNotes.identityVersion(in: reminder.notes ?? "") ?? 1, title: reminder.title ?? "", dueDate: due, isAllDay: parts?.hour == nil && parts?.minute == nil)
        }
        // Legacy exact matching is one-time and bijective. Version 2 never falls back.
        let managed = try LegacyAdoption.prepare(events: feed.events, existing: storedManaged)
        let knownMarkers = Set(defaults.stringArray(forKey: "managedUIDHashes") ?? [])
        try ReconciliationSafety.validate(events: feed.events,
                                          recognizedMarkers: Set(managed.map(\.marker)),
                                          knownMarkers: knownMarkers,
                                          previouslySynced: ReminderDestinationBBImportPolicy.previouslySynced(
                                            selection: destinations.selection(),
                                            hasHashCheckpoint: defaults.object(forKey: "managedUIDHashes") != nil,
                                            legacyHint: defaults.bool(forKey: "bbLegacyImportEvidence")))
        let plan = SyncPlanner.plan(events: feed.events, existing: managed)
        let titleSnapshotDate = Date()
        var byID = [String: EKReminder]()
        for reminder in reminders { byID[reminder.calendarItemIdentifier] = reminder }
        var added = 0, updated = 0
        do {
            try validateDestination(destinationSelection, calendar: calendar, isNew: isNew)
            if isNew && !plan.operations.isEmpty { try store.saveCalendar(calendar, commit: false) }
            for operation in plan.operations {
                let reminder: EKReminder
                if let id = operation.existingID {
                    guard let found = byID[id] else { throw SafeError("提醒事项在同步过程中发生变化，请重试。") }
                    reminder = found; updated += 1
                } else {
                    reminder = EKReminder(eventStore: store); reminder.calendar = calendar; added += 1
                }
                let oldNotes = reminder.notes ?? ""
                let oldAlarm = ManagedNotes.alarmDate(in: oldNotes)
                if let oldAlarm {
                    for alarm in reminder.alarms ?? [] where alarm.absoluteDate == oldAlarm && alarm.structuredLocation == nil {
                        reminder.removeAlarm(alarm)
                    }
                }
                let event = operation.event
                // Presentation is derived only after strict adoption and identity planning.
                reminder.title = CoursePresentation.reminderTitle(for: event, isCompleted: reminder.isCompleted, now: titleSnapshotDate, courseName: CourseAssignments.name(for: event, in: courseNames))
                if !event.cancelled {
                    guard let deadline = event.deadline else { throw SafeError("日历缺少截止时间，未同步。") }
                    reminder.dueDateComponents = deadline.components
                    // Completed reminders remain completed, and gain no obsolete notification.
                    if !reminder.isCompleted { reminder.addAlarm(EKAlarm(absoluteDate: deadline.date)) }
                }
                // Never assign isCompleted or completionDate on existing reminders.
                let nextAlarm = !event.cancelled && !reminder.isCompleted ? event.deadline?.date : nil
                reminder.notes = ManagedNotes.replacing(in: oldNotes, event: event, alarmDate: nextAlarm)
                try store.save(reminder, commit: false)
            }
            if !plan.operations.isEmpty {
                try validateDestination(destinationSelection, calendar: calendar, isNew: isNew)
                try store.commit()
                defaults.set(calendar.calendarIdentifier, forKey: "calendarID")
                let savedMarkers = Set(plan.operations.map { ManagedNotes.marker(uid: $0.event.uid) })
                defaults.set(Array(knownMarkers.union(managed.map(\.marker)).union(savedMarkers)).sorted(), forKey: "managedUIDHashes")
            }
        } catch {
            store.reset()
            if let safe = error as? SafeError { throw safe }
            throw SafeError("保存提醒事项失败；请检查列表和账户后重试。")
        }
        return SyncResult(added: added, updated: updated, skipped: plan.skippedPast, warnings: plan.warnings)
    }
}

@MainActor
final class SyncController: ObservableObject {
    @Published var source = "" {
        didSet {
            guard source != oldValue, !restoringSource else { return }
            preview = nil; previewAddress = nil
            invalidateOperation()
            enabled = false; activeAddress = nil; lastSuccessfulSync = nil
            restore.setIntent(false)
            updateRestoreStatus()
            armDailyTimer()
            status = "链接已改变；请重新读取日历并启用。保存新链接需再次点“保存并开机恢复”。"
        }
    }
    @Published private(set) var courseNames: [String: String]
    @Published private(set) var preview: Feed?
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未启用。本次运行使用链接，退出后需重新填写。"
    @Published private(set) var lastSync = "尚无实际同步记录"
    @Published private(set) var restoreStatus = "本次运行模式：退出后需重新填写链接。"
    @Published private(set) var loginAvailability: LoginAvailability = .notRegistered
    @Published private(set) var canRecover = false
    private let services: SyncServices
    private let restore: RestartRestore
    private var previewAddress: String?
    private var activeAddress: String?
    private var started = false
    private var restoringSource = false
    private var generation = 0
    private var lastSuccessfulSync: Date?
    private var pendingAutomaticCheck = false
    private var fetchTask: Task<Feed, Error>?
    private var credentialTask: Task<String, Error>?
    private var scheduledTask: Task<Void, Never>?
    // Session-only failures use the same finite policy without persisting consent.
    private var sessionRetry: RetryCheckpoint?
    private var sessionBlocked = false
    var canEnable: Bool { !busy && preview != nil && previewAddress == source && !enabled }
    var canSaveForRestart: Bool { !busy && enabled && preview != nil && previewAddress == source && activeAddress == source }
    var restartConfigured: Bool { restore.configured }

    init(services: SyncServices, restore: RestartRestore) {
        self.services = services; self.restore = restore
        courseNames = services.loadCourses()
    }
    func courseName(for event: FeedEvent) -> String? { CourseAssignments.name(for: event, in: courseNames) }
    @discardableResult
    func setCourseName(_ raw: String, for event: FeedEvent) -> Bool {
        guard !busy else { return false }
        guard let key = CourseAssignments.key(for: event) else {
            status = "此事件缺少已验证的 BB 稳定记录 ID，无法保存课程。"; return false
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { courseNames.removeValue(forKey: key) }
        else if let name = CourseAssignments.normalizedName(raw) { courseNames[key] = name }
        else { status = "课程名不能包含换行或控制字符；未保存。"; return false }
        services.saveCourses(courseNames)
        status = "课程已保存到本机。保存后点“立即同步”更新标题；尚未启用时请先启用同步。"
        return true
    }
    func start() async {
        guard !started else { return }; started = true
        guard restore.configured else { return }
        refreshLoginStatus()
        guard restore.metadata?.desiredEnabled == true else {
            restoreStatus = "已保存恢复设置；自动同步已暂停。重新启用前请读取日历，或点“恢复已保存链接”。"
            canRecover = true
            return
        }
        await restoreSavedSource(interactive: false)
    }
    func refreshLoginStatus() {
        guard restore.configured else { return }
        loginAvailability = restore.login.status()
        updateRestoreStatus()
    }
    private func updateRestoreStatus() {
        guard restore.configured else { restoreStatus = "本次运行模式：退出后需重新填写链接。"; return }
        let prefix = restore.metadata?.desiredEnabled == true ? "链接已保存，可在重开应用后恢复。" : "链接已保存；自动同步已暂停。"
        switch loginAvailability {
        case .enabled: restoreStatus = prefix + "登录启动已就绪。"
        case .requiresApproval: restoreStatus = prefix + "登录启动仍需在系统设置中批准。"
        case .notRegistered: restoreStatus = prefix + "登录启动未开启；可再次保存并开机恢复。"
        case .notFound: restoreStatus = prefix + "系统无法找到登录应用；请固定应用位置后重试。"
        }
    }
    func recoverSavedSource() async {
        guard restore.configured, !busy else { return }
        await restoreSavedSource(interactive: true)
    }
    private func restoreSavedSource(interactive: Bool) async {
        guard !busy, restore.configured else { return }
        let token = generation
        busy = true; canRecover = false
        status = "正在恢复已保存的链接…"
        defer { finishOperation() }
        do {
            let vault = restore.vault
            let task = Task { try await vault.read(interactive: interactive) }; credentialTask = task
            let address = try await task.value
            credentialTask = nil
            guard started, generation == token, restore.configured,
                  interactive || restore.metadata?.desiredEnabled == true else { return }
            _ = try FeedAddress.validate(address)
            guard restore.metadata?.fingerprint == RestartRestore.fingerprint(address) else { throw RestoreFailure.invalid }
            if interactive && !services.authorized() {
                status = "正在重新确认提醒事项授权…"
                try await services.requestAccess()
                // A system permission sheet yields the actor. Pause, editing
                // the source, or quitting must still cancel this restoration.
                guard started, generation == token, restore.configured,
                      restore.metadata?.fingerprint == RestartRestore.fingerprint(address) else { return }
            }
            guard services.authorized() else { throw SafeError("提醒事项权限未开启。请在系统设置中允许，再点“恢复已保存链接”。") }
            restoringSource = true; source = address; restoringSource = false
            activeAddress = address; enabled = true; restore.setIntent(true)
            lastSuccessfulSync = restore.validatedSuccess(address: address, now: services.now())
            if let date = lastSuccessfulSync {
                lastSync = "上次成功同步：" + DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
            }
            status = "已恢复同步；每天北京时间 00:00 检查，错过时唤醒补查。"
            updateRestoreStatus()
            await performAutomaticCheck()
            if restore.metadata?.blockedDay != nil {
                status = "已恢复链接；上次同步遇到日历或权限问题，自动重试已停止。请处理后点“立即同步”。"
            }
        } catch {
            guard started, generation == token else { return }
            enabled = false; canRecover = true
            status = "恢复未完成。" + recoveryMessage(error)
            restoreStatus = "已保存的同步意愿保留；点“恢复已保存链接”可重试，系统可能需要你授权。"
        }
    }
    func saveForRestart() async {
        guard canSaveForRestart else { return }
        let address = source, token = generation
        busy = true; defer { finishOperation() }
        do {
            _ = try FeedAddress.validate(address)
            try await restore.vault.save(address)
            guard valid(token, address) else { return }
            let sameSource = restore.metadata?.fingerprint == RestartRestore.fingerprint(address)
            let retry = sameSource ? restore.metadata?.retry : sessionRetry
            let blocked = sameSource ? restore.metadata?.blockedDay : (sessionBlocked ? services.now() : nil)
            restore.configure(address: address, lastSuccess: lastSuccessfulSync, retry: retry, blockedDay: blocked)
            sessionRetry = nil; sessionBlocked = false
            canRecover = false
            do { loginAvailability = try restore.login.register() }
            catch {
                loginAvailability = restore.login.status()
                updateRestoreStatus()
                restoreStatus += "链接保存成功；登录启动设置失败，请检查系统设置后重试。"
                return
            }
            updateRestoreStatus()
        } catch { restoreStatus = "未能保存恢复设置；本次运行的同步仍可继续。" + recoveryMessage(error) }
    }
    func disableRestartRestore() async {
        guard !busy, restore.configured else { return }
        // Revoke app consent first, even if the OS refuses to remove its login entry.
        pause(); restore.disable(); canRecover = false
        busy = true; defer { finishOperation() }
        do {
            try await restore.login.unregister()
            loginAvailability = .notRegistered
            restoreStatus = "已关闭开机恢复；保存的钥匙串条目不再读取。已有提醒事项保留。"
        } catch { restoreStatus = "已关闭链接恢复；登录启动未能关闭，请在系统登录项设置中移除应用。" }
    }
    func openLoginSettings() { if restore.configured { restore.login.openSettings() } }
    private func invalidateOperation() {
        generation += 1; pendingAutomaticCheck = false
        fetchTask?.cancel(); credentialTask?.cancel(); scheduledTask?.cancel()
        services.scheduler.cancel(); sessionRetry = nil; sessionBlocked = false
    }
    func stop() {
        started = false; invalidateOperation(); enabled = false
        // A normal quit preserves the user's persisted desiredEnabled choice.
    }
    private func armDailyTimer() {
        services.scheduler.cancel()
        guard started, enabled else { return }
        let now = services.now()
        var next = restore.nextCheck(now: now)
        if let retry = sessionRetry, retry.cycle == DailySchedule.midnight(for: now),
           let deadline = retry.deadline, deadline > now { next = min(next, deadline) }
        services.scheduler.schedule(at: next) { [weak self] in
            guard let self, self.started else { return }
            self.scheduledTask = Task { @MainActor [weak self] in await self?.syncAutomatically() }
        }
    }
    func handleWake() async { await syncAutomatically() }
    func handleClockChange() async { await syncAutomatically() }
    private func finishOperation() {
        busy = false; armDailyTimer()
        if pendingAutomaticCheck, started, enabled {
            pendingAutomaticCheck = false
            scheduledTask = Task { @MainActor [weak self] in await self?.syncAutomatically() }
        }
    }
    private func fetch(_ address: String) async throws -> Feed {
        let loader = services.fetch
        let task = Task { try await loader(address) }; fetchTask = task
        defer { fetchTask = nil }
        return try await task.value
    }
    func readPreview() async {
        guard !busy else { return }
        busy = true; status = "正在读取日历预览；不会申请提醒事项权限或写入。"
        let address = source, token = generation
        defer { finishOperation() }
        do {
            let feed = try await fetch(address)
            guard generation == token, source == address, started else { return }
            preview = feed; previewAddress = address
            status = "预览已读取，共 \(feed.events.count) 项；尚未写入提醒事项。"
        } catch { if generation == token { preview = nil; previewAddress = nil; status = safeMessage(error) } }
    }
    func enable() async {
        guard canEnable else { return }
        busy = true
        let address = source, token = generation
        defer { finishOperation() }
        do {
            _ = try FeedAddress.validate(address)
            status = "正在检查提醒事项授权；尚未保存开机恢复设置。"
            try await services.requestAccess()
            guard started, generation == token, source == address else { return }
            activeAddress = address; enabled = true; sessionRetry = nil; sessionBlocked = false
            // A newly entered source cannot reuse a saved credential after restart.
            if restore.metadata?.fingerprint == RestartRestore.fingerprint(address) { restore.setIntent(true) }
            await performSync(address: address, token: token)
        } catch { if generation == token { enabled = false; status = safeMessage(error) } }
    }
    func pause() {
        invalidateOperation(); enabled = false; restore.setIntent(false); updateRestoreStatus()
        status = busy ? "已暂停；正在进行的读取不会开始新的写入。" : "已暂停自动同步；已有提醒事项保留。"
    }
    func manualSync() async {
        guard started, enabled, !busy, let address = activeAddress else { return }
        busy = true; defer { finishOperation() }
        await performSync(address: address, token: generation)
    }
    func syncAutomatically() async {
        guard started, enabled else { return }
        guard !busy else { pendingAutomaticCheck = true; return }
        busy = true; defer { finishOperation() }
        await performAutomaticCheck()
    }
    private func performAutomaticCheck() async {
        guard started, enabled, let address = activeAddress else { return }
        let now = services.now()
        lastSuccessfulSync = RestartRestore.validSuccessDate(lastSuccessfulSync, now: now)
        if let retry = sessionRetry, retry.cycle != DailySchedule.midnight(for: now) { sessionRetry = nil }
        guard !sessionBlocked,
              sessionRetry.map({ $0.deadline.map { now >= $0 } ?? false }) ?? true,
              restore.automaticAllowed(address: address, lastSuccess: lastSuccessfulSync, now: now) else { return }
        await performSync(address: address, token: generation)
    }
    private func valid(_ token: Int, _ address: String) -> Bool {
        started && enabled && generation == token && source == address && activeAddress == address
    }
    private func performSync(address: String, token: Int) async {
        do {
            status = "正在检查 BB 日历…"
            let feed = try await fetch(address)
            guard valid(token, address) else { return }
            guard services.authorized() else { throw SafeError("提醒事项权限已关闭；请在系统设置中允许后手动重试。") }
            let result = try await services.reconcile(feed, courseNames) { self.valid(token, address) }
            guard valid(token, address) else { return }
            let now = services.now()
            lastSuccessfulSync = now; sessionRetry = nil; sessionBlocked = false
            restore.recordSuccess(address: address, now: now)
            preview = feed; previewAddress = address
            if !result.warnings.isEmpty { preview?.warnings += result.warnings }
            let time = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .short)
            lastSync = "\(time)：新增 \(result.added)，更新 \(result.updated)，跳过首次过期项 \(result.skipped)"
            status = "同步完成。每天北京时间 00:00 检查；错过时唤醒补查。"
        } catch {
            guard valid(token, address) else { return }
            let network = error is NetworkFailure
            let now = services.now()
            restore.recordFailure(address: address, network: network, now: now)
            if !restore.configured || restore.metadata?.fingerprint != RestartRestore.fingerprint(address) {
                if network {
                    sessionBlocked = false
                    let count = sessionRetry?.count ?? 0, delays: [TimeInterval] = [60, 300, 900]
                    sessionRetry = RetryCheckpoint(cycle: DailySchedule.midnight(for: now), count: min(count + 1, 3), deadline: count < 3 ? now.addingTimeInterval(delays[count]) : nil)
                } else { sessionBlocked = true }
            }
            status = safeMessage(error) + (network ? "自动重试最多 3 次；也可点“立即同步”。" : "请处理提示后点“立即同步”，自动重试已停止。")
        }
    }
    private func recoveryMessage(_ error: Error) -> String {
        switch error {
        case RestoreFailure.missing: return "未找到已保存的链接；请重新读取日历、启用并保存。"
        case RestoreFailure.denied: return "暂时无法读取或保存链接；点恢复重试，或检查系统授权。"
        case RestoreFailure.invalid: return "保存的链接与恢复设置不符；请重新读取日历、启用并保存。"
        case RestoreFailure.unavailable: return "系统服务暂不可用，请稍后手动重试。"
        default: return safeMessage(error)
        }
    }
    private func safeMessage(_ error: Error) -> String {
        if error is NetworkFailure { return "网络连接失败或超时，未修改提醒事项。" }
        return (error as? SafeError)?.message ?? "操作失败，请重试；未显示私人链接或服务器错误详情。"
    }
}
