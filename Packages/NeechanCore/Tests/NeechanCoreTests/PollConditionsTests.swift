import Foundation
import Testing
@testable import NeechanCore

@Suite("Poll conditions")
struct PollConditionsTests {
    @Test("Wi-Fi is always allowed")
    func onWiFi() {
        #expect(PollConditions(isExpensive: false, wifiOnly: true).allowsPolling)
        #expect(PollConditions(isExpensive: false, wifiOnly: false).allowsPolling)
    }

    @Test("cellular is allowed unless the reader asked for Wi-Fi only")
    func onCellular() {
        #expect(PollConditions(isExpensive: true, wifiOnly: false).allowsPolling)
        #expect(PollConditions(isExpensive: true, wifiOnly: true).allowsPolling == false)
    }

    /// A request with nowhere to go still wakes the radio looking for one, and
    /// the session waits for connectivity rather than failing, so offline ticks
    /// would otherwise pile up.
    @Test("nothing is polled while the device is offline")
    func offline() {
        #expect(PollConditions(isConnected: false).allowsPolling == false)
        #expect(PollConditions(isConnected: false, wifiOnly: false).allowsPolling == false)
    }

    @Test("low power does not stop polling, it only slows it")
    func lowPower() {
        #expect(PollConditions(isLowPower: true).allowsPolling)
    }
}
