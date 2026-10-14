import Foundation

// These bytes are part of version 1 cryptographic transcripts and key derivation.
enum ProtocolDomains {
    static let namespace = "com.gotdone.sync"
    static let appID = Data("com.gotdone.relay.poc".utf8)
}
