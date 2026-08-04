# Security red team — GotDone Relay (Option C)

**First pass:** 2026-08-03  
**Re-analysis (post mitigations):** 2026-08-03  
**Scope:** Code, workflow, and design after C2/C3/C4/copy work.  
**Not:** formal cryptographic audit or public-deployment pen test.  
**Related:** [PROTOCOL.md](PROTOCOL.md), [ARCHITECTURE.md](ARCHITECTURE.md), [MULTI-DEVICE-GROUP-SYNC.md](MULTI-DEVICE-GROUP-SYNC.md).

### How to use this doc

1. **Status** on each finding is the source of truth after re-analysis.  
2. **Critical residual** items still block production multi-device trust claims.  
3. Each open item has **Mitigation** + **Verify**.

---

## Verdict (updated)

| Layer | First pass | After changes |
| --- | --- | --- |
| **Vs honest-but-curious relay** | Strong | **Still strong** (unchanged model) |
| **Vs linked co-member privacy** | Weak (shared root) | **Still weak by design** — now **honest in UI** (C1 accepted) |
| **Vs forged membership** | Weak (unsigned gen++) | **Much better** — Ed25519 signed snapshots + reject path (C2) |
| **Vs leave / stolen phone crypto** | Weak (no rekey) | **Partially improved, still incomplete** — rekey exists but **does not exclude holders of old `groupRoot`** (C3 residual) |
| **Vs live invite leak** | Weak | **Honest copy + TTL** — still capability admission (C4 accepted) |
| **Production claim** | Not ready | **Still not ready** — custom crypto, shared-root rekey limit, no remove-member UI, public relay hardening |

**Local POC (trusted phones):** better than before; safe to demo with disclosures.  
**Untrusted co-member / stolen phone / App Store E2E claims:** still blocked on C1 design + C3 residual + audit.

---

## What landed (evidence)

| Mitigation | Where | Tests / UI |
| --- | --- | --- |
| Shared-access honesty (C1) | `ProductSyncPolicy.sharedAccessDisclosure`, Manage Sync, invite footers | UX screenshots under `docs/screenshots/security-red-team/`; `testSharedGroupRootCanDeriveForeignPairMailbox` **documents** current crypto |
| Signed membership (C2) | `GroupMembershipSnapshot` v2, Ed25519, `acceptedUpdate` | `testMembershipSnapshotRejectsUnsignedOrForeignIssuer` |
| Epoch rekey on remove/leave (C3 attempt) | `groupRootRekey`, `removingMemberWithRekey`, `publishLocalLeaveMembership`, `acceptedUpdate` | `testEpochRekeyInvalidatesOldMailboxMaterial`, `testLeavePublishesRemoveAndDropsRoutes` |
| Invite honesty (C4) | `inviteDetail`, safety code detail | Pairing + Manage Sync copy; weak TTL/single-use unit |
| Marketing banlist (M3) | `ConsumerCopyBanlist` | Overclaim tokens banned |
| Per-device signing keys | `GroupCredentials.localSigningPrivateKey`, roster pubkeys | Round-trip via Keychain encode |

---

## What is solid (do not regress)

| Strength | Verify |
| --- | --- |
| Relay sees ciphertext + capabilities only | Mailbox/auth unit tests |
| Invite is 128-bit one-time secret, not long-term root | `Invitation` tests |
| Keychain `WhenUnlockedThisDeviceOnly` | Attribute review |
| Persist-before-PUT pairing | Recovery suite |
| Release fail-closed TLS endpoints | Endpoint config tests |
| Relay loopback-by-default | Server bind tests |
| **v2 membership requires 64-byte signature** | C2 unit |
| **Remove without `rekeySeed` rejected** | C2/C3 unit |
| **Mailbox material epoch-bound** (old root ≠ new root routes) | C3 unit |

---

## Critical findings (re-scored)

### C1 — Shared `groupRoot` (co-member can decrypt all pairs)

| Field | Value |
| --- | --- |
| **Status** | **Open by design / product-accepted** |
| **Severity** | Critical for *privacy between members*; **not a bug** if product discloses it |
| **Finding** | Unchanged: `GroupMailboxKeyMaterial` is `HKDF(groupRoot, sender‖recipient‖epoch)`. Any member derives B→C keys. |
| **What changed** | UI/copy: `sharedAccessDisclosure`. Baseline test keeps documenting decrypt-by-third-member. |
| **Mitigations (future)** | Pairwise sender keys / MLS so A cannot open B→C; invert the C1 test when that lands. |
| **Verify** | Keep `testSharedGroupRootCanDeriveForeignPairMailbox` green until inverted. UX test: Manage Sync shows shared-access string. |

---

### C2 — Membership forgery

| Field | Value |
| --- | --- |
| **Status** | **Mostly fixed** — residual TOFU / empty-key path |
| **Severity** | Was Critical → **High residual** (TOFU); core forge path **mitigated** when issuer pubkey is already known |
| **Finding (original)** | Highest `membershipGeneration` + AEAD under shared root only. |
| **What changed** | Snapshots v2 signed with Ed25519. `acceptedUpdate` requires issuer ∈ active roster, valid signature, rekey on any remove, epoch rules. Unsigned / wrong key / remove-without-rekey throw. |
| **Residual R2a — TOFU when issuer pubkey empty** | If local roster has **empty** `signingPublicKey` for issuer, code accepts signature verified against the **pubkey claimed inside the snapshot itself**. An attacker who still has `groupRoot` (or can put membership envelopes) and targets a peer that never learned issuer’s real key can pin a **fake** key for that device ID on first use. |
| **Residual R2b — any valid member can remove others** | Intentional “no admin” model: signed remove+rekey by any active member still partitions/removes peers. Product honesty, not crypto failure. |
| **Residual R2c — joiner keys not bound at provision** | New joiners often land with empty remote pubkeys until gossip; widens TOFU window. |
| **Mitigations** | (1) Ship each member’s signing pubkey in **join provision / commit** and reject empty keys after founding. (2) **Never** verify with snapshot-claimed key unless TOFU is explicit and one-shot with UX. (3) Prefer: if known key empty, **reject** until out-of-band or provision-bound key. (4) Optional: multi-member confirm for remove. |
| **Verify** | |
| | **Unit (must add):** credentials with empty issuer pubkey + snapshot signed by attacker keypair claiming issuer’s device ID → **must reject** after fix; today may accept (assert current then invert). |
| | **Unit (existing):** unsigned / foreign key / remove without rekey → throw (keep green). |
| | **Unit:** provision/join installs non-empty pubkeys for all founding members. |
| | **Integration:** A cannot drop B from C’s roster without A’s real signing key already known to C. |

---

### C3 — Leave / stolen phone / rekey

| Field | Value |
| --- | --- |
| **Status** | **Partially fixed — critical residual** |
| **Severity** | Still **Critical** vs “stolen phone loses future access” claim |
| **What improved** | `groupRootRekey`; remove requires seed + epoch+1; leave path can publish signed roster-without-self + seed; remaining members drop routes; honest leave copy. |
| **Residual R3a — rekeySeed readable by anyone with old `groupRoot`** | Membership envelopes (including leave/remove) are sealed under **old** `groupRoot` / epoch (by design, so peers can open). A stolen device that **still holds** `groupRoot_e` can open that envelope, read `rekeySeed`, compute `groupRoot_{e+1}`, and **keep decrypting new traffic**. Epoch rotation **does not exclude** prior root holders. This is structural with shared-root control-plane encryption. |
| **Residual R3b — leave is best-effort + async** | `leaveGroupAndKeepTasks` fires `publishLocalLeaveMembership` in a Task then **immediately** `unlinkAndKeepTasks`. No durable “leave may have been stored” journal; failure is swallowed. Peers may never rekey. |
| **Residual R3c — N=2 leave skips publish** | Publish only if `activeMemberCount >= 3` (`preparingLocalLeave` needs ≥2 remaining). Two-phone leave does not rekey the peer. |
| **Residual R3d — no Remove member UI** | Manage Sync has leave self only. Lost-phone path for remaining members is **missing** (no `removingMemberWithRekey` from UI). |
| **Residual R3e — history** | Old epoch ciphertext on disk/relay still decryptable with old root; no remote wipe (correctly disclosed). |
| **Mitigations** | |
| | **Honest copy now:** “Left phone cannot read new edits” is **overstrong** if the left phone retained `groupRoot` and observes rekey gossip. Soften to: *“Other phones rotate keys; a phone that already had the old secret may still follow rekey until pairwise rekey exists.”* Or only claim drop from roster / stop accepting its ops. |
| | **Crypto (real fix):** Distribute `groupRoot_{e+1}` (or epoch secret) with **pairwise** or **sender keys** so removed device IDs are not recipients. Until then, treat rekey as **honest-member coordination**, not theft resistance. |
| | **Workflow:** Durable leave journal (like terminal pairing actions); block local clear until PUT ack or user accepts “offline leave.” |
| | **Product:** Remove-member + rekey for N≥2; for N=2, dissolve group or force peer re-pair. |
| **Verify** | |
| | **Unit (must add — attack):** Given old root, open leave/remove membership envelope sealed under old root, extract seed, derive new root, open a task envelope sealed under new epoch → **succeeds today**; must **fail** after pairwise rekey. |
| | **Unit (existing):** old material cannot open new-epoch seal without seed (keep); with seed+old root, document follow-on. |
| | **Unit:** leave publish attempted for N=2 policy decision (either rekey peer or dissolve). |
| | **Integration:** leave while offline → peer eventually applies or surfaces “member may still have access.” |
| | **UI:** Remove lost iPhone control + confirmation copy. |

---

### C4 — Live invitation = full group admission

| Field | Value |
| --- | --- |
| **Status** | **Accepted product risk** — copy improved |
| **Severity** | High product risk if mis-marketed; Medium if copy is always shown |
| **What changed** | `inviteDetail` + `safetyCodeDetail` state invite theft and non-hacker-proof code. |
| **Still true** | Photo of QR / shared phrase within 15 minutes + Approve → full `groupRoot`. |
| **Mitigations** | Keep confirm; optional proximity later; no Release invite-on-disk. |
| **Verify** | Copy UI tests / accessibility IDs; `testInvitationSingleUseAndTTL` (extend with real single-use + expiry behavior, not only random inequality). |

---

### C5 — Custom unaudited composition

| Field | Value |
| --- | --- |
| **Status** | **Open** (unchanged) |
| **Severity** | High for production |
| **Mitigations** | Vectors, fuzz, external review before production claim. |
| **Verify** | Security suite + fuzz; group rekey/sign vectors published. |

---

## High findings (re-scored)

| ID | Status | Notes | Verify |
| --- | --- | --- | --- |
| **H1** Public relay admission | Open | Unchanged | Capacity tests + deploy checklist |
| **H2** No PFS for retained mailbox | Open | Rekey helps **new** epochs only for members who **don’t** learn seed; see R3a | Retention + rekey tests |
| **H3** Terminal journal capabilities | Open | Unchanged | Journal bounds + no logging |
| **H4** Relay metadata | Open | Unchanged | Metrics scrub tests |
| **H5** DEBUG invite files | Open / mitigated in source | Still `#if DEBUG`; Release test is weak | Strengthen Release compile check |

---

## Medium findings (re-scored)

| ID | Status | Notes |
| --- | --- | --- |
| **M1** Live N>2 crypto deferred | Open | Mailbox SoT still correct interim |
| **M2** Concurrent invites | Open | No single-flight lock found |
| **M3** Safety code marketing | **Improved** | Banlist + `safetyCodeDetail` |
| **M4** Large `SyncAppModel` | Open | Leave/membership added more paths |
| **M5** Pair→group bridge | Open | Still bridge from pair root |

---

## Attack paths (updated)

| Step | Action | First pass | After changes |
| ---: | --- | --- | --- |
| 1 | Steal live QR | Join if approved | Same; clearer warning |
| 2 | Get `groupRoot` | Yes | Yes |
| 3 | Decrypt B→C as A | Yes | **Yes (C1 accepted)** |
| 4 | Forge roster omit B (no real key) | Yes | **No** if B already has A’s pubkey (C2) |
| 4b | Forge via TOFU empty pubkey | N/A | **Maybe yes (R2a)** |
| 5 | Honest leave + peer online | Peer keeps old root | Peer **may** rekey if message delivered (R3b) |
| 6 | Stolen phone keeps Keychain, peers rekey | Full ongoing access | **Still full access if phone sees rekey seed (R3a)** |
| 7 | Remaining remove stolen (no UI) | N/A | **API exists, UI missing (R3d)** |

---

## Part scorecard (updated)

| Part | Vs relay | Vs co-member / theft | Biggest hole now |
| --- | --- | --- | --- |
| Invitation | N/A | Capability | Physical share |
| Pairing handshake | High | — | Unaudited composition |
| Group provision | By design ships root | Insider after join | Pubkeys not always bound |
| Group mailbox | High | **No co-member privacy** | Shared root (C1) |
| Membership gossip | High | **Signed** | TOFU empty key (R2a) |
| Leave / rekey | — | **Weak vs retained root** | Seed under old root (R3a) |
| Manage Sync UI | — | Honesty improved | No remove-member |
| Keychain | Good class | Unlocked = keys | Signing key in credential blob |
| Relay | Careful limits | N/A | Public deploy |

---

## Recommended test inventory (post-change)

### Keep green

1. `testSharedGroupRootCanDeriveForeignPairMailbox` (C1 baseline)  
2. `testMembershipSnapshotRejectsUnsignedOrForeignIssuer` (C2/C3 happy path)  
3. `testEpochRekeyInvalidatesOldMailboxMaterial` (epoch isolation **without** seed sharing)  
4. `testLeavePublishesRemoveAndDropsRoutes` (route map)  
5. UX: shared access + invite + safety strings present  

### Add next (priority)

1. **`testRekeySeedUnderOldRootAllowsFollower` (R3a)**  
   Seal leave under old root; third party with old root opens seed; derives new root; opens new-epoch task seal. Documents hole until pairwise rekey.

2. **`testMembershipRejectsClaimedKeyWhenKnownKeyEmpty` (R2a)**  
   After fix: reject. Until fix: `XCTExpectFailure` or baseline assert accept then invert.

3. **`testJoinProvisionBindsSigningPublicKeys`**  
   Joiner/issuer rosters non-empty pubkeys after commit.

4. **`testLeaveDurableOrExplicitOffline`**  
   Simulate PUT failure; credentials clear policy + peer outcome.

5. **`testTwoMemberLeavePolicy`**  
   N=2 leave either rekeys remaining or dissolves / requires re-pair.

6. **Real invitation single-use**  
   Same secret cannot complete two successful joins (app state, not only random secrets differ).

### Manual multi-sim

1. N=3 leave while peers online → remaining show 2 members + still sync (check).  
2. N=3 leave offline peer → document stuck roster until online.  
3. Stolen-phone drill: keep old app container, force rekey from remaining → **expect** old container can still follow rekey until R3a fixed; do not claim otherwise.  
4. Release build: no `debug-invite-*.txt`.

---

## Copy accuracy check (do now)

| Claim | Accurate? |
| --- | --- |
| Every linked iPhone can read/edit tasks | **Yes** |
| Anyone with live invite can join if approved | **Yes** |
| Safety code ≠ invite-theft defense | **Yes** |
| “Other phones drop this phone and rotate keys so it cannot read **new** edits” | **Only if** the left phone **discards** old root and **never** observes rekey seed. **False** for stolen phone that keeps Keychain and fetches membership. |
| Past data not remotely wiped | **Yes** |

**Suggested leave copy (safer):**  
“Tasks stay on this iPhone. Other phones remove you from the link and rotate keys for coordination. A phone that still has the old secret may keep reading until a stronger rekey ships. We cannot wipe data already on a phone.”

---

## Suggested engineering order (revised)

1. **Fix leave copy** to match R3a (minutes).  
2. **Bind signing pubkeys at join; reject empty-key TOFU** (R2a) — highest leverage crypto fix.  
3. **Durable leave / remove-member UI** (R3b, R3d).  
4. **Pairwise (or per-recipient sealed) epoch secret** so removed devices cannot read rekey (R3a real fix).  
5. External review + public relay hardening (C5, H1).

---

## Severity legend

| Level | Meaning |
| --- | --- |
| **Critical** | Breaks stated multi-device / theft model |
| **High** | Serious for production or empty-key/TOFU window |
| **Medium** | Design debt / ops / marketing |

---

## Out of scope (unchanged non-protections)

- Relay/network DoS  
- Full device compromise while unlocked  
- Deliberately shared live invite  
- Relay metadata (IP, timing, sizes, co-membership)  
- Edits that never reached the mailbox  
- Guaranteed background receive without push  
- Remote wipe of history already on a device  

---

## Changelog (re-analysis)

| Item | Delta |
| --- | --- |
| C1 | Still open by design; **disclosure done** |
| C2 | **Major fix**; residual TOFU |
| C3 | **Mechanism added**; **theft resistance not achieved** under shared root |
| C4 | Disclosure done |
| C5 / H* | Largely unchanged |
| M3 | Improved |
