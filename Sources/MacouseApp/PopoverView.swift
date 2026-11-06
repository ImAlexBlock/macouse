import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("鼠标加速（Windows 提高指针精确度）", isOn: $model.accelerationEnabled)
                .onChange(of: model.accelerationEnabled) { model.update() }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Windows 速度")
                    Spacer()
                    Text("\(model.speedPosition)/11 · \(formattedMultiplier)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: .init(get: { Double(model.speedPosition) },
                                    set: { model.speedPosition = Int($0.rounded()) }),
                       in: 1...11, step: 1)
                    .onChange(of: model.speedPosition) { model.update() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                if !model.detailText.isEmpty {
                    Text(model.detailText).foregroundStyle(.secondary)
                }
                if model.needsInputMonitoringPermission {
                    Button("打开输入监控设置") { model.openInputMonitoringSettings() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)

            Divider()

            HStack {
                Button("恢复系统默认") { model.restoreSystemDefault() }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var formattedMultiplier: String {
        String(format: "%.1f", model.multiplier)
    }
}
