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
state while the device is locked, after the first unlock since boot. The MLS
database, the replication checkpoint, and the task replica match it: they use
`completeUntilFirstUserAuthentication` protection and are excluded from
backups. A background cycle on a locked device can therefore persist received
tasks and acknowledge them.

The trade-off is that someone with code execution on a locked device, after
that first unlock, can read the task plaintext, the state key, and the MLS
state. `complete` protection would keep the tasks unreadable until the next
unlock, but it would also stop locked receive from persisting anything.
Excluding the files from backups means a backup restored to another device
contains no tasks or link; the tasks return only by pairing with a device that
still has them.

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
Both devices show a safety code over the group ID, both fingerprints, and a
nonce from each device; the inviter adds the joiner only after approval. The
joiner commits to its KeyPackage, fingerprint, and nonce before it learns the
inviter's nonce, and the inviter accepts one commitment per invitation. Someone
holding the invitation therefore cannot search offline for a KeyPackage whose
code matches the real joiner's code. Each attempt matches with probability
10⁻⁶ and costs a visible pairing attempt. The code still cannot defeat an
attacker who holds the invitation and wins the race to respond, but then the
real joiner shows a different value. The inviter's approval wait ends after 10
minutes, before the relay discards the KeyPackage.

## Removal and leave

Any member can remove another device with an MLS Remove commit. The commit
starts a new epoch whose secrets the removed leaf cannot derive, so a removed
or stolen device fails to decrypt later application messages even with a full
copy of its MLS state. The relay revokes the removed device's writer token in
the same step: it refuses its appends at once and serves its reads only up to
the removal commit, for at most 24 hours or until the device acknowledges that
commit. Removal requests are saved before they are sent and are retried until
they succeed.

Leaving publishes an MLS proposal that removes this device, and the next member
to sync commits it. The relay revokes the leaving device when the proposal
arrives. Until then the departure journal keeps the old MLS state and key on
the device, so an offline leave is completed later rather than lost. A device
that learns it was removed erases its MLS state. An added member that never
sends a message is removed after 15 minutes, so a joiner that cancels does not
leave a hidden member behind.

These mechanisms have limits:

- A compromised member defeats confidentiality for the whole group, since
  every member reads every message.
- There is no administrator. Any member, including a thief using an unlocked
  stolen device, can remove any other member. Whoever commits first wins.
- Removal and leave do not delete tasks the device already received, and
  cannot wipe a device remotely.
- A device that never comes online again stays a member until someone
  removes it.

## Unresolved limits

Pairing frames on the relay WebSocket use ChaCha20-Poly1305 with keys derived
from the invitation secret through HKDF-SHA256. They carry only the group ID,
fingerprints, nonces, a commitment, and a KeyPackage reference. MLS secures
everything after the Welcome. The MLS integration has not received an
independent review.

The relay can deny service. The relay enforces per-source connection and
request rate limits, per-source concurrency limits, and optional deployment
admission by network allowlist or proxy-injected token. These bound what one
address or IPv6 `/64` can consume, but anonymous clients spread across many
addresses can still exhaust capacity despite bounded rooms, request bodies,
mailbox quotas, and delivery logs. Operators remain responsible for the TLS
proxy, trusted-proxy configuration, perimeter rate limits and DDoS protection,
firewalling the relay ports, backup policy, and deployment monitoring. See the
relay README for the perimeter checklist.

## Delivery and loss

The engine receives while its application is active. Background send is best
effort; iOS suspension and force-quit can prevent delivery until the next launch.
An edit that never reaches another replica or the delivery log can be lost with
its source device. The relay prunes log entries once every current member has
acknowledged them. There is no recovery if every copy of a group's secrets and
data is lost.
