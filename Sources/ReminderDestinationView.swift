import SwiftUI

@MainActor struct ReminderDestinationView: View {
    @ObservedObject var model: ReminderDestinationModel
    let busy: Bool
    @State private var selectedID = ""
    @State private var newName = "DueBridge"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("同步列表").font(.title2.bold())
            Text("BB、MO 和学在浙大的截止事项共用此列表。首次使用可以直接在这里完成设置。")
                .foregroundStyle(.secondary)
            Text(model.status).textSelection(.enabled)
            Button(model.loading ? "正在读取…" : "授权并读取列表") {
                Task { await model.refresh(busy: busy) }
            }
            .disabled(busy || model.loading)
            if model.loaded {
                GroupBox("选择现有列表") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.lists.isEmpty {
                            Text("暂无可写列表。请创建新列表，或在苹果提醒事项中配置账户。")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("列表", selection: $selectedID) {
                                Text("请选择列表").tag("")
                                ForEach(model.lists) { list in
                                    Text("\(list.title)（\(list.account)）").tag(list.id)
                                }
                            }
                            Button("使用所选列表") { model.select(id: selectedID, busy: busy) }
                                .disabled(selectedID.isEmpty)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("创建新列表") {
                    HStack {
                        TextField("新列表名称", text: $newName)
                        Button("创建并使用") { model.create(named: newName, busy: busy) }
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text("原列表中的事项会保留。已有记录的来源可能因新列表缺少原事项而停止导入；遇到提示时请恢复原列表。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if busy { Text("同步进行中，完成或暂停后才能更改列表。").foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .disabled(model.loading || busy)
        .onChange(of: model.currentID) { _, next in selectedID = next ?? "" }
        .onChange(of: model.lists) { _, lists in
            if !lists.contains(where: { $0.id == selectedID }) { selectedID = "" }
        }
    }
}
