import Foundation
@testable import Moblin
import Testing
import WagaWebRTC

struct WhipPacketLossSuite {
    @Test
    func publisherWithoutReceiverFeedbackIsUnavailable() throws {
        for enabled in [false, true] {
            let publisher = try WagaPublisher(videoPacketLossStats: enabled)
            #expect(publisher.videoPacketLoss() == nil)
            publisher.stop()
            #expect(publisher.videoPacketLoss() == nil)
        }
    }

    @Test
    func unavailableFeedbackNeverLooksLikeZeroLoss() {
        let unavailable = String(localized: "Video packet loss: unavailable")
        let values: [Double?] = [nil, .nan, .infinity, -0.01, 1.01]
        for value in values {
            #expect(whipPacketLossText(value) == unavailable)
        }
        #expect(whipPacketLossText(0) != unavailable)
    }

    @Test
    func smallMeasuredLossNeverRoundsToZero() {
        let percent = "<0.1%"
        #expect(whipPacketLossText(0.0001) == String(localized: "Video packet loss: \(percent)"))
    }

    @Test
    func receiverFractionIsDisplayedAsAPercentage() {
        let percent = String(format: "%.1f%%", 12.5)
        #expect(whipPacketLossText(0.125) == String(localized: "Video packet loss: \(percent)"))
    }
}
