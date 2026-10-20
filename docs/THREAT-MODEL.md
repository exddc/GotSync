# Threat model

This document is for consumers assessing GotSync and operators deploying its
relay. It describes the implemented task-sync model, rather than a security
certification. See PROTOCOL.md for formats and SECURITY-RED-TEAM.md for findings.

## Assets and trust boundaries

Device-local storage contains task plaintext and replication history. The
injected `SecretStore` holds the device identity and the key that encrypts the
local MLS state. The MLS state itself, including signing keys and epoch
secrets, lives in an AES-GCM-encrypted SQLite file under the storage
directory. The production Keychain implementation disables synchronisation,
binds every item to this device, and separates consumers by an explicitly
supplied service name. In-memory test stores provide no production protection.

The MLS state key uses `AfterFirstUnlockThisDeviceOnly`; every other secret
uses `WhenUnlockedThisDeviceOnly`. This lets a background sync open the MLS
state while the device is locked, after the first unlock since boot. The
trade-off is that someone with code execution on a locked device, after that
first unlock, can read the state key and decrypt the MLS state. The MLS
database and the replication checkpoint (group ID, member device IDs, and
upload position) use `completeUntilFirstUserAuthentication` protection to
match. The task replica keeps `complete` protection. A background cycle on a
locked device can upload edits but cannot persist received tasks; it leaves
them unacknowledged and a later cycle retries.

The relay receives MLS ciphertext, commits, Welcome messages, KeyPackages,
writer-token hashes, cursors, and epochs. It also observes IP addresses,
timing, sizes, group IDs, and co-membership in pairing rooms. It sees the
pairing token when the inviter fetches a KeyPackage, but not the invitation
secret it is derived from. The server has no application decryption keys. Its
SQLite database and backups still need access controls and encrypted storage.

A group has up to eight devices. Every member can read and edit all tasks and
invite additional members. There is no administrator role or privacy boundary
between members. TLS protects transport between a device and the deployment;
MLS protects message contents from the relay.

## Adversaries considered

MLS authenticates every commit and application message to a group member and
rejects modified, replayed, and non-member messages. The engine skips a
rejected application message and keeps syncing. It stops at a commit it cannot
verify and reports the blocked log instead of skipping it. An active relay can
delay, reorder, drop, or replay traffic and withhold the log, but cannot create
valid task changes without device secrets. Receivers persist task changes
before acknowledging MLS delivery.

A one-time random invitation authorizes a join attempt. The invitation URL
binds the group ID and the inviter's MLS fingerprint; a joiner using the phrase
learns them from an offer sealed under a key derived from the invitation
secret. The joiner's KeyPackage reference and fingerprint return under a second
derived key. The inviter rejects a KeyPackage whose hash or signing key does not
match, and the joiner rejects a Welcome that the expected inviter did not sign.
Both devices show a safety code over both fingerprints and the group ID; the
inviter adds the joiner only after approval. The code cannot defeat an
attacker who already holds the invitation and wins the race to respond, but it
shows a different value on the real joiner.

## Unresolved limits

A compromised member defeats confidentiality for the whole group, since every
member reads every message. No operation removes another device yet. Leaving
erases this device's MLS state, but the remaining members still list it in the
group and its leaf stays until a removal commit. Leaving does not delete a
former member's local data or wipe it remotely.

Pairing frames on the relay WebSocket use ChaCha20-Poly1305 with keys derived
from the invitation secret through HKDF-SHA256. They carry only the group ID,
fingerprints, and a KeyPackage reference. MLS secures everything after the
Welcome. The MLS integration has not received an independent review.

The relay can deny service. Anonymous clients can exhaust capacity despite
bounded rooms, request bodies, and delivery logs. Admission controls,
perimeter rate limits, backup policy, and deployment monitoring are operator
responsibilities.

## Delivery and loss

The engine receives while its application is active. Background send is best
effort; iOS suspension and force-quit can prevent delivery until the next launch.
An edit that never reaches another replica or the delivery log can be lost with
its source device. The relay prunes log entries once every current member has
acknowledged them. There is no recovery if every copy of a group's secrets and
data is lost.
