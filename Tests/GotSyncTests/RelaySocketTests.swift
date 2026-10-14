import XCTest
@testable import GotSync

final class RelaySocketTests: XCTestCase {
    func testRegistrationIsCanonicalAndOpaque() throws {
        let route = Data(0..<32)
        let registration = try RelaySocket.registrationText(route: route)

        XCTAssertEqual(
            registration,
            #"{"route":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","type":"register","version":1}"#
        )
    }

    func testControlParsing() throws {
        let ready = try RelaySocket.parseControl(
            #"{"extra":true,"type":"peerReady","version":1}"#
        )
        let left = try RelaySocket.parseControl(
            #"{"type":"peerLeft","version":1}"#
        )
        let error = try RelaySocket.parseControl(
            #"{"code":"routeFull","type":"error","version":1}"#
        )

        XCTAssertEqual(ready, .peerReady)
        XCTAssertEqual(left, .peerLeft)
        XCTAssertEqual(error, .error("routeFull"))
    }

    func testMalformedControlsAreRejected() {
        do {
            _ = try RelaySocket.parseControl(#"{"type":"peerReady","version":2}"#)
            XCTFail("Expected an invalid control error.")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .invalidControl)
        }

        do {
            _ = try RelaySocket.parseControl(#"{"type":"unknown","version":1}"#)
            XCTFail("Expected an unsupported control error.")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .unexpectedControl)
        }
    }
}
