import SwiftUI

struct StreamWhipConnectionPrioritiesSettingsView: View {
    let model: Model
    let stream: SettingsStream
    @ObservedObject var priorities: SettingsStreamWhipConnectionPriorities

    private func slider(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }
                ),
                in: 1 ... 10,
                step: 1
            )
            Text("\(value.wrappedValue)")
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
        }
        .disabled(stream.enabled && model.isLive)
    }

    var body: some View {
        Form {
            Section {
                slider("Wi-Fi", value: $priorities.wifi)
                slider("Cellular", value: $priorities.cellular)
                slider("Ethernet", value: $priorities.wiredEthernet)
            } footer: {
                Text("""
                Higher-priority connections carry more traffic when they are healthy. \
                Changes apply the next time WHIP connects.
                """)
            }
        }
        .navigationTitle("Connection priorities")
    }
}
