import SwiftUI

struct StreamWhipSettingsView: View {
    let model: Model
    @ObservedObject var stream: SettingsStream
    @ObservedObject var whip: SettingsStreamWhip

    private func getBearerToken() -> String {
        guard let authorization = whip.headers.first(where: { $0.name == "Authorization" }) else {
            return ""
        }
        guard let match = authorization.value.prefixMatch(of: /Bearer (.*)/) else {
            return ""
        }
        return String(match.output.1)
    }

    private func setBearerToken(token: String) {
        let value = "Bearer \(token)"
        if let index = whip.headers.firstIndex(where: { $0.name == "Authorization" }) {
            whip.headers[index].value = value
        } else {
            whip.headers.append(SettingsHttpHeader(name: "Authorization", value: value))
        }
        model.reloadStreamIfEnabled(stream: stream)
    }

    var body: some View {
        Form {
            Section {
                TextEditNavigationView(title: String(localized: "Bearer token"),
                                       value: getBearerToken(),
                                       onSubmit: setBearerToken,
                                       sensitive: true)
                    .disabled(stream.enabled && model.isLive)
            }
            Section {
                Picker("Target bitrate", selection: $stream.bitrate) {
                    ForEach(model.database.bitratePresets) { preset in
                        Text(formatBytesPerSecond(speed: Int64(preset.bitrate)))
                            .tag(preset.bitrate)
                    }
                }
                .onChange(of: stream.bitrate) { _ in
                    if stream.enabled {
                        model.setStreamBitrate(stream: stream)
                    }
                }
                NavigationLink {
                    StreamWhipAdaptiveBitrateSettingsView(
                        model: model,
                        stream: stream,
                        adaptiveBitrate: whip.adaptiveBitrate
                    )
                } label: {
                    Toggle("Adaptive bitrate", isOn: $whip.adaptiveBitrateEnabled)
                        .disabled(stream.enabled && model.isLive)
                        .onChange(of: whip.adaptiveBitrateEnabled) { _ in
                            model.reloadStreamIfEnabled(stream: stream)
                        }
                }
            } header: {
                Text("Bitrate")
            } footer: {
                Text("WHIP starts at the target bitrate and returns to it whenever the connection allows.")
            }
            Section {
                Toggle(isOn: $whip.bonding) {
                    VStack(alignment: .leading) {
                        Text("WHIP bonding")
                        Text("Experimental")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(stream.enabled && model.isLive)
                .onChange(of: whip.bonding) { _ in
                    model.reloadStreamIfEnabled(stream: stream)
                }
                NavigationLink {
                    StreamWhipConnectionPrioritiesSettingsView(
                        model: model,
                        stream: stream,
                        priorities: whip.connectionPriorities
                    )
                } label: {
                    Text("Connection priorities")
                }
                .disabled(!whip.bonding)
            } footer: {
                Text("""
                Use Wi-Fi, cellular, and Ethernet together with a compatible receiver such as WagaStrim. \
                Turn bonding off for standard WHIP services.
                """)
            }
            Section {
                NavigationLink {
                    advancedSettings
                } label: {
                    Text("Advanced")
                }
            }
        }
        .navigationTitle("WHIP")
    }

    private var advancedSettings: some View {
        Form {
            Section {
                Picker("Audio codec", selection: $stream.audioCodec) {
                    Text("Opus").tag(SettingsStreamAudioCodec.opus)
                    Text("AAC (experimental)").tag(SettingsStreamAudioCodec.aac)
                }
                .disabled(stream.enabled && model.isLive)
                .onChange(of: stream.audioCodec) { _ in
                    model.reloadStreamIfEnabled(stream: stream)
                }
            } footer: {
                Text("""
                AAC tests use 48 kHz stereo and require an AAC-capable WHIP receiver. \
                Use Opus for the WagaStrim dashboard preview.
                """)
            }
            Section {
                Picker(selection: $whip.httpTransport) {
                    ForEach(SettingsStreamWhipHttpTransport.allCases, id: \.self) {
                        Text($0.toString())
                    }
                } label: {
                    Text("HTTP transport")
                }
                .disabled(stream.enabled && model.isLive)
                .onChange(of: whip.httpTransport) { _ in
                    model.reloadStreamIfEnabled(stream: stream)
                }
            } footer: {
                VStack(alignment: .leading) {
                    Text("""
                    Select \(SettingsStreamWhipHttpTransport.standard.toString()) to use \
                    standard WHIP.
                    """)
                    Text("")
                    Text("""
                    Select \(SettingsStreamWhipHttpTransport.remoteControl.toString()) to exchange \
                    connection establishment information via the remote control. Configure this device \
                    as remote control assistant, and the device you are streaming to as remote control \
                    streamer.
                    """)
                }
            }
            if whip.httpTransport == .remoteControl {
                ShortcutSectionView {
                    RemoteControlAssistantShortcutView(model: model)
                }
            }
        }
        .navigationTitle("Advanced")
    }
}
