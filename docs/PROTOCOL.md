# Sync protocol

This branch uses RFC 9420 MLS through Wire CoreCrypto 10.5.4. Read
[the integration contract](WIRE-CORECRYPTO.md) for pairing, delivery, durable
state, authorization and operating limits. One MLS conversation represents
one task-sync group. The cipher suite is X25519 / AES-128-GCM / SHA-256 /
Ed25519, selected through the SDK.

`MLSHeader` checks the RFC wire version, wire format, group ID, epoch and
content type before decryption. The driver rejects proposals, future buffering,
unknown decrypted message kinds, duplicate identities and duplicate signing
keys. Received commits require a previously admitted signing identity. A bad
Commit never advances the cursor. An invalid application entry also fails
closed; it is not silently skipped. An authorized malicious member can therefore
stop group delivery, which remains an explicit availability boundary.

The relay stores opaque MLS bytes and routing metadata. It has no content keys.
`MLSRelayRequest`, `MLSEvent`, and `MLSApplication` define the version 3 JSON
contracts. The relay checks epoch and previous cursor atomically in SQLite.
The application schema has direct operations, initial checkpoint, pairing
confirmation and leave request messages. Only a verified inviter may supply a
new joiner's initial checkpoint. Ordinary changes bind their origin to the
SDK-authenticated sender.

Task replica archive format 1 and deterministic conflict resolution remain
unchanged. Old encrypted live frames, mailbox envelopes, shared group roots,
and pairing journals are not accepted by this client. Keep local tasks and
re-pair when switching implementations.
