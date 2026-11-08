import SwiftUI

@MainActor struct CalendarDestinationView: View {
    @ObservedObject var model: CalendarDestinationModel
    let hasPreview: Bool
    let sourceBusy: Bool
    @State private var selectedAccount: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("苹果日历", systemImage: "calendar").font(.title2.bold())
            Text("先在课程来源页预览，再选择一个账户创建专用日历。推荐 iCloud，可在使用同一账户的设备上查看。")
                .foregroundStyle(.secondary)
            Text("苹果日历需要单独授权。事件会显示截止时间，支持时标记为空闲，不添加应用提醒。")
                .font(.callout).foregroundStyle(.secondary)
            if model.identifier == nil {
                Button("授权并读取日历账户") {
                    Task {
                        selectedAccount = nil
                        await model.loadAccounts()
                    }
                }.disabled(!hasPreview || sourceBusy || model.busy)
                if !model.accounts.isEmpty {
                    Picker("日历账户", selection: $selectedAccount) {
                        Text("请选择").tag(String?.none)
                        ForEach(model.accounts) { account in
                            Text(account.recommended ? account.title + "（推荐）" : account.title).tag(Optional(account.id))
                        }
                    }.frame(maxWidth: 380)
                    Button("创建“" + CalendarDestinationModel.calendarTitle + "”") {
                        if let selectedAccount { model.create(in: selectedAccount) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!hasPreview || sourceBusy || model.busy || selectedAccount == nil)
                }
            } else {
                LabeledContent("专用日历", value: CalendarDestinationModel.calendarTitle)
                if let accountName = model.accountName { LabeledContent("日历账户", value: accountName) }
                Button("检查权限和专用日历") { Task { await model.loadAccounts() } }
                    .disabled(sourceBusy || model.busy)
            }
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .padding(24).frame(minWidth: 680, minHeight: 660, alignment: .topLeading)
    }
}

@MainActor struct CalendarSourceControls: View {
    @ObservedObject var calendar: CalendarSourceSync
    let busy: Bool
    let canEnable: Bool
    let enable: () async -> Void
    let sync: () async -> Void
    let pause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("苹果日历", systemImage: "calendar").font(.headline)
            Text(calendar.status).font(.callout).textSelection(.enabled)
            Text(calendar.lastSync).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("启用同步到苹果日历") { Task { await enable() } }
                    .disabled(!canEnable || calendar.enabled)
                Button("立即同步日历") { Task { await sync() } }.disabled(!calendar.enabled || busy)
                Button("暂停日历") { pause() }.disabled(!calendar.enabled)
            }
        }
    }
}
