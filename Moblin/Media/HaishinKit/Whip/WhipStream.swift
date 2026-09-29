@preconcurrency import AVFoundation
import WagaWebRTC

private let whipQueue = DispatchQueue(label: "com.eerimoq.Moblin.whip")

private final class WhipPublisherDelegate: WagaPublisherDelegate {
    enum Event: Sendable {
        case connected, disconnected, keyframe
        case bitrate(UInt64)
        case diagnostic(String)
        case failed(String)
    }

    let handle: @Sendable (Event) -> Void

    init(handle: @escaping @Sendable (Event) -> Void) {
        self.handle = handle
    }

    func wagaPublisherConnected() {
        handle(.connected)
    }

    func wagaPublisherDisconnected() {
        handle(.disconnected)
    }

    func wagaPublisherNeedsKeyframe() {
        handle(.keyframe)
    }

    func wagaPublisherBitrateEstimate(_ bitrate: UInt64) {
        handle(.bitrate(bitrate))
    }

    func wagaPublisherDiagnostic(_ message: String) {
        handle(.diagnostic(message))
    }

    func wagaPublisherFailed(_ message: String) {
        handle(.failed(message))
    }
}

private func makeEndpointUrl(url: String) -> URL? {
    guard var components = URLComponents(string: url) else {
        return nil
    }
    components.scheme = components.scheme?.replacing("whip", with: "http")
    return components.url
}

struct WhipNalUnits {
    private var parameterSets = Data()

    mutating func setParameterSets(_ units: [Data?]) {
        parameterSets = Data()
        for case let unit? in units {
            var length = UInt32(unit.count).bigEndian
            parameterSets.append(Data(bytes: &length, count: 4))
            parameterSets.append(unit)
        }
    }

    func process(_ sampleData: Data, isSync: Bool) -> Data? {
        guard !sampleData.isEmpty else {
            return nil
        }
        return isSync ? parameterSets + sampleData : sampleData
    }
}

protocol WhipStreamDelegate: AnyObject {
    func whipStreamOnConnected()
    func whipStreamOnDisconnected(reason: String)
    func whipStreamPerform(request: URLRequest,
                           queue: DispatchQueue,
                           completion: (@MainActor (Data?, URLResponse?, (any Error)?) -> Void)?)
    func whipStreamStartEncoding(_ delegate: any AudioEncoderDelegate & VideoEncoderDelegate)
    func whipStreamStopEncoding(_ delegate: any AudioEncoderDelegate & VideoEncoderDelegate)
    func whipStreamSetVideoBitrate(_ bitrate: UInt32)
}

struct WhipAdaptiveBitrateSettings: Sendable {
    let minimumBitrate: UInt64
    let networkUtilization: UInt64
    let bitrateIncreaseStep: UInt64
}

final class WhipStream: @unchecked Sendable {
    private weak var delegate: (any WhipStreamDelegate)?
    private var publisher: WagaPublisher?
    private var publisherDelegate: WhipPublisherDelegate?
    private var generation = UUID()
    private weak var videoEncoder: VideoEncoder?
    private var nalUnits = WhipNalUnits()
    private var videoCodec: SettingsStreamCodec = .h264avc
    private var audioCodec: WagaCodec = .opus
    private var adaptiveBitrate = true
    private var adaptiveBitrateSettings = WhipAdaptiveBitrateSettings(
        minimumBitrate: 250_000,
        networkUtilization: 85,
        bitrateIncreaseStep: 250_000
    )
    private var targetVideoBitrate: UInt64 = 1_000_000
    private var currentVideoBitrate: UInt64 = 1_000_000
    private var bitrateRamp = WagaBitrateRamp()
    private var totalByteCount: Int64 = 0
    private var videoOutput = WhipVideoOutput()
    private var session: WhipSession?
    private var endpointUrl: URL?
    private var headers: [SettingsHttpHeader] = []
    private var connected = false
    private var offerSent = false
    private var timeStampRebaser = TimeStampRebaser()
    private var nextAudioMediaTime: UInt64?
    private let connectTimer = SimpleTimer(queue: whipQueue)

    init(delegate: any WhipStreamDelegate) {
        self.delegate = delegate
    }

    func start(url: String,
               headers: [SettingsHttpHeader],
               iceServers: [String],
               bonding: Bool,
               connectionPriorities: WagaConnectionPriorities,
               adaptiveBitrate: Bool,
               adaptiveBitrateSettings: WhipAdaptiveBitrateSettings,
               videoCodec: SettingsStreamCodec,
               audioCodec: SettingsStreamAudioCodec,
               videoBitrate: Double)
    {
        whipQueue.async {
            self.startInternal(url: url,
                               headers: headers,
                               iceServers: iceServers,
                               bonding: bonding,
                               connectionPriorities: connectionPriorities,
                               adaptiveBitrate: adaptiveBitrate,
                               adaptiveBitrateSettings: adaptiveBitrateSettings,
                               videoCodec: videoCodec,
                               audioCodec: audioCodec,
                               videoBitrate: videoBitrate)
        }
    }

    func stop() {
        whipQueue.async {
            self.stopInternal()
        }
    }

    func getTotalByteCount() -> Int64 {
        whipQueue.sync {
            totalByteCount
        }
    }

    func getVideoPacketLoss() -> Double? {
        whipQueue.sync {
            connected ? publisher?.videoPacketLoss() : nil
        }
    }

    func getVideoBitrate() -> UInt32 {
        whipQueue.sync {
            UInt32(clamping: currentVideoBitrate)
        }
    }

    func getVideoOutputBitrate() -> Int64? {
        whipQueue.sync {
            connected ? videoOutput.sample(now: DispatchTime.now().uptimeNanoseconds) : nil
        }
    }

    func updateAdaptiveBitrate() {
        whipQueue.async {
            self.applyBitrateEstimate()
        }
    }

    func setTargetVideoBitrate(_ bitrate: UInt32) {
        whipQueue.async {
            self.targetVideoBitrate = max(100_000, UInt64(bitrate))
            if !self.adaptiveBitrate || self.currentVideoBitrate > self.targetVideoBitrate {
                self.currentVideoBitrate = self.targetVideoBitrate
                self.delegate?.whipStreamSetVideoBitrate(UInt32(clamping: self.currentVideoBitrate))
            }
            if self.adaptiveBitrate {
                self.publisher?.setTargetBitrate(self.transportTargetBitrate())
            }
        }
    }

    private func startInternal(url: String,
                               headers: [SettingsHttpHeader],
                               iceServers: [String],
                               bonding: Bool,
                               connectionPriorities: WagaConnectionPriorities,
                               adaptiveBitrate: Bool,
                               adaptiveBitrateSettings: WhipAdaptiveBitrateSettings,
                               videoCodec: SettingsStreamCodec,
                               audioCodec: SettingsStreamAudioCodec,
                               videoBitrate: Double)
    {
        stopInternal()
        guard let endpointUrl = makeEndpointUrl(url: url) else {
            return
        }
        self.endpointUrl = endpointUrl
        self.headers = headers
        self.videoCodec = videoCodec
        self.adaptiveBitrate = adaptiveBitrate
        self.adaptiveBitrateSettings = adaptiveBitrateSettings
        targetVideoBitrate = UInt64(max(100_000, videoBitrate))
        currentVideoBitrate = targetVideoBitrate
        bitrateRamp = WagaBitrateRamp()
        nextAudioMediaTime = nil
        delegate?.whipStreamSetVideoBitrate(UInt32(clamping: currentVideoBitrate))
        totalByteCount = 0
        logger.info("""
        whip: Start (bonding: \(bonding), adaptive bitrate: \(adaptiveBitrate), \
        target: \(targetVideoBitrate) bps)
        """)
        nalUnits = WhipNalUnits()
        self.audioCodec = audioCodec == .aac ? .aac : .opus
        do {
            let generation = generation
            let publisherDelegate = WhipPublisherDelegate { [weak self] event in
                whipQueue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    handlePublisherEvent(event)
                }
            }
            self.publisherDelegate = publisherDelegate
            let codec: WagaCodec = switch videoCodec {
            case .h264avc: .h264
            case .h265hevc: .h265
            }
            let publisher = try WagaPublisher(
                audio: self.audioCodec,
                video: codec,
                mode: bonding ? .bonded : .standard,
                iceServers: iceServers,
                connectionPriorities: connectionPriorities,
                targetBitrate: adaptiveBitrate ? transportTargetBitrate() : nil,
                diagnostics: logger.debugEnabled,
                videoPacketLossStats: true,
                delegate: publisherDelegate
            )
            self.publisher = publisher
            publisher.createOffer { [weak self] result in
                guard let self else {
                    return
                }
                whipQueue.async {
                    guard self.generation == generation else { return }
                    switch result {
                    case let .success(offer):
                        self.sendOffer(offer: offer)
                    case let .failure(error):
                        self.stopInternal(reason: "Failed to create offer: \(error)")
                    }
                }
            }
            connectTimer.startSingleShot(timeout: 10) { [weak self] in
                guard self?.generation == generation else { return }
                self?.stopInternal(reason: "Connect timeout")
            }
        } catch {
            stopInternal(reason: "Start failed: \(error)")
        }
    }

    private func stopInternal(reason: String? = nil) {
        if let reason {
            logger.info("whip: Stopped: \(reason)")
        } else if publisher != nil {
            logger.debug("whip: Stopped")
        }
        generation = UUID()
        videoEncoder = nil
        stopEncoding()
        if let session {
            sendDeleteRequest(session: session)
        }
        session = nil
        videoOutput = WhipVideoOutput()
        endpointUrl = nil
        publisher?.delegate = nil
        publisher?.stop()
        publisher = nil
        publisherDelegate = nil
        connected = false
        offerSent = false
        connectTimer.stop()
        if let reason {
            delegate?.whipStreamOnDisconnected(reason: reason)
        }
    }

    private func sendOffer(offer: String) {
        guard !offerSent, let endpointUrl else {
            return
        }
        logger.debug("whip: Sending offer")
        let headers = headers
        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setContentType("application/sdp")
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = offer.utf8Data
        let generation = generation
        delegate?.whipStreamPerform(request: request, queue: whipQueue) { [weak self] data, response, error in
            whipQueue.async { [weak self] in
                guard let self else { return }
                guard self.generation == generation else {
                    if let response = response?.http, response.isSuccessful,
                       let session = WhipSession(
                           response: response,
                           endpointUrl: endpointUrl,
                           headers: headers
                       )
                    {
                        sendDeleteRequest(session: session)
                    }
                    return
                }
                handleOfferResponse(data: data, response: response, error: error,
                                    endpointUrl: endpointUrl, headers: headers)
            }
        }
        offerSent = true
    }

    private func handleOfferResponse(data: Data?, response: URLResponse?, error: (any Error)?,
                                     endpointUrl: URL, headers: [SettingsHttpHeader])
    {
        if let error {
            stopInternal(reason: "Sending WHIP offer failed: \(error.localizedDescription)")
            return
        }
        guard let response = response?.http else {
            stopInternal(reason: "Bad WHIP server response")
            return
        }
        guard response.isSuccessful else {
            stopInternal(reason: "WHIP server returned HTTP status \(response.statusCode)")
            return
        }
        session = WhipSession(response: response, endpointUrl: endpointUrl, headers: headers)
        guard let data, let answer = String(data: data, encoding: .utf8) else {
            stopInternal(reason: "WHIP answer missing")
            return
        }
        logger.debug("whip: Got answer")
        publisher?.acceptAnswer(answer)
    }

    private func sendDeleteRequest(session: WhipSession) {
        delegate?.whipStreamPerform(request: session.deleteRequest(), queue: whipQueue, completion: nil)
    }

    private func startEncoding() {
        processorControlQueue.async {
            self.delegate?.whipStreamStartEncoding(self)
        }
    }

    private func stopEncoding() {
        processorControlQueue.async {
            self.delegate?.whipStreamStopEncoding(self)
        }
    }

    private func transportTargetBitrate() -> UInt64 {
        ((targetVideoBitrate + 160_000) * 100) / adaptiveBitrateSettings.networkUtilization
    }

    private func handleBitrateEstimate(_ estimate: UInt64) {
        guard adaptiveBitrate else {
            return
        }
        let usable = estimate * adaptiveBitrateSettings.networkUtilization / 100
        let videoBitrate = min(
            targetVideoBitrate,
            max(adaptiveBitrateSettings.minimumBitrate,
                usable > 160_000 ? usable - 160_000 : adaptiveBitrateSettings.minimumBitrate)
        )
        bitrateRamp.observe(ceiling: videoBitrate, now: DispatchTime.now().uptimeNanoseconds)
        applyBitrateEstimate()
    }

    private func applyBitrateEstimate() {
        guard connected, adaptiveBitrate,
              let nextBitrate = bitrateRamp.next(current: currentVideoBitrate,
                                                 target: targetVideoBitrate,
                                                 maximumIncrease: adaptiveBitrateSettings.bitrateIncreaseStep,
                                                 now: DispatchTime.now().uptimeNanoseconds)
        else {
            return
        }
        let wasLimited = currentVideoBitrate < targetVideoBitrate * 95 / 100
        let isLimited = nextBitrate < targetVideoBitrate * 95 / 100
        if wasLimited != isLimited {
            logger.debug("whip: adaptive bitrate \(isLimited ? "reduced" : "recovered"): \(nextBitrate) bps")
        }
        currentVideoBitrate = nextBitrate
        delegate?.whipStreamSetVideoBitrate(UInt32(clamping: nextBitrate))
    }

    private func handleAudioEncoderOutputBuffer(_ buffer: AVAudioCompressedBuffer,
                                                _ presentationTimeStamp: CMTime)
    {
        guard connected, let publisher else {
            return
        }
        guard let presentationTimeStamp = timeStampRebaser.rebase(presentationTimeStamp.seconds) else {
            return
        }
        guard buffer.byteLength > 0 else {
            return
        }
        let mediaTime = nextAudioMediaTime ?? UInt64(max(0, presentationTimeStamp * 48000))
        let framesPerPacket: UInt64 = audioCodec == .aac ? 1024 : 960
        let allData = Data(bytes: buffer.data, count: Int(buffer.byteLength))
        guard buffer.packetCount > 0, let descriptions = buffer.packetDescriptions else {
            publisher.send(codec: audioCodec, mediaTime: mediaTime, data: allData)
            totalByteCount += Int64(allData.count)
            nextAudioMediaTime = mediaTime + framesPerPacket
            return
        }
        var packetMediaTime = mediaTime
        for index in 0 ..< Int(buffer.packetCount) {
            let description = descriptions[index]
            let offset = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)
            guard size > 0, offset >= 0, offset + size <= allData.count else {
                continue
            }
            let packet = allData.subdata(in: offset ..< offset + size)
            publisher.send(codec: audioCodec, mediaTime: packetMediaTime, data: packet)
            totalByteCount += Int64(packet.count)
            packetMediaTime += UInt64(description.mVariableFramesInPacket == 0
                ? UInt32(framesPerPacket)
                : description.mVariableFramesInPacket)
        }
        nextAudioMediaTime = packetMediaTime
    }

    private func handleVideoEncoderOutputFormat(_ formatDescription: CMFormatDescription) {
        switch videoCodec {
        case .h264avc:
            guard let config = MpegTsVideoConfigAvc(formatDescription: formatDescription) else {
                return
            }
            nalUnits.setParameterSets([config.sequenceParameterSet, config.pictureParameterSet])
        case .h265hevc:
            guard let config = MpegTsVideoConfigHevc(formatDescription: formatDescription) else {
                return
            }
            nalUnits.setParameterSets([config.videoParameterSet,
                                       config.sequenceParameterSet,
                                       config.pictureParameterSet])
        }
    }

    private func handleVideoEncoderOutputSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard connected, let publisher else {
            return
        }
        guard let presentationTimeStamp = timeStampRebaser.rebase(sampleBuffer.presentationTimeStamp.seconds)
        else {
            return
        }
        guard let (buffer, length) = sampleBuffer.dataBuffer?.getDataPointer(),
              let data = nalUnits.process(
                  Data(bytes: buffer, count: length),
                  isSync: sampleBuffer.getIsSync()
              )
        else {
            return
        }
        publisher.send(
            codec: videoCodec == .h264avc ? .h264 : .h265,
            mediaTime: UInt64(max(0, presentationTimeStamp * 90000)),
            data: data
        )
        totalByteCount += Int64(data.count)
        videoOutput.add(bytes: data.count)
    }
}

private extension WhipStream {
    func handlePublisherEvent(_ event: WhipPublisherDelegate.Event) {
        switch event {
        case .connected:
            guard !connected else {
                return
            }
            connectTimer.stop()
            connected = true
            videoOutput.start(now: DispatchTime.now().uptimeNanoseconds)
            logger.info("whip: Connected")
            startEncoding()
            delegate?.whipStreamOnConnected()
        case .disconnected:
            stopInternal(reason: "Connection disconnected")
        case .keyframe:
            if connected {
                videoEncoder?.requestKeyframe()
            }
        case let .bitrate(bitrate):
            handleBitrateEstimate(bitrate)
        case let .diagnostic(message):
            logger.debug("whip: \(message)")
        case let .failed(message):
            stopInternal(reason: message)
        }
    }
}

extension WhipStream: AudioEncoderDelegate {
    func audioEncoderOutputFormat(_: AVAudioFormat) {}

    func audioEncoderOutputBuffer(_ buffer: AVAudioCompressedBuffer, _ presentationTimeStamp: CMTime) {
        whipQueue.async {
            self.handleAudioEncoderOutputBuffer(buffer, presentationTimeStamp)
        }
    }
}

extension WhipStream: VideoEncoderDelegate {
    func videoEncoderOutputFormat(_ encoder: VideoEncoder, _ formatDescription: CMFormatDescription) {
        whipQueue.async {
            self.videoEncoder = encoder
            self.handleVideoEncoderOutputFormat(formatDescription)
        }
    }

    func videoEncoderOutputSampleBuffer(_ encoder: VideoEncoder,
                                        _ sampleBuffer: CMSampleBuffer,
                                        _: CMTime)
    {
        whipQueue.async {
            self.videoEncoder = encoder
            self.handleVideoEncoderOutputSampleBuffer(sampleBuffer)
        }
    }
}
