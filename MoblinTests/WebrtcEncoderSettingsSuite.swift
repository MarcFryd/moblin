import AVFAudio
import Foundation
@testable import Moblin
import Testing

struct WebrtcEncoderSettingsSuite {
    @Test
    func audioFormatsKeepWebrtcOverridesSeparate() throws {
        var source = AudioStreamBasicDescription()
        source.mSampleRate = 24000
        source.mChannelsPerFrame = 1
        for format in [AudioEncoderSettings.Format.aac, .opus] {
            let output = try #require(format.makeAudioFormat(source))
            #expect(output.sampleRate == 24000)
            #expect(output.channelCount == 1)
        }
        let opus = try #require(AudioEncoderSettings.Format.opusWhip.makeAudioFormat(source))
        #expect(opus.sampleRate == 48000)
        #expect(opus.channelCount == 1)
        let aac = try #require(AudioEncoderSettings.Format.aacWhip.makeAudioFormat(source))
        #expect(aac.sampleRate == 48000)
        #expect(aac.channelCount == 2)
    }

    @Test
    func bitrateRetriesAreOptIn() {
        #expect(!VideoEncoderSettings().retryBitrateUpdates)
    }

    @Test
    func whipParameterSetsPreserveCodecOrderAndFrameBytes() {
        var units = WhipNalUnits()
        let frame = Data([0, 0, 0, 2, 0x65, 0x88])
        units.setParameterSets([Data([0x67, 0x64]), Data([0x68])])
        #expect(units.process(frame, isSync: true) == Data([0, 0, 0, 2, 0x67, 0x64,
                                                            0, 0, 0, 1, 0x68]) + frame)
        #expect(units.process(frame, isSync: false) == frame)
        units.setParameterSets([Data([0x40]), Data([0x42]), Data([0x44])])
        #expect(units.process(frame, isSync: true) == Data([0, 0, 0, 1, 0x40,
                                                            0, 0, 0, 1, 0x42,
                                                            0, 0, 0, 1, 0x44]) + frame)
    }

    @Test
    func whipParameterSetReplacementClearsOldHeadersAndSkipsAbsentSets() {
        var units = WhipNalUnits()
        let frame = Data([0, 0, 0, 1, 0x65])
        #expect(units.process(frame, isSync: true) == frame)
        units.setParameterSets([Data([0x40]), Data([0x42]), Data([0x44])])
        let sps = Data(repeating: 0x67, count: 260)
        units.setParameterSets([sps, nil])
        #expect(units.process(frame, isSync: true) == Data([0, 0, 1, 4]) + sps + frame)
        #expect(units.process(Data(), isSync: true) == nil)
        units.setParameterSets([])
        #expect(units.process(frame, isSync: true) == frame)
    }
}
