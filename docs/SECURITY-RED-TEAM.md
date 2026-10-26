# Security red-team findings

This record is for engineers and consumers assessing the current protocol.
It distinguishes implemented mitigations from unresolved attacks. No
independent audit has been completed.

## Verdict

Re-run on 2026-10-20 against `feature/tw-530-l4-remove-custom-crypto` at
`abb60f3`. That branch stacks on PRs #16, #15, #13, and #12. `SyncEngine` runs
protocol version 2 on OpenMLS (RFC 9420). The custom version 1 cryptography is
no longer in the client. The follow-up branch `feature/tw-530-l5-remove-v1`
removes every `/v1` path from the relay as well; see "Re-run evidence".

**Production claim: not ready.** No crypto finding is open in code. Two items
still block a production claim:

1. **C5:** the integration-only external review of the MLS integration and the
   pairing-frame composition has not happened.
2. **H1:** the admission and rate-limit controls are in sibling PR #14. They
   close only when the hardened relay host is deployed with the perimeter
   controls in `server/README.md`.

C2, C3, H2, and H4 are fixed. The owner accepted C1, C4, H3, and M1 on
2026-10-20; their rationale still holds under MLS. The new findings N1 to N8
need an owner decision. None of them blocks the claims in the table below,
provided the disclosures in "Product claims" ship.

| Claim | Status |
| --- | --- |
| Relay cannot read or forge task changes | Holds against an honest-but-curious or active relay without device secrets (MLS) |
| Keys are bound to verified fingerprints | Holds; a substituted KeyPackage, inviter fingerprint, or Welcome signer is rejected (C2) |
| Removed or departed devices lose future access | Holds once the removal commit or leave proposal reaches the relay (C3, H4); see N3 |
| Forward secrecy for relay-retained ciphertext | Holds across epochs (H2); no post-compromise recovery without a membership change (N6) |
| Privacy between group members | Not provided; accepted by design (C1) |
| Sync availability against a malicious relay or member | Not provided (N1, N2, N7) |
| Public relay service | Not ready (H1) |
| "Private" or "audited" marketing | Blocked until the external review (C5) completes and H1 closes |

### Re-run evidence

All suites passed on 2026-10-21 at `a6c1def` on
`feature/tw-530-l5-remove-v1`, after the relay's `/v1` paths were removed:

- `scripts/uv.sh pytest server/tests -q`: 49 passed. The drop from 77 is the
  deleted version 1 mailbox and route-vector tests.
- `scripts/test-swift.sh`: 82 tests, 0 failures, 2 skipped (the real-relay
  tests that `scripts/test-integration.sh` runs).
- `scripts/test-mls.sh`: Rust 17 passed (6 unit, 11 protocol), relay MLS 27
  passed, Swift `MLSClientTests` 22 passed.
- `scripts/test-integration.sh`: 82 tests, 0 failures, against the real relay
  on `/v2/pairing` and `/v2/mls`.
- Example app: 20 unit tests passed on the iOS 26.5 simulator.

On 2026-10-20 at `abb60f3`, 20 example app unit tests passed on the iOS 26.5
simulator. Pairing, removal, and the removed-device notice were checked by
hand on two simulators.

The Swift suite is smaller than before (129 tests at #16) because the version
1 code and the tests that only covered it were deleted.

H2 has two new tests. A mutation check confirmed that both detect retained
epoch secrets: with `max_past_epochs(2)` instead of `0`, the Rust test fails,
and the Swift test fails with `invalidDelivery`.

Code inspection covered `SyncEngine`, `MLSSession`, `PairingChannel`,
`Invitation`, `MLSClient`, `mls/src/lib.rs`, and `server/gotsync_server/mls.py`.
It found the new findings N1 to N8 below.

## Findings and disposition

"Blocking" means the finding prevents a production claim. "Accepted" means
the finding stays true and is disclosed instead of fixed, with owner sign-off
and the rationale given. "Proposed" means the finding awaits that sign-off.

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| C1 | Critical | Every member can read every member's traffic | Accepted 2026-10-20 |
| C2 | Critical | Unpinned signing keys permit substitution | Fixed |
| C3 | Critical | Old root holders can follow rekey | Fixed |
| C4 | Critical | A live invitation is an admission capability | Accepted 2026-10-20 |
| C5 | Critical | Custom, unaudited cryptographic composition | Fixed in code, pending the integration-only external MLS review; blocking |
| H1 | High | Anonymous capacity exhaustion | Fixed in code by PR #14 (sibling branch); closes when the hardened relay host is deployed with the perimeter controls in `server/README.md`; blocking for public service |
| H2 | High | No forward secrecy for retained data | Fixed |
| H3 | High | No account recovery | Accepted 2026-10-20 |
| H4 | High | No operation to remove another device | Fixed |
| M1 | Medium | Observable relay metadata | Accepted 2026-10-20 |
| N1 | Medium | An invalid commit blocks a group's sync until it pairs again | Not blocking; acceptance proposed |
| N2 | Medium | No administrator: any member, or a thief with an unlocked phone, can remove others | Not blocking; acceptance proposed |
| N3 | Medium | A departing device keeps its keys until its leave proposal is accepted | Not blocking; acceptance proposed |
| N4 | Medium | Task data and the MLS state key use after-first-unlock protection | Not blocking; acceptance proposed |
| N5 | Low | A removed device can read pre-removal history from the relay for up to 24 hours | Not blocking; acceptance proposed |
| N6 | Medium | No periodic key update, so no post-compromise security without a membership change | Not blocking; fix recommended |
| N7 | Low | An offline member stops log pruning until the group log is full | Not blocking; acceptance proposed |
| N8 | Low | Pairing frames have no replay protection or transcript binding | Not blocking; in scope for the C5 review |

### Fixed findings

**C2, fixed.** Every MLS credential is bound to a fingerprint that a user
verified. The inviter adds a KeyPackage only if its signature key matches the
joiner fingerprint behind the safety code (`prepare_add` returns
`FingerprintMismatch` otherwise). The joiner accepts only a Welcome signed by
the inviter fingerprint from the URL or the authenticated offer. Other members
accept a new member because a verified member committed the Add; this is
transitive trust in group members, as C1 already assumes. Evidence:
`SyncEngineMLSTests.testSubstitutedKeyPackageIsRejected`,
`testSubstitutedInviterFingerprintIsRejected`,
`testWelcomeSignedByNonInviterIsRejected`,
`testStolenInvitationSubstitutingResponseShowsDifferentSafetyCode`,
`testOfferForgedWithoutInvitationSecretIsRejected`,
`testApplicationMessageFromNonMemberIsRejected`; Rust
`fingerprints_and_group_id_are_verified_in_both_directions`,
`welcome_must_be_signed_by_pinned_inviter_not_just_contain_them`, and
`replay_tampering_and_unknown_member_are_rejected`.

**C3, fixed.** Removal and leave are MLS Remove commits. They start an epoch
whose secrets the removed leaf cannot derive. The relay revokes the removed
writer in the same entry. The leave path is durable: the departure journal
retries the proposal across restarts. Evidence:
`SyncEngineMLSTests.testRemovedDeviceWithRetainedStateCannotReadLaterEpochs`
and `testLeaveIsCommittedByRemainingMembersAndLocksOutRetainedState` (groups of
2 and 3; a full copy of the removed device's MLS state and key fails to decrypt
later epochs, and the relay refuses its writes and reads past the removal);
Rust `removed_member_with_retained_state_cannot_read_later_epochs` and
`leave_proposal_committed_by_another_member_locks_out_retained_state`; relay
`test_removed_writer_cannot_read_or_write_later_epochs` and
`test_leave_proposal_revokes_its_sender_and_a_later_commit_removes_it`. The
residual window before a leave proposal reaches the relay is N3.

**H2, fixed.** OpenMLS runs with `max_past_epochs(0)`, so a state snapshot
holds no secrets of earlier epochs. The per-sender ratchet deletes each message
key after use. Evidence: Rust
`state_after_epoch_change_cannot_decrypt_earlier_epoch_messages`, which shows
that a pre-change state could decrypt a message and the post-change snapshot
cannot. Also `SyncEngineMLSTests.testStateAfterEpochChangeCannotDecryptEarlierEpochs`,
which uses the persisted, encrypted state of a real engine: a copy that skips
the old messages and processes only the commit fails to open them, as does the
device's own post-change state. Both tests fail under the mutation described
in the evidence section. The fix covers ciphertext the relay retains. It does
not protect plaintext on a compromised device, and it does not give
post-compromise security (N6).

**H4, fixed.** `SyncEngine.linkedDevices` lists members and
`removeDevice(_:)` removes one with an MLS commit. The request is saved first
and retried until the device leaves the roster. Evidence:
`testRemovedDeviceWithRetainedStateCannotReadLaterEpochs` (in the group of 3
the stolen device is offline and a member other than its inviter removes it),
`testDeviceRemovalSurvivesRestartAndConcurrentRemoval`,
`testAddedMemberThatNeverJoinsIsRemoved`, and the real-relay
`RelayIntegrationTests.testPairAndSyncThroughRealRelayOverMLS`, where the
removed device stops receiving and gets HTTP 403.

### Open blocking findings

**C5, fixed in code, pending review.** The custom protocol is gone from the
client: `SyncCrypto`, `MailboxCrypto`, `GroupMailbox`, `GroupCredentials`,
the version 1 mailbox and live clients, `LegacyInvitation`, the no-op
keep-both API, and the version 1 vectors and their tests. Two compositions
remain outside MLS itself and need the integration-only external review before
any "audited" or "private" claim:

- **The pairing-frame composition (`PairingChannel.swift`, `Invitation.swift`).**
  HKDF-SHA256 derives route, pairing token, and two ChaCha20-Poly1305 keys from
  the invitation secret. The frames carry the offer, the hash commitment, the
  inviter nonce, the response, and the decision. A 6-digit SAS covers both
  fingerprints, the group ID, and both nonces. The reviewer should cover the
  commitment ordering, the SAS reduction, frame replay (N8), and the
  phrase-only path, where the joiner learns the inviter fingerprint from a
  frame that any invitation holder can forge.
- **The OpenMLS integration (`mls/src/lib.rs`, `MLSClient`, `MLSSession`).**
  This covers proposal filtering (only self-removal), commit validation and
  merge, credential identity (device ID and writer hash), Welcome signer
  pinning, pending-commit handling, state encryption at rest, and the relay
  authorization model.

**H1, fixed in code by PR #14.** Sibling PR #14 adds per-source token-bucket
rate limits, per-source concurrency limits, trusted-proxy handling, and
optional admission tokens on the WebSocket, `/v1/mailbox`, and `/v2/mls`. This
branch does not contain PR #14, and the relay no longer serves `/v1/mailbox`,
so PR #14's controls apply to the `/v2/pairing` WebSocket and `/v2/mls` only. H1 closes when the hardened relay host runs
with those controls and the perimeter checklist in `server/README.md`.

### Accepted findings

The owner accepted each item below on 2026-10-20. The rationale was rechecked
under MLS. Revisit an acceptance if a product claim starts to depend on it.

- **C1:** Every member can read and edit all tasks by design. MLS gives every
  member every application message, so pairwise privacy would not protect task
  contents from co-members. Holds unchanged.
- **C4:** A live invitation still admits its holder if the inviter approves. It
  expires after 15 minutes, approval waits at most 10 minutes, and the README
  and threat model disclose the risk. The L3 commitment strengthens the
  rationale. A holder can no longer search offline for a KeyPackage whose code
  matches the real joiner's code: each attempt matches with probability 10⁻⁶
  and is visible to the inviter. Because the inviter binds the first
  commitment, a holder who answers first also blocks the real joiner, which
  users notice. The phrase path gives the holder the same power to impersonate
  the inviter to a joiner; comparing codes on both devices detects it.
  Proximity is still not proven. Holds.
- **H3:** Accountless operation rules out server-held recovery. Since L3 the
  task replica and MLS state are also excluded from device backups, so a
  restored backup has no tasks or link. Losing every device still loses the
  group. This is disclosed. Holds.
- **M1:** The relay must route and store ciphertext. It sees timing, sizes, IP
  addresses, group IDs, cursors, epochs, writer hashes, and add and remove
  events, which reveal membership churn. No product claim covers metadata
  privacy. Holds. The relay no longer keeps version 1 mailbox routes,
  envelopes, or receipts, so the MLS delivery log and the volatile pairing
  rooms are the only metadata it holds.

### New findings

**N1. An invalid commit blocks a group's sync until it pairs again (Medium).**
The relay does not parse MLS. It accepts any payload of kind `commit` from a
current writer at the current epoch and advances its epoch. The relay
operator can do the same directly in its database. Every client stops at the
unverifiable commit and reports `syncHistoryBlocked`. Its own appends then
fail with `epochConflict`, so the group cannot sync in either direction until
its devices pair into a new group. Tasks stay on each device. Evidence:
`testInvalidCommitBlocksSyncAndIsSurfaced` and the Swift MLS
`testInvalidApplicationIsSkippedAndInvalidCommitFailsClosed`. **Proposed
acceptance:** the relay can already deny service by withholding the log, and
members are fully trusted (C1). Failing closed is the safe choice; skipping an
unverifiable commit would fork the group. A later relay could reject commits
whose MLS framing does not parse, but cannot verify them without group
secrets.

**N2. No administrator role (Medium).** Any member can remove any other
member. A thief with an unlocked stolen phone can remove the owner's other
devices before they remove it; whoever commits first wins. The relay also
trusts the `removeWriter` field of a commit entry. A member can append a valid
commit that names another member's writer hash. The victim then loses relay
access while it is still an MLS member, and its sync retries without success.
**Proposed acceptance:** consistent with C1, every member is fully trusted; a
thief with an unlocked device can read all tasks anyway. The README discloses
the lack of an administrator. A device that is removed this way can pair
again. An admin role or a removal quorum would change the product model and is
not planned.

**N3. A departing device keeps its keys until its leave proposal is accepted
(Medium).** `unlinkAndKeepTasks()` and `eraseLocalData()` move the MLS state
and key into `mls-v2-departing/` and publish the proposal in the background. If
the device is offline, the old state stays on it. If the device is stolen
before the proposal reaches the relay, the other members do not know it left,
and the thief can keep reading until a member removes the device. **Proposed
acceptance:** the journal is what makes leave durable instead of best effort
(C3). The mitigation is H4, removing the device from another phone. The
example's leave copy should say so for a lost phone.

**N4. After-first-unlock protection for task data and the MLS key (Medium).**
The MLS state key uses `AfterFirstUnlockThisDeviceOnly`. The replica,
checkpoint, and MLS database use `completeUntilFirstUserAuthentication`.
Someone with code execution on, or a forensic image of, a locked device that
was unlocked once since boot can read tasks and the MLS state. **Proposed
acceptance:** this is what allows background receive on a locked device to
persist. Under `complete` protection, received tasks could not be stored until
the next unlock. The trade-off is documented in THREAT-MODEL.md. The secrets
stay `ThisDeviceOnly` and out of backups.

**N5. A removed device can read pre-removal history for up to 24 hours (Low).**
A revoked writer may fetch entries up to its removal cursor until it
acknowledges that cursor or 24 hours pass. A thief holding a removed, offline
device can therefore fetch and decrypt the backlog from before the removal
that the device had not yet processed. Evidence:
`test_removed_writer_final_read_ack_and_pruning` and
`test_removed_writer_floor_expires_after_day`. **Proposed acceptance:** these
are messages from epochs the device belonged to. The device would have
received them if it had been online, and they are bounded by the removal
cursor. The window lets a legitimately removed device catch up before it
erases itself. A shorter window or an opt-out for theft removals would reduce
it.

**N6. No periodic key update (Medium).** Epochs change only on Add and Remove
commits. If the MLS state and key of a device are copied without the device
being removed, for example through a forensic image (N4), the copy keeps
decrypting new messages until the next membership change. **Not blocking**
because no product claim covers post-compromise security. Recommended fix:
periodic self-Update commits (for example daily or every N messages), so that
H2-style forward secrecy also limits a silent state clone.

**N7. An offline member stops log pruning (Low).** The relay deletes entries
only after every current writer acknowledges them. A member that never syncs
holds the whole log, which grows until it reaches 10,000 entries or 16 MiB.
Every append then fails with `deliveryCapacity`. **Proposed acceptance:**
removing the inactive device (H4) releases the log, and an added member that
never joins is already removed after 15 minutes. A relay-side inactivity
policy could follow with H1. The MLS log has no time-based expiry; the version
1 mailbox's 365-day retention no longer applies, because that store has been
removed.

**N8. Pairing frames have no replay protection or transcript binding (Low).**
Frames are bound only to the invitation key, direction, and kind byte. Within
an invitation's lifetime the relay can replay an earlier frame into a later
attempt. Its effect is limited to aborting pairing: a replayed decision cannot
cause a join, because the joiner needs a Welcome signed by the inviter for its
own KeyPackage reference, and a replayed response fails the commitment check.
**Not blocking.** It is in scope for the C5 review.

## Product claims

Consumers may state that task contents are end-to-end encrypted with MLS,
that the relay cannot read or forge them, and that a removed device cannot read
later changes. They must disclose:

- full shared access between linked devices (C1);
- live-invitation admission and the need to compare safety codes (C4);
- the lack of recovery when every device is lost (H3);
- that any linked device can remove any other (N2);
- that removal does not wipe a device, and that a phone lost after leaving
  should be removed from another phone (N3);
- that a malicious relay can stop sync until devices pair again (N1);
- the lack of push receive.

Avoid claims of an independent audit, "private" or audited marketing, metadata
privacy, privacy between members, post-compromise security, or theft-resistant
removal until C5 and H1 close and the relevant findings change. The example's
copy no longer refers to live sockets or mailboxes, and it shows
`removedFromGroup` on the unpaired screen.

## Follow-up verification

- **C5:** run the integration-only external review with the scope listed
  above, including the pairing-frame composition and N8, and record its
  findings here.
- **H1:** after PR #14 merges and the hardened host is deployed, re-run the
  admission and rate-limit tests against that host and record the perimeter
  configuration.
- **N1 to N8:** record the owner's acceptance or a fix for each. If N6 is
  fixed, add a test showing that a state clone stops decrypting after an
  Update commit.
- **H2:** re-run the mutation check, temporarily setting a non-zero
  `max_past_epochs`, after any OpenMLS upgrade or `config()` change.
- **Server:** done. The relay serves only `/v2/pairing` and `/v2/mls`, and
  `/healthz` advertises `supportedVersions: [2]`.
