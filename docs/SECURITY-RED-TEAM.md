# Security red-team findings

This record is for engineers and consumers assessing the current protocol.
It carries forward the internal group-sync review and distinguishes implemented
mitigations from unresolved attacks. The repository restructure does not claim
to fix the underlying shared-root security design. No independent audit has
been completed.

## Open findings

| ID | Finding | Current behavior and impact | Required mitigation |
| --- | --- | --- | --- |
| C1 | Every group member derives every pair's mailbox keys | `GroupMailboxKeyMaterial` derives keys from one shared root. A third member can decrypt another pair's traffic. This is consistent with shared task access, but provides no privacy between members. | Use independently distributed sender or pairwise keys if member privacy becomes a goal. |
| C2 | Unpinned signing keys permit substitution on first use | Signed membership v2 rejects unsigned and wrong-known-key updates. A roster entry with an empty key can accept a key claimed by the snapshot itself. Join provision does not bind every member's real signing key. | Bind all roster keys during authenticated provision and reject updates for unpinned issuers. |
| C3 | Old root holders can follow rekey | Membership messages carry the rekey seed under the previous root. A removed or compromised device retaining that root can derive the next root and read subsequent traffic. Leave is best effort, without a durable delivery journal, and a two-member leave does not publish a rekey. | Deliver fresh secrets through keys unavailable to removed members and journal leave/removal delivery. |
| C4 | A live invitation is an admission capability | Someone holding its phrase or QR can attempt admission during the 15-minute window. Safety-code comparison does not establish physical proximity or defeat invite theft. | Add a verified local channel if proximity is required; otherwise retain explicit admission disclosure. |
| H1 | Anonymous capacity exhaustion | Room, socket, queue, request, and SQLite quotas bound work but do not provide caller admission or robust per-source abuse controls. | Add deployment admission controls and perimeter rate limiting before operating a public service. |
| H2 | No forward secrecy for retained mailbox data | Compromise of a retained root permits derivation of keys for stored envelopes. Epoch separation alone does not solve C3. | Introduce an appropriate ratchet and authenticated secret distribution with a migration plan. |
| H3 | No account recovery | Losing every device loses the group's keys and data. There is no recovery account or server-side plaintext backup. | Define an explicit recovery mechanism before promising recovery. |
| M1 | Observable relay metadata | Stable routes, global cursors, sizes, IP addresses, timing, and acknowledgements expose activity metadata. Aggregate metrics suppress identifiers but transport metadata remains visible. | Evaluate route rotation and privacy-preserving storage metadata for a stronger privacy goal. |

Any valid group member may remove another member through a signed membership
update. This is the current no-administrator model, not protection from a
malicious co-member. A departing device's already stored plaintext cannot be
remotely wiped.

## Existing mitigations and evidence

`GroupSyncTests.testMembershipSnapshotRejectsUnsignedOrForeignIssuer` verifies
signature and issuer checks when an issuer key is known.
`testSharedGroupRootCanDeriveForeignPairMailbox` records the C1 boundary by
showing that a third member derives a foreign pair's keys.
`testEpochRekeyInvalidatesOldMailboxMaterial` verifies epoch isolation without
assuming the old root holder cannot learn the rekey seed.
`testLeavePublishesRemoveAndDropsRoutes` checks the local membership operation;
it does not prove reliable remote exclusion.

Pairing recovery, mailbox, and terminal-journal suites check durable completion
and persist-before-ack behavior. Protocol vectors freeze version 1 key
derivation, canonical records, encrypted envelopes, and membership snapshots
against the pre-extraction baseline. The real-server integration test covers
pairing, live convergence, restart catch-up, and three-member mailbox delivery.
These tests establish implementation behavior, not the absence of other
cryptographic attacks.

## Product claims

Consumers must disclose full shared access, live-invitation admission, lack of
recovery and push receive, and the limits of removal and rekey. The example's
leave text does not claim that a former root holder loses future access.
Avoid claims of forward secrecy, private traffic between group members,
reliable remote deletion, or theft-resistant removal until their underlying
mechanisms change and receive review.

## Follow-up verification

Add adversarial tests that substitute an attacker key for an unpinned issuer,
and that decrypt rekey material with an old root before decrypting a new-epoch
operation. Those are open attack paths, not mitigations demonstrated by this
restructure. A fix must invert the expected successful attack and update the
protocol version, compatibility policy, and threat model where required.
