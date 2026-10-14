# Threat model

This document is for consumers assessing GotSync and operators deploying its
relay. It describes the implemented task-sync model, rather than a security
certification. See PROTOCOL.md for formats and SECURITY-RED-TEAM.md for findings.

## Assets and trust boundaries

Device-local storage contains task plaintext and replication history. The
injected `SecretStore` holds device identity, group roots, signing keys, and
pairing recovery records. The production Keychain implementation uses
`WhenUnlockedThisDeviceOnly`, disables synchronisation, and separates consumers
by an explicitly supplied service name. In-memory test stores provide no
production protection.

The relay receives ciphertext, bearer authorization capabilities, opaque
routes, message identifiers, cursors, and retention metadata. It also observes
IP addresses, timing, sizes, and co-membership in live rooms. The server has
no application decryption keys. Its SQLite database and backups still need
access controls and encrypted storage.

A group has up to eight devices. Every member can read and edit all tasks and
invite additional members. There is no administrator role or privacy boundary
between members. TLS protects transport between a device and the deployment;
application encryption protects message contents from the relay.

## Adversaries considered

Authenticated encryption rejects modified frames and mailbox envelopes.
Sequence checks and durable replication make duplicates and replay safe within
their supported limits. An active relay can delay, reorder, replay, inject, or
drop traffic, but cannot create valid task changes without device secrets.
Receivers persist changes before acknowledging mailbox delivery.

A one-time random invitation authorizes a join attempt. Possession of a live
invitation is the authorization mechanism. Safety-code comparison catches
accidental cross-pairing but cannot defeat an attacker who already holds the
invitation. The host must approve pairing, and the clients persist completion
state to recover interrupted finalization.

## Unresolved limits

A compromised member or extracted group root defeats confidentiality for the
whole group, including derived sender/recipient mailboxes. Signed membership
updates authenticate issuers only after their real signing keys are pinned.
Legacy or newly provisioned rosters with empty signing keys use trust on first
use and remain vulnerable to key substitution.

Rekey material travels under the previous shared root. An old root holder can
observe it and follow rotation. Leaving is best effort and does not guarantee
exclusion, deletion of a former member's local data, or a remote wipe. There is
no forward secrecy for retained mailbox data after root compromise.

The relay can deny service. Anonymous clients can exhaust capacity despite
bounded rooms, queues, request bodies, and mailbox quotas. Admission controls,
perimeter rate limits, backup policy, and deployment monitoring are operator
responsibilities. Public service hardening remains separate from this
repository restructure.

## Delivery and loss

The engine receives while its application is active. Background send is best
effort; iOS suspension and force-quit can prevent delivery until the next launch.
An edit that never reaches another replica or the mailbox can be lost with its
source device. Mailbox ciphertext expires after 365 days by default. Fetching
does not extend a queue's retention deadline. There is no recovery if every
copy of a group's secrets and data is lost.
