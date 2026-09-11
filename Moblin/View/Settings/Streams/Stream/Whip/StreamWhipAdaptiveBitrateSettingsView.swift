import SwiftUI

struct StreamWhipAdaptiveBitrateSettingsView: View {
    let model: Model
    let stream: SettingsStream
    @ObservedObject var adaptiveBitrate: SettingsStreamWhipAdaptiveBitrate

    private func submitMinimumBitrate(value: Float) {
        adaptiveBitrate.minimumBitrate = UInt32(value)
    }

    private func submitNetworkUtilization(value: Float) {
        adaptiveBitrate.networkUtilization = UInt32(value)
    }

    private func submitBitrateIncreaseStep(value: Float) {
        adaptiveBitrate.bitrateIncreaseStep = UInt32(value)
    }

    private func formatBitrate(value: Float) -> String {
        formatBytesPerSecond(speed: Int64(value))
    }

    private func formatNetworkUtilization(value: Float) -> String {
        "\(Int(value))%"
    }

    var body: some View {
        Form {
            Section {
                SliderView(
                    value: Float(adaptiveBitrate.minimumBitrate),
                    minimum: 100_000,
                    maximum: 2_000_000,
                    step: 50000,
                    onSubmit: submitMinimumBitrate,
                    width: 100,
                    format: formatBitrate
                )
                .disabled(stream.enabled && model.isLive)
            } header: {
                Text("Minimum bitrate")
            } footer: {
                Text("The lowest video bitrate WHIP may use when the connection becomes weak.")
            }
            Section {
                SliderView(
                    value: Float(adaptiveBitrate.networkUtilization),
                    minimum: 50,
                    maximum: 100,
                    step: 1,
                    onSubmit: submitNetworkUtilization,
                    width: 80,
                    format: formatNetworkUtilization
                )
                .disabled(stream.enabled && model.isLive)
            } header: {
                Text("Network utilization")
            } footer: {
                Text("How much of the receiver's estimated bandwidth WHIP may use. 85% by default.")
            }
            Section {
                SliderView(
                    value: Float(adaptiveBitrate.bitrateIncreaseStep),
                    minimum: 50000,
                    maximum: 1_000_000,
                    step: 50000,
                    onSubmit: submitBitrateIncreaseStep,
                    width: 100,
                    format: formatBitrate
                )
                .disabled(stream.enabled && model.isLive)
            } header: {
                Text("Bitrate recovery step")
            } footer: {
                Text("How quickly WHIP returns to the selected target bitrate after bandwidth recovers.")
            }
        }
        .navigationTitle("Adaptive bitrate")
    }
}
