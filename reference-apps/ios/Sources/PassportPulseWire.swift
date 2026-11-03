import Foundation
import KenshikiPulsePassport

// No product HTTP or assertion-byte algorithms are implemented in the app.
typealias PulseAppAttestAssertion = KenshikiPulsePassport.PulseAppAttestAssertion
typealias PulseNativeAttestation = KenshikiPulsePassport.PulseNativeAttestation
typealias PulseBoundedHTTPResponse = KenshikiPulsePassport.PulseBoundedHTTPResponse
typealias PulseBoundedHTTPTransport = KenshikiPulsePassport.PulseBoundedHTTPTransport
typealias PulseBoundedHTTPTransportError = KenshikiPulsePassport.PulseBoundedHTTPTransportError
typealias URLSessionPulseBoundedHTTPTransport = KenshikiPulsePassport.URLSessionPulseBoundedHTTPTransport

enum PassportServerClock {
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
