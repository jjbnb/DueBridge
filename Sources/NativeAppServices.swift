import Foundation
import Combine

@MainActor private final class NativeSessionHolder {
    let platform: NativePlatform
    private var currentID: UUID?
    private var current: NativeWebSession?
    init(platform: NativePlatform) { self.platform = platform }
    func session(_ id: UUID) -> NativeWebSession {
        if currentID == id, let current { return current }
        current?.close()
        let created = NativeWebSession(platform: platform, storeID: id)
        currentID = id; current = created
        return created
    }
    func cancel() { current?.cancel() }
    func close() { current?.close(); current = nil; currentID = nil }
}

extension NativeSourceServices {
    @MainActor static func live(platform: NativePlatform, gate: ReminderWriteGate, readGate: SourceReadGate) -> Self {
        let holder = NativeSessionHolder(platform: platform)
        var writer: NativeReminderWriter?
        func client() -> NativeReminderWriter {
            if let writer { return writer }
            let created = NativeReminderWriter(gate: gate); writer = created; return created
        }
        return Self(openLogin: { holder.session($0).openLogin() },
                    finishLogin: { id in try await readGate.withPermit { try await holder.session(id).finishLogin() } },
                    verify: { storeID, expectedFingerprint in
                        guard try await readGate.withPermit({ try await holder.session(storeID).verifyAccount() }) == expectedFingerprint else { throw NativeSessionError.accountChanged }
                    },
                    collect: { storeID, scope, account in
                        let collected = try await readGate.withPermit {
                            try await NativeTaskCollector.collect(scope: scope, expectedAccount: account, session: holder.session(storeID))
                        }
                        return NativeSourcePreview(scope: collected.scope, accountFingerprint: collected.accountFingerprint,
                                                   candidates: collected.candidates, courseCount: collected.courseCount)
                    },
                    requestAccess: { try await client().requestAccess() },
                    authorized: { NativeReminderWriter.authorized },
                    write: { storeID, preview, history, shouldContinue in
                        let result = try await client().reconcile(scope: preview.scope, candidates: preview.candidates, history: history,
                            verifyBinding: {
                                guard try await readGate.withPermit({ try await holder.session(storeID).verifyAccount() }) == preview.accountFingerprint else { throw NativeSessionError.accountChanged }
                            }, shouldContinue: shouldContinue)
                        return (result.result, result.knownHashes)
                    }, cancel: { holder.cancel() }, close: { holder.close() }, now: Date.init,
                    networkFailure: { error in
                        guard let failure = error as? NativeSessionError else { return false }
                        switch failure { case .network, .timeout: return true; default: return false }
                    }, errorMessage: { error in
                        if let safe = error as? SafeError { return safe.message }
                        if let failure = error as? NativeSessionError {
                            switch failure {
                            case .loginRequired: return "登录已过期或未完成，请重新连接本平台。"
                            case .accountChanged: return "当前账号已改变，请重新连接并核对课程。"
                            case .network, .timeout: return "连接失败或超时，本次未完成同步。"
                            case .cancelled: return "本次读取已取消。"
                            case .budgetExceeded: return "本次课程数据超过读取上限，已停止同步，请检查课程范围。"
                            default: return "平台返回的数据暂不兼容或无法验证，已停止本次同步。"
                            }
                        }
                        return "课程数据或本机记录无法完整校验，已停止本次同步。"
                    })
    }
}

@MainActor final class MultiSourceAppModel: ObservableObject {
    let bb: SyncController
    let nativeSources: [NativeSourceController]
    let destination = ReminderDestinationModel()
    let calendarDestination: CalendarDestinationModel
    private let coordinator: AppSyncCoordinator
    private var observations = Set<AnyCancellable>()
    var isBusy: Bool { calendarDestination.busy || bb.busy || nativeSources.contains(where: \.busy) }
    var isEnabled: Bool { bb.anyEnabled || nativeSources.contains(where: \.anyEnabled) }

    init() {
        let defaults = UserDefaults.standard
        let calendarDestination = CalendarDestinationModel(defaults: defaults)
        self.calendarDestination = calendarDestination
        let states = NativeStateStore(read: { defaults.data(forKey: $0) }, write: { defaults.set($1, forKey: $0) })
        let descriptors = SourceRegistry.production.nativeDescriptors
        var claims = Set<String>()
        if MacRestartSettings().load() != nil { claims.insert("bb") }
        for descriptor in descriptors {
            guard let platform = descriptor.nativePlatform else { continue }
            do { if try states.load(platform)?.active?.restoreEnabled == true { claims.insert(descriptor.runtimeSlot) } }
            catch { claims.insert(descriptor.runtimeSlot) }
        }
        let login = SharedLoginClaims(underlying: MacRestartLogin(), initialClaims: claims)
        let gate = ReminderWriteGate()
        let readGate = SourceReadGate(limit: 2)
        let schedules = AppSyncCoordinator(scheduler: DailySyncScheduler())
        coordinator = schedules
        bb = SyncController(services: .live(gate: gate, scheduler: schedules.slot("bb"), readGate: readGate),
                            restore: .live(login: login.facade("bb")),
                            calendar: CalendarSourceSync(destination: calendarDestination, defaults: defaults))
        nativeSources = descriptors.compactMap { descriptor in
            guard let platform = descriptor.nativePlatform else { return nil }
            return NativeSourceController(platform: platform, store: states,
                services: .live(platform: platform, gate: gate, readGate: readGate),
                scheduler: schedules.slot(descriptor.runtimeSlot), login: login.facade(descriptor.runtimeSlot),
                calendar: CalendarSourceSync(destination: calendarDestination, defaults: defaults))
        }
        bb.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        calendarDestination.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        for calendar in [bb.calendar] + nativeSources.map(\.calendar) {
            calendar?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        for source in nativeSources {
            source.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
    }
    func start() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.bb.start() }
            for source in nativeSources { group.addTask { await source.start() } }
        }
    }
    func handleWake() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.bb.handleWake() }
            for source in nativeSources { group.addTask { await source.handleWake() } }
        }
    }
    func syncNow() async {
        await bb.syncAllNow()
        for source in nativeSources { await source.syncAllNow() }
    }
    func pause() {
        bb.pauseCalendar(); bb.pause()
        for source in nativeSources { source.pauseCalendar(); source.pause() }
    }
    func refreshLoginStatus() { bb.refreshLoginStatus(); nativeSources.forEach { $0.refreshLoginStatus() } }
    func stop() { bb.stop(); nativeSources.forEach { $0.stop() }; coordinator.stop() }
}
