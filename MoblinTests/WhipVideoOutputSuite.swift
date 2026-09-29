@testable import Moblin
import Testing

struct WhipVideoOutputSuite {
    @Test
    func bitrateUsesMeasuredBytesAndElapsedTime() {
        var output = WhipVideoOutput()
        #expect(output.sample(now: 0) == nil)
        output.start(now: 1_000_000_000)
        output.add(bytes: 125_000)
        #expect(output.sample(now: 1_100_000_000) == nil)
        #expect(output.sample(now: 3_000_000_000) == 500_000)
        output.add(bytes: 62500)
        #expect(output.sample(now: 3_100_000_000) == 500_000)
        #expect(output.sample(now: 3_500_000_000) == 1_000_000)
    }

    @Test
    func idleIntervalIsMeasuredZeroAndRestartClearsHistory() {
        var output = WhipVideoOutput()
        output.start(now: 0)
        output.add(bytes: 625_000)
        #expect(output.sample(now: 1_000_000_000) == 5_000_000)
        #expect(output.sample(now: 2_000_000_000) == 0)
        output.start(now: 3_000_000_000)
        #expect(output.sample(now: 3_000_000_000) == nil)
        output.add(bytes: 31250)
        #expect(output.sample(now: 4_000_000_000) == 250_000)
    }

    @Test
    func repeatedOrEarlierReadsDoNotConsumeBytes() {
        var output = WhipVideoOutput()
        output.start(now: 2_000_000_000)
        output.add(bytes: 125_000)
        #expect(output.sample(now: 1_000_000_000) == nil)
        #expect(output.sample(now: 2_000_000_000) == nil)
        #expect(output.sample(now: 3_000_000_000) == 1_000_000)
        #expect(output.sample(now: 3_000_000_000) == 1_000_000)
    }
}
