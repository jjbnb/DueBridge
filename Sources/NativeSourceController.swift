import Foundation
import Combine

struct NativeSourcePreview {
    let scope: SourceScope
    let accountFingerprint: String
    let candidates: [NativeDeadlineTask]
    let courseCount: Int
}
@MainActor struct NativeSourceServices {
    var openLogin: (UUID) -> Void
    var finishLogin: (UUID) async throws -> String
    var verify: (UUID, String) async throws -> Void
    var collect: (UUID, SourceScope, String) async throws -> NativeSourcePreview
    var requestAccess: () async throws -> Void
    var authorized: () -> Bool
    var write: (UUID, NativeSourcePreview, NativeTaskHistory, @escaping () -> Bool) async throws -> (SyncResult, Set<String>)
    var cancel: () -> Void
    var close: () -> Void
    var now: () -> Date
    var networkFailure: (Error) -> Bool
    var errorMessage: (Error) -> String
}
@MainActor final class NativeSourceController: ObservableObject {
    let platform: NativePlatform
    @Published private(set) var preview: NativeSourcePreview?
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var waitingForLogin = false
    @Published private(set) var status = "尚未连接。连接后先预览，再启用写入。"
    @Published private(set) var lastSync = "尚无成功同步记录"
    @Published private(set) var restoreStatus = "未开启登录恢复"
    @Published private(set) var restoreEnabled = false
    private let store: NativeStateStore
    private let services: NativeSourceServices
    private let scheduler: SyncScheduling
    private let login: RestartLogin
    private var state: NativePlatformState?
    private var damagedState = false
    private var started = false
    private var generation = 0
    private var pendingAutomatic = false
    var connected: Bool { state?.active != nil }
    var canEnable: Bool { !busy && !enabled && preview != nil && !waitingForLogin }
    init(platform: NativePlatform, store: NativeStateStore, services: NativeSourceServices, scheduler: SyncScheduling, login: RestartLogin) {
        self.platform = platform; self.store = store; self.services = services; self.scheduler = scheduler; self.login = login
        do { state = try store.load(platform); restoreEnabled = state?.active?.restoreEnabled == true }
        catch { damagedState = true; status = "本机连接记录无法校验，已停止接入以避免重复事项。请保留记录并检查应用。" }
    }
    private func save(_ value: NativePlatformState) throws { try store.save(value, for: platform); state = value }
    private func change(_ edit: (inout NativeConnectionState) -> Void) throws {
        guard var next = state, var current = next.active else { throw NativeStateError.invalidState }
        edit(&current); try next.update(current); try save(next)
    }
    private func scope(_ record: NativeConnectionState) throws -> SourceScope {
        try SourceScope(platform: platform, host: platform.verifiedHost, connectionID: record.id)
    }
    private func valid(_ token: Int, _ id: UUID) -> Bool {
        started && generation == token && state?.activeID == id && !Task.isCancelled
    }
    func start() async {
        guard !started else { return }; started = true
        refreshLoginStatus()
        guard let c = state?.active, let storeID = state?.storeID,
              c.restoreEnabled && c.desiredEnabled, !damagedState else { return }
        let token = generation
        do {
            busy = true; defer { busy = false }
            status = "正在验证本平台保存的登录状态…"
            try await services.verify(storeID, c.accountFingerprint)
            guard valid(token, c.id) else { return }
        } catch {
            guard valid(token, c.id) else { return }
            // Keep saved intent and history so reconnect can recover this scope.
            status = services.errorMessage(error) + " 请重新连接本平台后恢复同步。"
            return
        }
        enabled = true
        status = "本平台登录已验证，已恢复同步。"
        if let date = c.lastSuccess { lastSync = "上次成功：" + Self.time(date) }
        await handleWake()
    }
    func beginConnect() {
        guard started, !busy, !damagedState else { return }
        generation += 1; pendingAutomatic = false; scheduler.cancel(); services.cancel()
        enabled = false; preview = nil
        do {
            if state == nil { try save(NativePlatformState()) }
            if state?.active != nil { try change { $0.desiredEnabled = false; $0.retry = nil } }
            waitingForLogin = true
            services.openLogin(state!.storeID)
            status = "请在工具的登录窗口完成登录，再点“登录完成，读取课程”。登录状态仅保存在本机。"
        } catch { status = "无法保存连接记录，未开始登录。" }
    }
    func finishConnect() async {
        guard started, !busy, waitingForLogin, let saved = state else { return }
        let token = generation
        busy = true; defer { finishOperation() }
        do {
            let fingerprint = try await services.finishLogin(saved.storeID)
            guard started, generation == token else { return }
            var next = saved
            let connected = try next.connect(fingerprint: fingerprint)
            try save(next)
            restoreEnabled = connected.restoreEnabled
            // Switching accounts releases this platform's former startup claim.
            if !restoreEnabled { try? await login.unregister() }
            guard valid(token, connected.id) else { return }
            waitingForLogin = false
            try await loadPreview(record: connected, token: token)
            status = "课程已读取；核对截止时间后可启用同步。尚未写入提醒事项。"
            refreshLoginStatus()
        } catch { if generation == token { status = services.errorMessage(error) } }
    }
    private func loadPreview(record: NativeConnectionState, token: Int) async throws {
        guard let storeID = state?.storeID else { throw NativeStateError.invalidState }
        let expectedScope = try scope(record)
        let result = try await services.collect(storeID, expectedScope, record.accountFingerprint)
        guard valid(token, record.id) else { return }
        guard result.scope == expectedScope, result.accountFingerprint == record.accountFingerprint,
              result.candidates.allSatisfy({ $0.identity.scope == expectedScope }) else { throw NativeStateError.invalidState }
        _ = try NativeTaskSelection.select(result.candidates)
        preview = result
    }
    func readPreview() async {
        guard started, !busy, !waitingForLogin, let c = state?.active else { return }
        let token = generation
        busy = true; status = "正在完整读取课程任务；预览不会写入提醒事项。"
        defer { finishOperation() }
        do {
            try await loadPreview(record: c, token: token)
            if valid(token, c.id) { status = "预览已更新，按截止时间排序；尚未写入提醒事项。" }
        } catch { if valid(token, c.id) { preview = nil; status = services.errorMessage(error) } }
    }
    func enable() async {
        guard started, canEnable, let c = state?.active else { return }
        let token = generation
        busy = true; defer { finishOperation() }
        do {
            try await services.requestAccess()
            guard valid(token, c.id) else { return }
            try change { $0.desiredEnabled = true; $0.retry = nil; $0.blocked = false }
            enabled = true
            await performSync(token: token)
        } catch { if valid(token, c.id) { status = services.errorMessage(error) } }
    }
    func manualSync() async {
        guard started, enabled, !busy, !waitingForLogin else { return }
        busy = true; defer { finishOperation() }
        await performSync(token: generation)
    }
    func pause() {
        generation += 1; pendingAutomatic = false; enabled = false; waitingForLogin = false
        services.cancel(); scheduler.cancel()
        do { if state?.active != nil { try change { $0.desiredEnabled = false; $0.retry = nil } } }
        catch { status = "已暂停本次运行，但未能保存暂停状态。请检查本机连接记录。"; return }
        status = "已暂停；已有事项、个人备注和完成状态保留。"
    }
    func handleWake() async {
        guard started, enabled else { return }
        if busy { pendingAutomatic = true; return }
        guard var c = state?.active else { return }
        let due = c.automaticDue(now: services.now())
        do { try change { $0 = c } } catch { status = "无法保存检查状态，自动同步已停止。"; enabled = false; return }
        guard due else { arm(); return }
        busy = true; defer { finishOperation() }
        await performSync(token: generation)
    }
    private func performSync(token: Int) async {
        guard let c = state?.active, let storeID = state?.storeID else { return }
        do {
            status = "正在读取并核对课程任务…"
            try await loadPreview(record: c, token: token)
            guard valid(token, c.id), enabled, let fresh = preview else { return }
            guard services.authorized() else { throw SafeError("提醒事项权限已关闭，请在系统设置中允许后手动重试。") }
            let history = NativeTaskHistory(scope: fresh.scope, knownHashes: c.knownHashes, hasImported: c.hasImported)
            let (result, hashes) = try await services.write(storeID, fresh, history) { self.valid(token, c.id) && self.enabled }
            guard valid(token, c.id), enabled else { return }
            // Writer returns only after commit; checkpointing never precedes it.
            let now = services.now()
            try change { $0.recordSuccess(hashes: hashes, now: now) }
            lastSync = "\(Self.time(now))：新增 \(result.added)，更新 \(result.updated)，跳过首次过期项 \(result.skipped)"
            status = "同步完成。每天北京时间 00:00 更新，错过时唤醒补查。"
            if !result.warnings.isEmpty { status += " " + result.warnings.joined(separator: " ") }
        } catch {
            guard valid(token, c.id), enabled else { return }
            let network = services.networkFailure(error)
            do { try change { $0.recordFailure(network: network, now: services.now()) } }
            catch { status = "同步结果无法保存，已暂停本次运行。请检查本机连接记录。"; enabled = false; return }
            status = services.errorMessage(error) + (network ? " 将有限重试，也可点立即同步。" : " 自动重试已停止，请重新登录或处理后手动同步。")
        }
    }
    func setRestore(_ value: Bool) async {
        guard started, !busy, state?.active != nil, !value || enabled else { return }
        busy = true; defer { finishOperation() }
        do {
            try change { $0.restoreEnabled = value }
            restoreEnabled = value
            if value { _ = try login.register() } else { try await login.unregister() }
            refreshLoginStatus()
        } catch {
            restoreStatus = value ? "恢复意愿已保存；登录启动设置未完成，可再次点开启重试。" : "已关闭本平台恢复意愿；系统登录项更新未完成。"
        }
    }
    func refreshLoginStatus() {
        guard restoreEnabled else { restoreStatus = "未开启登录恢复；退出后可手动重新连接同一账号。"; return }
        switch login.status() {
        case .enabled: restoreStatus = "登录恢复已开启；登录过期时需在工具内重新登录。"
        case .requiresApproval: restoreStatus = "登录恢复意愿已保存；请在系统登录项中允许应用。"
        default: restoreStatus = "恢复意愿已保存；请点击开启登录恢复重试系统设置。"
        }
    }
    private func arm() {
        scheduler.cancel()
        guard started, enabled, var c = state?.active else { return }
        let date = c.nextCheck(now: services.now())
        do { try change { $0 = c } } catch { enabled = false; status = "无法保存检查状态，自动同步已停止。"; return }
        if let date {
            scheduler.schedule(at: date) { [weak self] in Task { @MainActor in await self?.handleWake() } }
        }
    }
    private func finishOperation() {
        busy = false; arm()
        if pendingAutomatic, started, enabled {
            pendingAutomatic = false
            Task { @MainActor [weak self] in await self?.handleWake() }
        }
    }
    func stop() {
        started = false; generation += 1; enabled = false; pendingAutomatic = false
        scheduler.cancel(); services.close()
        // A normal quit preserves persisted enable/restore intent.
    }
    private static func time(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "zh_CN"); format.timeZone = DailySchedule.timeZone
        format.dateFormat = "MM-dd HH:mm"; return format.string(from: date)
    }
}
