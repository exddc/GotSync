# Security red-team findings

This record is for engineers and consumers assessing the current protocol.
It distinguishes implemented mitigations from unresolved attacks. No
independent audit has been completed.

## Verdict

Re-run on 2026-10-20 against `main` at `88be0f6`.

**Production claim: not ready.** `SyncEngine` still uses the custom protocol.
The blocking crypto findings C2, C3, C5, and H2 remain open. They are resolved
by moving `SyncEngine` to the OpenMLS package and the `/v2/mls` relay, not by
patching the custom protocol. Public operation also requires the hardened relay
host (H1). The owner accepted C1, C4, H3, and M1 on 2026-10-20 with the
rationale below.

| Claim | Status |
| --- | --- |
| Relay cannot read or forge task changes | Holds for an honest-but-curious or active relay without device secrets |
| Privacy between group members | Not provided; accepted by design (C1) |
| Forged membership updates are rejected | Only when the issuer's signing key is pinned (C2 open) |
| Removed or stolen devices lose future access | Not provided (C3, H4 open) |
| Forward secrecy for retained data | Not provided (H2 open) |
| Public relay service | Not ready (H1 open) |
| "Private" or "audited" marketing | Blocked until every blocking finding closes and the MLS integration review completes |

### Re-run evidence

All suites passed on 2026-10-20:

- `scripts/uv.sh pytest server/tests -q`: 75 passed.
- `scripts/test-swift.sh`: 114 tests, 0 failures, 1 skipped (the real-relay
  integration test, which `scripts/test-integration.sh` runs).
- `scripts/test-mls.sh`: Rust 12 passed, relay MLS 24 passed, Swift
  `MLSClientTests` 21 passed.

Code inspection of `GroupMailbox.swift` and `GroupCredentials.swift` confirms
that C1, C2, C3, and H2 remain present. It also found a C2 detail missing from
the previous record: an update carrying a rekey seed from an issuer without a
pinned key is accepted without any signature check, not only on first use.
`SyncEngine` exposes `leaveGroupAndKeepTasks()` but no operation to remove
another device.

## Experimental MLS status

The experimental OpenMLS package in `Packages/GotSyncMLS` tests rejection of
unknown-member application messages (R2a), QR fingerprint substitution, Welcome-signer
substitution, and removed-device decryption of later epochs. It also tests
replays, tampering, commit conflicts, and durable state/inbox recovery.
These results apply only to the experimental package. `SyncEngine` still
uses the custom protocol, so no existing finding is marked resolved.

The Rust tests covering these attacks are
`three_members_offline_catchup_and_removal`,
`fingerprints_and_group_id_are_verified_in_both_directions`,
`replay_tampering_and_unknown_member_are_rejected`, and
`welcome_must_be_signed_by_pinned_inviter_not_just_contain_them`. The relay test
`test_unauthorized_and_removed_writers_cannot_advance_epoch` covers delivery
authorization. Once `SyncEngine` uses this package, re-run these checks against
the engine and the real relay before closing any finding.

## Findings and disposition

"Blocking" means the finding prevents a production claim. "Accepted" means
the finding stays true and is disclosed instead of fixed, with owner sign-off
and the rationale given.

| ID | Finding | Disposition | Closes when |
| --- | --- | --- | --- |
| C1 | Every member derives every pair's mailbox keys | Accepted 2026-10-20 | Accepted; shared access is the product model |
| C2 | Unpinned signing keys permit substitution | Blocking, open | `SyncEngine` uses MLS credentials bound to verified fingerprints |
| C3 | Old root holders can follow rekey | Blocking, open | `SyncEngine` removes members with MLS commits |
| C4 | A live invitation is an admission capability | Accepted 2026-10-20 | Accepted; disclosure replaces proximity |
| C5 | Custom, unaudited cryptographic composition | Blocking, open | MLS replaces the custom protocol and the integration review completes |
| H1 | Anonymous capacity exhaustion | Blocking for public service | Hardened relay host deploys admission and rate limits |
| H2 | No forward secrecy for retained mailbox data | Blocking, open | `SyncEngine` uses MLS epochs |
| H3 | No account recovery | Accepted 2026-10-20 | Accepted; loss is disclosed |
| H4 | No operation to remove another device | Blocking, open | `SyncEngine` exposes MLS removal |
| M1 | Observable relay metadata | Accepted 2026-10-20 | Accepted; no metadata privacy claim |

### Finding details

| ID | Current behavior and impact | Required mitigation |
| --- | --- | --- |
| C1 | `GroupMailboxKeyMaterial` derives keys from one shared root. A third member can decrypt another pair's traffic. This is consistent with shared task access, but provides no privacy between members. | Use independently distributed sender or pairwise keys if member privacy becomes a goal. |
| C2 | Signed membership v2 rejects unsigned and wrong-known-key updates. A roster entry with an empty key can accept a key claimed by the snapshot itself, and an update carrying a rekey seed from such an issuer is accepted unsigned. Join provision does not bind every member's real signing key. | Bind all roster keys during authenticated provision and reject updates for unpinned issuers. |
| C3 | Membership messages carry the rekey seed under the previous root. A removed or compromised device retaining that root can derive the next root and read subsequent traffic. Leave is best effort, without a durable delivery journal, and a two-member leave does not publish a rekey. | Deliver fresh secrets through keys unavailable to removed members and journal leave/removal delivery. |
| C4 | Someone holding a live invitation's phrase or QR can attempt admission during the 15-minute window. Safety-code comparison does not establish physical proximity or defeat invite theft. | Add a verified local channel if proximity is required; otherwise retain explicit admission disclosure. |
| C5 | Key derivation, envelopes, membership signing, and rekey are a custom composition. Protocol vectors freeze behavior but do not show the design is sound. | Replace with MLS (RFC 9420) and complete the integration-only external review. |
| H1 | Room, socket, queue, request, and SQLite quotas bound work but do not provide caller admission or robust per-source abuse controls. | Add deployment admission controls and perimeter rate limiting before operating a public service. |
| H2 | Compromise of a retained root permits derivation of keys for stored envelopes. Epoch separation alone does not solve C3. | Introduce an appropriate ratchet and authenticated secret distribution with a migration plan. |
| H3 | Losing every device loses the group's keys and data. There is no recovery account or server-side plaintext backup. | Define an explicit recovery mechanism before promising recovery. |
| H4 | A member can leave, but no member can exclude a lost or stolen device. Combined with C3, a stolen device keeps access. | Expose removal of another device, and make it cryptographically effective. |
| M1 | Stable routes, global cursors, sizes, IP addresses, timing, and acknowledgements expose activity metadata. Aggregate metrics suppress identifiers but transport metadata remains visible. | Evaluate route rotation and privacy-preserving storage metadata for a stronger privacy goal. |

The protocol lets any valid group member remove another member through a
signed membership update, but `SyncEngine` does not expose this (H4). This is
the current no-administrator model, not protection from a malicious co-member. A departing device's already stored plaintext cannot be
remotely wiped.

### Acceptance rationale

The owner accepted each item below on 2026-10-20. Revisit an acceptance if a
product claim starts to depend on it.

- **C1:** Every member can read and edit all tasks by design. Pairwise
  privacy would not protect task contents from co-members. MLS also gives
  every member every application message, so the migration does not change this.
- **C4:** Invitations expire after 15 minutes and need host approval after
  safety-code comparison. The README and threat model disclose that a stolen
  invitation admits its holder.
- **H3:** Accountless operation rules out server-held recovery. Permanent loss
  when every device is lost is already disclosed to users.
- **M1:** The relay must route and store ciphertext, so it sees timing, size,
  and network metadata. No product claim covers metadata privacy.

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

After `SyncEngine` moves to MLS, re-run this record against the engine. For
C2, a key substituted for an unverified fingerprint must be rejected. For C3
and H4, a device removed by another member must fail to decrypt a
later-epoch operation. For H2, a state snapshot taken after an epoch change
must not decrypt earlier application messages. Update the protocol version,
compatibility policy, and threat model with that change.
