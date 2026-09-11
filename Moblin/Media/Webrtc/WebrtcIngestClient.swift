import AVFoundation
import CoreMedia
import WagaWebRTC

protocol WebrtcIngestClientDelegate: AnyObject {
    func webrtcIngestClientOnConnected(streamId: UUID)
    func webrtcIngestClientOnDisconnected(streamId: UUID, reason: String)
    func webrtcIngestClientOnVideoBuffer(streamId: UUID, _ sampleBuffer: CMSampleBuffer)
    func webrtcIngestClientOnAudioBuffer(streamId: UUID, _ sampleBuffer: CMSampleBuffer)
    func webrtcIngestClientSetTargetLatencies(
        streamId: UUID,
        _ videoTargetLatency: Double,
        _ audioTargetLatency: Double
    )
    func webrtcIngestClientOnGatheringComplete(streamId: UUID, localDescription: String)
    func webrtcIngestClientOnDataReceived(streamId: UUID, count: Int)
}

private enum VideoCodec {
    case h264
    case h265
}

private class TrackTimestamper {
    private let syncTimestamps: Bool

    init(syncTimestamps: Bool) {
        self.syncTimestamps = syncTimestamps
    }

    func timestampSeconds(_ frame: WagaMediaFrame) -> Double? {
        guard frame.clockRate > 0 else {
            return nil
        }
        let clockRate = Double(frame.clockRate)
        let timestampSeconds = Double(frame.mediaTime) / clockRate
        guard syncTimestamps else {
            return timestampSeconds
        }
        guard let ntpMicroseconds = frame.ntpMicroseconds else {
            return nil
        }
        let delta: Double = if frame.mediaTime >= frame.senderMediaTime {
            Double(frame.mediaTime - frame.senderMediaTime) / clockRate
        } else {
            -Double(frame.senderMediaTime - frame.mediaTime) / clockRate
        }
        return Double(ntpMicroseconds) / 1_000_000 + delta
    }
}

final class WebrtcIngestClient: @unchecked Sendable {
    private let name: String
    let streamId: UUID
    private let latency: Double
    private let softwareDecoding: Bool
    private let iceServers: [String]
    weak var delegate: (any WebrtcIngestClientDelegate)?
    private var receiver: WagaReceiver?
    private var connected = false
    private var videoDecoder: VideoDecoder?
    private var videoFormatDescription: CMFormatDescription?
    private var basePresentationTimeStamp: Double = -1
    private var timeStampRebaser = TimeStampRebaser()
    private var opusAudioConverter: AVAudioConverter?
    private var opusCompressedBuffer: AVAudioCompressedBuffer?
    private var pcmAudioFormat: AVAudioFormat?
    private var pcmAudioBuffer: AVAudioPCMBuffer?
    private var targetLatenciesSynchronizer: TargetLatenciesSynchronizer
    private var videoCodec: VideoCodec = .h264
    private let timestamper: TrackTimestamper
    private let dispatchQueue: DispatchQueue

    init(name: String,
         streamId: UUID,
         latency: Double,
         syncTimestamps: Bool,
         softwareDecoding: Bool,
         iceServers: [String],
         dispatchQueue: DispatchQueue,
         delegate: any WebrtcIngestClientDelegate)
    {
        self.name = name
        self.streamId = streamId
        self.latency = latency
        self.softwareDecoding = softwareDecoding
        self.iceServers = iceServers
        self.dispatchQueue = dispatchQueue
        targetLatenciesSynchronizer = TargetLatenciesSynchronizer(targetLatency: latency)
        timestamper = TrackTimestamper(syncTimestamps: syncTimestamps)
        self.delegate = delegate
    }

    func createOffer() throws {
        let receiver = try makeReceiver()
        receiver.createOffer { [weak self] result in self?.handleLocalDescription(result) }
    }

    func acceptOffer(_ sdp: String) throws {
        let receiver = try makeReceiver()
        receiver.acceptOffer(sdp) { [weak self] result in self?.handleLocalDescription(result) }
    }

    func acceptAnswer(_ sdp: String) {
        receiver?.acceptAnswer(sdp)
    }

    func stop() {
        stopInternal()
    }

    private func makeReceiver() throws -> WagaReceiver {
        receiver?.delegate = nil
        receiver?.stop()
        let receiver = try WagaReceiver(
            queue: dispatchQueue,
            iceServers: iceServers,
            delegate: self
        )
        self.receiver = receiver
        setupOpusDecoder()
        return receiver
    }

    private func handleLocalDescription(_ result: Result<String, Error>) {
        switch result {
        case let .success(description):
            delegate?.webrtcIngestClientOnGatheringComplete(
                streamId: streamId,
                localDescription: description
            )
        case let .failure(error):
            stopInternal(reason: "ICE gathering failed: \(error)")
        }
    }

    private func stopInternal(reason: String? = nil) {
        videoDecoder?.stopRunning()
        videoDecoder = nil
        opusAudioConverter = nil
        opusCompressedBuffer = nil
        pcmAudioBuffer = nil
        receiver?.delegate = nil
        receiver?.stop()
        receiver = nil
        connected = false
        if let reason {
            delegate?.webrtcIngestClientOnDisconnected(streamId: streamId, reason: reason)
        }
    }

    private func handleVideoMessage(_ frame: WagaMediaFrame) {
        let data = frame.data
        delegate?.webrtcIngestClientOnDataReceived(streamId: streamId, count: data.count)
        guard let timestampSeconds = timestamper.timestampSeconds(frame)
        else {
            return
        }
        var frameData = data
        let nalUnits = getNalUnits(data: frameData)
        let formatDescription: CMFormatDescription?
        switch videoCodec {
        case .h264:
            let units = readH264NalUnits(data: frameData,
                                         nalUnits: nalUnits,
                                         filter: [.sps, .pps, .idr])
            formatDescription = units.makeFormatDescription()
        case .h265:
            let units = readH265NalUnits(data: frameData,
                                         nalUnits: nalUnits,
                                         filter: [.sps, .pps, .vps])
            formatDescription = units.makeFormatDescription()
        }
        if let formatDescription, videoFormatDescription != formatDescription {
            videoFormatDescription = formatDescription
            videoDecoder?.stopRunning()
            videoDecoder = nil
        }
        guard let videoFormatDescription else {
            return
        }
        removeNalUnitStartCodes(&frameData, nalUnits)
        guard let rebasedTimeStamp = timeStampRebaser.rebase(timestampSeconds) else {
            return
        }
        let presentationTimeStamp = getBasePresentationTimeStamp() + rebasedTimeStamp
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: presentationTimeStamp),
            decodeTimeStamp: .invalid
        )
        let blockBuffer = frameData.makeBlockBuffer()
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = blockBuffer?.dataLength ?? 0
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoFormatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return
        }
        if videoDecoder == nil {
            videoDecoder = VideoDecoder(name: name,
                                        lockQueue: dispatchQueue,
                                        softwareDecoding: softwareDecoding)
            videoDecoder?.delegate = self
            videoDecoder?.startRunning(formatDescription: videoFormatDescription)
        }
        targetLatenciesSynchronizer.setLatestVideoPresentationTimeStamp(presentationTimeStamp)
        updateTargetLatencies()
        videoDecoder?.decodeSampleBuffer(sampleBuffer)
    }

    private func handleAudioMessage(_ frame: WagaMediaFrame) {
        let data = frame.data
        delegate?.webrtcIngestClientOnDataReceived(streamId: streamId, count: data.count)
        guard let timestampSeconds = timestamper.timestampSeconds(frame)
        else {
            return
        }
        guard !data.isEmpty else {
            return
        }
        guard let opusCompressedBuffer,
              let opusAudioConverter,
              let pcmAudioBuffer,
              pcmAudioFormat != nil
        else {
            return
        }
        let length = data.count
        guard length <= opusCompressedBuffer.maximumPacketSize else {
            return
        }
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            opusCompressedBuffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(length)
            )
            opusCompressedBuffer.packetCount = 1
            opusCompressedBuffer.byteLength = UInt32(length)
            opusCompressedBuffer.data.copyMemory(from: baseAddress, byteCount: length)
        }
        var error: NSError?
        opusAudioConverter.convert(to: pcmAudioBuffer, error: &error) { _, inputStatus in
            inputStatus.pointee = .haveData
            return self.opusCompressedBuffer
        }
        if let error {
            logger.info("webrtc-ingest-client: Opus decode error: \(error)")
            return
        }
        guard let rebasedTimeStamp = timeStampRebaser.rebase(timestampSeconds) else {
            return
        }
        let presentationTimeStamp = getBasePresentationTimeStamp() + rebasedTimeStamp
        let pts = CMTime(seconds: presentationTimeStamp)
        guard let sampleBuffer = pcmAudioBuffer.makeSampleBuffer(pts) else {
            return
        }
        targetLatenciesSynchronizer.setLatestAudioPresentationTimeStamp(presentationTimeStamp)
        updateTargetLatencies()
        delegate?.webrtcIngestClientOnAudioBuffer(streamId: streamId, sampleBuffer)
    }

    private func setupOpusDecoder() {
        var audioStreamBasicDescription = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &audioStreamBasicDescription) else {
            logger.info("webrtc-ingest-client: Failed to create Opus audio format")
            return
        }
        opusCompressedBuffer = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: 4096
        )
        pcmAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 2,
            interleaved: true
        )
        guard let pcmAudioFormat else {
            logger.info("webrtc-ingest-client: Failed to create PCM audio format")
            return
        }
        pcmAudioBuffer = AVAudioPCMBuffer(pcmFormat: pcmAudioFormat, frameCapacity: 960)
        opusAudioConverter = AVAudioConverter(from: opusFormat, to: pcmAudioFormat)
        if opusAudioConverter == nil {
            logger.info("webrtc-ingest-client: Failed to create Opus audio converter")
        }
    }

    private func getBasePresentationTimeStamp() -> Double {
        if basePresentationTimeStamp == -1 {
            basePresentationTimeStamp = currentPresentationTimeStamp().seconds + latency
        }
        return basePresentationTimeStamp
    }

    private func updateTargetLatencies() {
        guard let (audioTargetLatency, videoTargetLatency) = targetLatenciesSynchronizer.update() else {
            return
        }
        delegate?.webrtcIngestClientSetTargetLatencies(
            streamId: streamId,
            videoTargetLatency,
            audioTargetLatency
        )
    }
}

extension WebrtcIngestClient: WagaReceiverDelegate {
    func wagaReceiverConnected() {
        guard !connected else {
            return
        }
        connected = true
        delegate?.webrtcIngestClientOnConnected(streamId: streamId)
    }

    func wagaReceiverDisconnected() {
        stopInternal(reason: "Connection disconnected")
    }

    func wagaReceiverReceived(_ frame: WagaMediaFrame) {
        switch frame.codec {
        case .h264:
            videoCodec = .h264
            handleVideoMessage(frame)
        case .h265:
            videoCodec = .h265
            handleVideoMessage(frame)
        case .opus:
            handleAudioMessage(frame)
        case .aac:
            stopInternal(reason: "AAC receiving is not supported. Select Opus on the publisher.")
        case .none:
            break
        }
    }

    func wagaReceiverFailed(_ message: String) {
        stopInternal(reason: message)
    }
}

extension WebrtcIngestClient: VideoDecoderDelegate {
    func videoDecoderOutputSampleBuffer(_: VideoDecoder, _ sampleBuffer: CMSampleBuffer) {
        delegate?.webrtcIngestClientOnVideoBuffer(streamId: streamId, sampleBuffer)
    }
}
