# Multi-device group sync — Option C design plan

**Status:** vertical slice implemented on `agent/multi-device-group-sync` (Phases 1–5 POC)  
**Codename:** Group Sync v2  
**Supersedes product boundary:** Private Sync links exactly two iPhones  
**Related docs:** [PROTOCOL.md](PROTOCOL.md), [ARCHITECTURE.md](ARCHITECTURE.md), [RESEARCH.md](RESEARCH.md), [README.md](../README.md)

### Implementation notes (this branch)

| Area | Status |
| --- | --- |
| `GroupCredentials` + pair→group migration | Done |
| Product cap `maxDevices = 8` + multi-device copy | Done |
| Per-recipient `GroupMailbox` + multi-checkpoint | Done |
| Membership snapshot gossip (mailbox) | Done |
| Any-member invite while linked (`inviteToGroup`) | Done |
| Manage Sync UI (members, invite, leave) | Done |
| Relay N-socket rooms + fan-out | Done |
| Live multi-peer crypto for N>2 | Deferred (mailbox source of truth; N=2 pair live retained) |
| Pair→group silent upgrade of in-flight mailboxes | Re-link policy (P1) |

---

## 1. Purpose

Today Got Done Relay implements **Option pair**: one cryptographic pair root,
one remote peer, one host invitation ceremony, and directional A↔B live and
mailbox paths. The task replica already supports multi-origin last-writer-wins
(up to eight origins). Transport, credentials, and product copy do not.

This document specifies **Option C: shared group root + membership roster** —
the architecture required so that:

1. Many iPhones share **one logical link** (one group identity).
2. **Any linked member** can open **Manage Sync** and show a QR / phrase so
   another phone can join that same link.
3. Task state remains local-first, end-to-end encrypted, and accountless.

It is a plan and requirements baseline for implementation work, not a wire
spec frozen for shipping. Wire details marked **TBD** must be resolved in a
protocol PR before code lands.

---

## 2. Goals and non-goals

### 2.1 Goals

| ID | Goal |
| --- | --- |
| G1 | One group can include **2…N** devices (recommended product cap **N = 8**, aligned with `ReplicaLimits.maxOrigins`). |
| G2 | Every member holds the same **group identity** and can decrypt group task traffic for the current epoch. |
| G3 | Every member can **invite** a new phone into the group without unlinking. |
| G4 | Local edits remain durable on the editing phone first; peers receive them via live and/or mailbox paths. |
| G5 | Joiners with existing local tasks keep **Keep Both** / merge confirmation semantics. |
| G6 | Leave / lost-phone paths preserve local tasks on remaining phones. |
| G7 | Relay remains honest-but-curious: no plaintext tasks, no long-term group root in cleartext. |
| G8 | Consumer UI centers **Manage Sync** (members + invite QR), not host/joiner jargon after the group exists. |

### 2.2 Non-goals (v1 group)

| ID | Non-goal |
| --- | --- |
| NG1 | Unlimited device count or enterprise admin hierarchies. |
| NG2 | Cloud accounts, cross-user identity, or server-side recovery. |
| NG3 | Perfect forward secrecy for all historical mailbox ciphertext after a member is compromised (epoch rekey is best-effort v1; full PFS is later). |
| NG4 | Real-time multi-peer collaborative cursors or presence avatars. |
| NG5 | Automatic remote wipe of a lost phone. |
| NG6 | Cross-platform clients beyond iOS in the first group cut. |
| NG7 | In-place silent upgrade of existing pair links without an explicit re-link or migration step (migration may be a dedicated phase). |

### 2.3 Product delivery contract (unchanged unless noted)

- **Receive:** open-to-sync — peers see edits while Got Done is open, or the next time they open.
- **Send:** background-capable mailbox upload when iOS allows; durable retry on relaunch.
- **No push** for inbound until a separate receive epic.
- Pairing / join windows remain a single product TTL (today **15 minutes**).

---

## 3. Why Option C

### 3.1 Alternatives rejected

| Option | Summary | Why not |
| --- | --- | --- |
| **A — Mesh of pairwise pairs** | Each new phone pairs 1:1 with someone already linked | Not one link; requires forwarding or N−1 independent sync graphs; invite UX is ambiguous |
| **B — Permanent star host** | Only original host can invite; host is coordinator | Contradicts “any member shows QR”; host loss kills group management |
| **C — Shared group root + roster** | One group secret + explicit member set | Matches product; any member can issue joins; replica multi-origin already fits |

### 3.2 One-sentence architecture

> A group is a shared `groupRoot` (epoch-keyed), a signed or AEAD-bound
> membership roster of device IDs, per-device operation origins in the existing
> CRDT, mailbox fan-out to every other member, and optional live fan-out on a
> multi-socket group route — with **any member** able to run a short-lived
> **join-issuer** ceremony that provisions newcomers into that same group.

---

## 4. Current system constraints (as-built)

These are hard 2-device assumptions that Option C must replace or generalize.

| Layer | Today | Implication for Option C |
| --- | --- | --- |
| Product | `ProductSyncPolicy.maxDevices = 2` | Raise / rename to group max |
| Live relay | ≤2 sockets per route; third → `routeFull` | N-socket rooms or new routing model |
| Handshake | Role A/B; transcript binds exactly two device IDs | Member-indexed or group session model |
| Credentials | `PairCredentials`: one `remoteDeviceID`, one `role` | Roster + local role as member/issuer only |
| Mailbox | One outbound + one inbound; open requires single remote origin | Per-recipient routes or multi-ACK |
| Pairing | Host-only provision; `createPrivateSync` blocked while paired | Join-issuer path while linked |
| Invite | Derives a **new** pair root | Must join **existing** group, not mint a new pair |
| Replica | Multi-origin LWW; `maxOrigins = 8` | Keep; treat as device cap source of truth |
| Unlink | Clears pair; optional replacement via new pair | Leave group; remaining members rekey/roster update |

Primary hotspots:

- `GotDoneRelay/Sync/SyncAppModel.swift` (~4.4k lines, pair-centric loops)
- `GotDoneRelay/Security/SyncCrypto.swift`, `MailboxCrypto.swift`, `KeychainStore.swift`
- `GotDoneRelay/Transport/MailboxTransport.swift` (`PairMailbox`)
- `relay/gotdone_relay/server.py` (2-socket rooms)
- `docs/PROTOCOL.md` (pair completion v2)

---

## 5. Domain model

### 5.1 Entities

```text
Group
  groupID          16 bytes  (stable public-ish identifier for logs/UI keys)
  epoch            UInt64    (starts at 1; increments on rekey / membership change policy)
  groupRoot        32 bytes  (epoch secret; Keychain ThisDeviceOnly)
  members[]        ordered set of Member
  createdAt        local display only (optional)

Member
  deviceID         16 bytes  (install identity; same as replica origin)
  joinedEpoch      UInt64
  displayLabel     optional local nickname (not required for sync)
  status           active | leaving | removed

InviteCapability (ephemeral, not long-term credential)
  inviteSecret     16+ bytes random
  groupID          binds attempt to group
  issuerDeviceID
  expiresAt
  maxUses          v1: 1 successful join
  safety material  for confirmation UI
```

### 5.2 Credentials (device-local)

Replace or version-extend `PairCredentials`:

```text
GroupCredentials v1 (conceptual)
  version
  groupID
  epoch
  groupRoot
  localDeviceID
  members: [deviceID]          // active roster snapshot
  membershipGeneration        // monotonic roster version for conflict resolution
  // optional: per-peer sync checkpoints (see mailbox)
```

**Invariant:** After a successful join, every active member’s roster must
eventually converge to the same member set for a given
`membershipGeneration` (or equivalent CRDT/membership log).

### 5.3 Roles

| Role | Scope | Who |
| --- | --- | --- |
| **Member** | Permanent while linked | Every device in the roster |
| **Join issuer** | Only for one live invite attempt | Any member that opened Manage Sync → Invite |
| **Joiner** | Only during join ceremony | New device |

There is **no permanent host** after the founding event. Founding the first
two-device group may still use today’s ceremony shape; from three devices
onward (and ideally from two), invite is always “issuer + joiner.”

---

## 6. Requirements

### 6.1 Functional requirements

| ID | Requirement | Priority |
| --- | --- | --- |
| FR1 | A user can create a new empty group (founding invite) from an unpaired phone. | P0 |
| FR2 | A second phone can join via QR or 17-word phrase within the join window. | P0 |
| FR3 | After link, **any** member can open **Manage Sync** and show a new invite QR/phrase. | P0 |
| FR4 | A third (…Nth) phone joining via any member’s invite ends in the **same** `groupID` and task convergence. | P0 |
| FR5 | Local task create/edit/complete/delete on any member eventually appears on all other active members (open-to-sync receive). | P0 |
| FR6 | Concurrent edits use existing LWW + device-ID tie-break; no wall-clock authority. | P0 |
| FR7 | Joiner with local-only tasks gets merge preflight / Keep Both confirmation before irreversible install. | P0 |
| FR8 | Leave link keeps local tasks; device is removed from others’ roster (best effort when online). | P0 |
| FR9 | Product refuses new joins at `maxDevices` / `maxOrigins` with calm copy. | P0 |
| FR10 | Manage Sync lists known members (at least “This iPhone” + count or device labels). | P1 |
| FR11 | Two members may attempt invites concurrently; protocol defines deterministic acceptance or single-flight per group. | P1 |
| FR12 | Lost-phone guidance: remaining members rekey epoch and drop the missing device; no remote wipe. | P1 |
| FR13 | Background outbound mailbox flush continues for multi-recipient pending sets. | P1 |
| FR14 | Migration path from existing pair credentials to group credentials (or explicit “upgrade link”). | P2 |

### 6.2 Non-functional requirements

| ID | Requirement |
| --- | --- |
| NFR1 | Relay never sees task plaintext or `groupRoot`. |
| NFR2 | Mailbox envelopes remain independently authenticated; retries byte-identical where applicable. |
| NFR3 | Recipient ACKs only after durable local apply (per envelope / per recipient route). |
| NFR4 | Join window TTL single constant (reuse `ProductSyncPolicy.pairingWindowTimeToLive`). |
| NFR5 | Provisioning archive size limit remains enforced (today 280 KiB) until a snapshot epic raises it. |
| NFR6 | Consumer UI avoids host/joiner/ciphertext jargon; diagnostics stay DEBUG. |
| NFR7 | Unit tests cover crypto vectors, mailbox fan-out, membership commits; multi-simulator integration for N=3. |
| NFR8 | Failure modes preserve local tasks; erase is never the primary recovery CTA. |

### 6.3 Explicit acceptance scenarios

1. **Three-phone converge:** A founds, B joins, C joins via B’s QR; A creates task; B and C both eventually show it.
2. **Any-member invite:** After A+B linked, B shows QR; C joins; A never opened invite UI.
3. **Offline member:** A offline; B edits; A opens later and receives via mailbox.
4. **Local merge:** C has local tasks; joins A+B; Keep Both preview; all three share combined list.
5. **At capacity:** N members linked; invite shows “group full” without breaking sync.
6. **Leave:** C leaves; A and B keep syncing; C keeps tasks but no longer receives new ops.
7. **Issuer crash mid-join:** Joiner or issuer relaunches; join either completes idempotently or both return to safe linked/unpaired states without silent data loss.

---

## 7. Protocol design (Option C)

### 7.1 Cryptographic objects

```text
# Founding (group birth) — first successful 2-device join
groupRoot_0 = HKDF(sessionSecret, info: "com.gotdone.sync/group-root/v1", 32)
groupID     = HKDF(sessionSecret, info: "com.gotdone.sync/group-id/v1", 16)
epoch       = 1
members     = { founderDeviceID, firstJoinerDeviceID }

# Epoch rekey (membership change or explicit rotate)
groupRoot_{e+1} = HKDF(groupRoot_e || rekeySeed, info: "…/group-root-rekey/v1", 32)
epoch := e+1
```

Labels must be domain-separated from pair-era labels
(`pair-root`, `A-to-B`, etc.) so mixed-version peers fail closed.

### 7.2 Live transport

**v1 recommendation (pragmatic):**

1. Derive `groupLiveRoute = HKDF(groupRoot_epoch, info: "…/group-live-route/v1", 32)`.
2. Relay admits **up to N sockets** on that route (product cap).
3. Relay **fan-outs** binary frames to all other sockets on the route (not only one peer).
4. Application frames authenticate **sender device ID** + monotonic per-sender sequence under keys derived from `groupRoot_epoch` (or pairwise sessions — see open questions).

**Relay control plane changes:**

| Today | Group v1 |
| --- | --- |
| Max 2 sockets | Max N (config ≥ product maxDevices) |
| `peerReady` (binary peer present) | Optional `peersPresent` count or device-blind presence |
| Lone-peer wait 15 minutes destroys room | **Do not** expire multi-member rooms after short absence; only expire **join** waiting rooms |
| `routeFull` at 3 | `routeFull` at N+1 |

**Defer if needed:** Full multi-peer live can ship after mailbox multi-recipient if schedule requires it. Mailbox remains source of truth for durability.

### 7.3 Mailbox fan-out (source of truth)

Single-consumer ACK (today) cannot serve N members on one shared queue without multi-ACK.

**Chosen approach for Option C v1: per-recipient envelopes.**

```text
For local operation op from device S:
  for each active member M ≠ S:
    auth_SM  = HKDF(groupRoot_epoch, info: "…/mailbox-auth/" || S || M || "/v1", 32)
    route_SM = SHA256(UTF8("…/mailbox-route/v1") || auth_SM)
    PUT seal(op) on route_SM

Each member M:
  for each active member S ≠ M:
    FETCH/ACK inbound route_SM  (S → M)
  Accept origin == S only for that route
```

**Checkpoints:** Replace single `uploadedLocalSequence` with per-recipient
high-water marks, or a compact map `remoteDeviceID → uploadedThroughSequence`.

**Cost:** O(members − 1) PUTs per local op. Acceptable for N ≤ 8 and small task ops.

**Rejected for v1:** Shared broadcast queue with multi-ACK (requires larger relay redesign and membership-aware server state).

### 7.4 Membership log

Roster changes must not rely on “whoever last wrote Keychain.”

**v1 approach:** Append-only **membership operations** (separate from task ops or as a reserved namespace), gossiped like tasks:

| Op | Payload |
| --- | --- |
| `memberAdd` | deviceID, joinedEpoch, issuerDeviceID, inviteID |
| `memberRemove` | deviceID, reason (leave \| revoke), issuerDeviceID |
| `epochRekey` | newEpoch, commitment / wrapped keys as designed |

Conflict rules (draft):

- Adds for the same deviceID are idempotent.
- Remove wins over add for the same generation if authenticated by a still-active member (detail TBD).
- Devices never process task ops from removed members after remove is applied (policy: drop vs quarantine).

Membership must be authenticated under `groupRoot` / issuer credentials so the relay cannot inject members.

### 7.5 Join ceremony (any member issues)

```text
Issuer M (already in group)                 Joiner J
────────────────────────────                 ────────
Generate inviteSecret (128-bit)
Show QR / phrase (TTL = product window)
Register on inviteRoute(inviteSecret)

                                             Parse invite
                                             Register inviteRoute
          <---------- peerReady / hellos + safety code ---------->
M confirms safety code (or auto if product allows; v1: confirm)
Seal JoinProvision:
  - groupID, epoch, groupRoot (or wrapped)
  - roster snapshot
  - replica archive frontier (same size limits)
  - membershipGeneration
Mailbox PUT join-control chunks (like provision v2)
                                             Stage archive
                                             Keep Both if needed
                                             Ready
M persists memberAdd(J), may rekey policy
Commit + receipt (durable, restart-safe, pair-completion-style)
M gossips memberAdd to other members (mailbox + live)
                                             Active GroupCredentials
```

**Key differences from pair v2:**

| Pair v2 | Group join |
| --- | --- |
| New `pairRoot` every invite | Invite admits to **existing** `groupRoot`/epoch |
| Only unpaired host invites | **Any member** invites while linked |
| One remote peer forever | Roster grows |
| Host role permanent in credentials | Issuer role only for this attempt |

**Idempotency:** Reuse the durable state machine ideas from pairing completion v2 (persist before PUT; deterministic envelopes; terminal journal for receipt/abort).

### 7.6 Founding ceremony

First phone creates group skeleton locally (`groupID`, pending members = {self})
and shows founding invite. First joiner completes ceremony equivalent to
today’s pair, producing `GroupCredentials` with two members. Implementation
may:

- **Path F1:** Implement founding as a special-case of join (recommended long-term), or  
- **Path F2:** Keep pair v2 for 2-device only, then “upgrade to group” when third invite starts (faster interim, two code paths — discouraged past POC).

**Recommendation:** F1 single ceremony engine with `founding=true|false`.

### 7.7 Leave, revoke, lost phone

| User intent | Local effect | Group effect |
| --- | --- | --- |
| Leave and keep tasks | Clear `GroupCredentials`; keep replica | `memberRemove(self)` best-effort publish; others drop routes to self |
| Erase local POC | Clear credentials + tasks | Same remove best-effort |
| Lost phone (other) | N/A | Remaining members **Remove member** + **epoch rekey** so stolen device cannot decrypt **new** traffic |
| Lost phone returns | Must re-join via new invite | Treated as new join; old deviceID may be tombstoned |

v1 cannot cryptographically force a stolen device to forget old `groupRoot_epoch`
already in its Keychain; rekey limits **forward** damage for new epochs only.

### 7.8 Limits (proposed)

| Value | Proposal |
| --- | ---: |
| Max active members | 8 (`ReplicaLimits.maxOrigins`) |
| Concurrent live join attempts per group | 1 (single-flight) or 2 (if tested) |
| Invite TTL | 15 minutes |
| Invite uses | 1 success |
| Provisioning archive | 280 KiB (existing) |
| Version-vector origins | 8 |
| Mailbox routes per device | up to 7 outbound + 7 inbound at max N |

---

## 8. Application architecture

### 8.1 Module boundaries (target)

```text
SyncAppModel (orchestration only)
  ├── GroupSessionController      // live + reconciling multi-peer
  ├── GroupMailboxController      // fan-out PUT/FETCH/ACK + checkpoints
  ├── MembershipStore             // roster + generation
  ├── JoinIssuerController        // Manage Sync invite
  ├── JoinAcceptorController      // join existing group
  ├── TaskReplica                 // mostly unchanged
  └── CredentialStore             // GroupCredentials Keychain
```

Avoid growing `SyncAppModel` further as a monolith; group work is the forcing
function to split pair-era loops.

### 8.2 State machine (device)

```text
Unlinked
  → FoundingInvite | AcceptingJoin
  → Linked (members ≥ 2, or ≥ 1 local founding pending policy)
Linked
  → IssuingJoin (optional concurrent with sync)
  → Syncing (live and/or mailbox)
  → Repair (auth/crypto failure)
  → Leaving
  → Unlinked (tasks kept)
```

### 8.3 UI requirements

#### Manage Sync (linked)

Entry: dashboard menu / toolbar.

Contents:

1. **Status** — Linked · N iPhones · last update language from delivery contract  
2. **Members** — This iPhone; other deviceIDs shortened or nicknames  
3. **Invite** — primary button → full-screen QR + phrase + countdown + safety-code wait  
4. **Leave link** — Unlink and keep tasks  
5. **Remove a member** (P1) — for lost phone  
6. **Diagnostics** (DEBUG) — routes, RTT, mailbox errors  

Copy principles:

- Prefer “Private Sync” / “your linked iPhones” over host/joiner after link.  
- Invite sheet: “Anyone with this code can join **this** sync for 15 minutes.”  
- Capacity: “This sync is full (8 iPhones).”  
- Two-device boundary string removed or replaced with multi-device boundary.

#### Unlinked with local tasks

Keep Create / Join; add guidance that Create founds a **new** group; Join adds
this phone to an existing one (merge if needed).

### 8.4 Wire / versioning

- Introduce `pairingVersion` / `syncVersion` bump or `groupVersion = 1`.  
- Mixed pair-v2 and group-v1 peers must **fail closed** with upgrade copy.  
- Test vectors for new HKDF labels and frame AAD including `senderDeviceID`.

---

## 9. Threat model deltas

### 9.1 Still in scope (from pair protocol)

Honest-but-curious relay; active relay reordering/injection; stale invite
replay; duplicate ops; clock skew.

### 9.2 New / amplified risks

| Risk | Mitigation |
| --- | --- |
| Photographed invite admits attacker into whole group | Short TTL; single use; issuer confirmation; optional rate limit |
| Any member is as trusted as any other (no admin) | Product honesty; later admin optional |
| Stolen member device reads history for current epoch | Device passcode/Keychain; epoch rekey on revoke; ThisDeviceOnly |
| Malicious member injects ops | Ops accepted only from roster; cannot prevent insider abuse |
| Relay observes N co-members on live route | Same as today’s room co-membership, larger N |
| Mailbox route graph O(N²) traffic metadata | Accept for N≤8; document; consider padding later |
| Split brain dual invites | Single-flight membership commit; generation numbers |

### 9.3 Explicit non-protections

- No remote wipe.  
- No protection if user deliberately shares invite.  
- No guarantee offline members learn remove/rekey until they come online.  
- No account recovery if all devices lost.

---

## 10. Implementation plan

### Phase 0 — Product freeze (≤1 week)

**Deliverables:**

- This document accepted as working baseline.  
- Frozen decisions: N=8, any-member invite, per-recipient mailbox, join TTL, single-flight joins.  
- UX copy pack for Manage Sync / Invite / Full / Leave / Lost phone.  
- Out-of-scope list signed off (push, admin roles, PFS perfection).

**Exit criteria:** Written answers to open questions in §12 that are marked P0.

---

### Phase 1 — Data model & credentials (1–2 weeks)

**Work:**

- Define `GroupCredentials`, membership generation, Keychain encode/decode.  
- Migration stub: detect pair credentials → surface “upgrade” or dual-read.  
- Replace `maxDevices = 2` product constant with group max; keep enforcement.  
- Unit tests for credential round-trip and roster invariants.

**Exit criteria:** App stores group credentials for a simulated 2-member group without network change.

---

### Phase 2 — Membership ops + join ceremony vertical slice (3–5 weeks)

**Work:**

- Join-control mailbox stages generalized from provision/ready/commit/receipt.  
- Any linked member can mint invite bound to `groupID` (not new pair root).  
- Joiner installs roster + archive; issuer commits `memberAdd`.  
- Start with N=2 using new engine; prove restart safety (pair recovery tests ported).  
- Manage Sync → Invite UI wired for linked members.

**Exit criteria:**

- Two simulators complete founding + re-invite of a **replacement** third identity after leave is optional; at minimum **re-join ceremony** works for a cleared third simulator as member #3 **or** documented gate if mailbox fan-out still missing (prefer Phase 3 overlap).

**Note:** True 3-way task sync may still need Phase 3; Phase 2 must at least complete membership credential install on joiner.

---

### Phase 3 — Mailbox multi-recipient (3–5 weeks)

**Work:**

- `GroupMailbox`: seal/open per (sender, recipient).  
- Outbound drain uploads to all members; durable multi-checkpoint.  
- Inbound polls all peer routes; accept any roster origin.  
- Background flush handles pending multi-recipient sets.  
- Capacity / full-route errors with guided recovery.  
- Tests: 3 devices offline fan-out; partial peer failure; retry idempotency.

**Exit criteria:** A offline, B and C edit, A relaunches → converges without live sockets.

---

### Phase 4 — Live multi-socket room (1–3 weeks)

**Work:**

- Relay: N sockets, fan-out, routeFull at N+1, no aggressive multi-member TTL.  
- Client: group live route; multi-peer reconcile or broadcast ops.  
- Presence optional.  
- Fallback: mailbox-only still correct if live fails.

**Exit criteria:** Three open apps exchange live ops; kill one → others continue; killed returns via mailbox/live.

---

### Phase 5 — Manage Sync complete + leave/revoke (1–2 weeks)

**Work:**

- Member list, leave, remove lost member, rekey trigger.  
- Capacity and concurrent-invite UX.  
- Support summary multi-device strings.  
- Remove obsolete two-device-only consumer copy.

**Exit criteria:** UX acceptance scenarios §6.3 pass on simulators.

---

### Phase 6 — Migration, hardening, docs (2–4 weeks)

**Work:**

- Pair → group migration or forced re-link policy.  
- Protocol doc update (`PROTOCOL.md` group section).  
- Architecture diagrams.  
- Security review notes; threat model update.  
- Soak tests; fuzz roster edges; journal bounds.  
- Performance: N=8 synthetic mailbox put volume.

**Exit criteria:** Docs match code; pair-only path deprecated or compatibility matrix published.

---

### Suggested sequencing diagram

```text
Phase 0  Product freeze
   │
Phase 1  GroupCredentials + roster model
   │
   ├──────────────┐
Phase 2 Join/Issuer     Phase 3 Mailbox fan-out
   │                    │
   └────────┬───────────┘
            │
         Phase 4 Live N-room (optional lag)
            │
         Phase 5 Manage Sync polish
            │
         Phase 6 Migration + hardening
```

Phases 2 and 3 can overlap once credential shapes stabilize.

---

## 11. Effort estimate

| Scope | Calendar (1 senior mobile + protocol familiarity) |
| --- | --- |
| Option C POC (N≤8, mailbox-first, any-member QR, leave) | **~2–3 months** |
| + live multi-peer polish, migration, revoke/rekey, audit prep | **+1–2 months** |
| Production-hardened (PFS story, admin optional, push receive) | separate epics |

Largest cost centers, in order:

1. Mailbox multi-recipient + checkpoints  
2. Join ceremony multi-issuer durability  
3. Crypto/session generalization  
4. `SyncAppModel` decomposition  
5. Relay fan-out  

---

## 12. Open questions

Resolve before or during Phase 0/2. **P0** blocks implementation.

| # | Question | Priority | Notes |
| --- | --- | --- | --- |
| Q1 | Founding: single ceremony engine vs keep pair v2 for first link? | P0 | Prefer single engine |
| Q2 | Live crypto: group traffic key vs pairwise mesh sessions? | P0 | Group key simpler; pairwise better isolation |
| Q3 | Concurrent invites: reject second vs allow parallel joiners? | P0 | Recommend single-flight v1 |
| Q4 | Must issuer stay online for entire join, or fully mailbox-mediated? | P0 | Mailbox-mediated matches pair v2 resilience |
| Q5 | On `memberRemove`, rekey always or only on “lost/stolen”? | P1 | Recommend always rekey |
| Q6 | Device display names in-group or local-only nicknames? | P1 | Local-only simpler |
| Q7 | Migrate existing pair users automatically or ask to re-link? | P1 | Re-link safer for POC |
| Q8 | Raise `maxOrigins` above 8 later? | P2 | Requires archive validation + UX |
| Q9 | Should membership live inside `TaskReplica` archive or side log? | P0 | Side log reduces task schema churn |
| Q10 | Relay multi-ACK broadcast mailbox as future optimization? | P2 | Not v1 |

---

## 13. Testing strategy

### 13.1 Unit

- HKDF labels and mailbox route derivation for all ordered pairs in a roster.  
- Seal/open rejects wrong recipient and removed members.  
- Membership generation monotonicity; idempotent `memberAdd`.  
- Checkpoint map survives process kill.  
- Join control deterministic retry vectors (port pair recovery suite).  

### 13.2 Integration (simulators)

| Suite | Devices | Focus |
| --- | --- | --- |
| Founding | 2 | Create + join + task converge |
| Any-issuer | 3 | B invites C; A receives memberAdd + tasks |
| Offline fan-out | 3 | Mailbox only |
| Merge join | 2→3 | Keep Both preflight |
| Capacity | 8 | Ninth invite refused |
| Leave | 3 | C leaves; A/B continue |
| Live + mailbox hybrid | 3 | One backgrounded |

### 13.3 Regression

- Existing pair tests either migrate to group N=2 or run behind compatibility flag until Phase 6.  
- Do not delete pair recovery coverage until group join proves equal restart safety.

---

## 14. Documentation deliverables (when implementing)

| Doc | Change |
| --- | --- |
| `docs/PROTOCOL.md` | New “Group sync” section; version bump; vectors |
| `docs/ARCHITECTURE.md` | N-device diagrams; Manage Sync flow |
| `docs/RESEARCH.md` | Group messaging / sender keys references if adopted |
| `docs/RESULTS.md` | Multi-simulator evidence |
| `README.md` | Product boundary; how to run 3 sims |
| `ProductSyncPolicy.swift` | Strings: multi-device boundary, Manage Sync |

---

## 15. UI copy draft (consumer)

| Surface | Draft |
| --- | --- |
| Manage Sync title | Manage Sync |
| Status | Linked with N iPhones. Edits save here first; others see them when they open Got Done. |
| Invite button | Invite another iPhone |
| Invite detail | Show this code on phones you trust. Valid for 15 minutes. They join **this** sync. |
| Group full | This sync already has 8 iPhones. Leave a phone or start a new sync. |
| Leave | Leave sync and keep tasks |
| Leave detail | Tasks stay on this iPhone. Other phones keep syncing with each other. |
| Lost phone | Remove a lost iPhone | Stops new updates from that phone after others refresh. Create a new invite if you replace it. |
| Join with locals | Your tasks stay on this iPhone until you confirm how to combine lists. |

---

## 16. Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `SyncAppModel` rewrite slips | Schedule | Split controllers early (Phase 1–2) |
| Pair + group dual stack forever | Bugs | Hard deprecate pair after group N=2 parity |
| O(N²) mailbox puts drain battery | UX | Batch envelopes; backoff; N≤8 |
| Incomplete rekey story marketed as secure revoke | Security | Honest copy; epoch rekey; no “wipe remote” claim |
| Join state machine regressions | Data/link loss | Port terminal journal + recovery tests first |
| Relay presence TTL kills rooms | Flaky multi-device | Separate join wait TTL from group live TTL |

---

## 17. Definition of done (Option C v1)

Option C v1 is **done** when all of the following hold:

1. **N ≥ 3** simulators share one `groupID` and converge on task edits without unlinking.  
2. **Any** of the linked simulators can show an invite QR that admits a new member into that same group (until full).  
3. Manage Sync is the primary linked management surface (invite, members, leave).  
4. Offline mailbox path delivers ops to all other members with durable multi-recipient checkpoints.  
5. Leave keeps tasks; remaining members continue.  
6. Protocol and architecture docs describe group behavior; product no longer claims two-device-only.  
7. Automated tests cover founding, any-issuer join, offline fan-out, and capacity.  

Live multi-peer and automatic pair→group migration may trail slightly if explicitly deferred in Phase 0, but must be tracked as follow-ons rather than silent gaps.

---

## 18. Appendix A — Mapping from current types

| Current | Group Option C |
| --- | --- |
| `PairCredentials` | `GroupCredentials` |
| `remoteDeviceID` | `members[]` minus self |
| `DeviceRole.host/joiner` | Permanent roles removed; transient issuer/joiner |
| `PairMailbox` | `GroupMailbox` |
| `createPrivateSync()` | `createGroup()` / founding invite |
| `createPrivateSync` while paired (blocked) | `beginGroupInvite()` while linked |
| `unlinkAndKeepTasks()` | `leaveGroupAndKeepTasks()` + membership remove |
| `syncRoute` from pairRoot | `groupLiveRoute` from groupRoot_epoch |
| A-to-B / B-to-A mailbox | Per ordered pair (S→M) routes |
| `ProductSyncPolicy.maxDevices = 2` | `maxDevices = ReplicaLimits.maxOrigins` (8) |
| `twoDeviceBoundary` string | Multi-device boundary string |

---

## 19. Appendix B — Manage Sync information architecture

```text
Dashboard (linked)
  └─ Menu
       ├─ Manage Sync          ← primary
       │    ├─ Status summary
       │    ├─ Member list
       │    ├─ [Invite another iPhone] → Invite sheet (QR, phrase, TTL)
       │    ├─ [Remove lost iPhone]    → confirmation → rekey
       │    └─ [Leave sync…]           → keep tasks
       ├─ Sync status (optional collapsed)
       ├─ Diagnostics (DEBUG)
       └─ Erase local data…
```

Invite sheet reuses pairing visual language (QR, phrase, countdown, safety code)
but **title/copy** say “Invite to this sync,” not “Create Private Sync.”

---

## 20. Appendix C — Reference decision log

| Decision | Choice | Rationale |
| --- | --- | --- |
| Topology | Shared group root + roster | Matches one-link product; any-member invite |
| Device cap | 8 | Align with existing `maxOrigins` |
| Mailbox | Per-recipient copies | Reuses single-consumer ACK semantics |
| Live | N-socket fan-out (phase after mailbox) | Simpler than mesh handshakes for POC |
| Invite authority | Any active member | Stated product requirement |
| Permanent host | None | Host loss must not strand management |
| ACK model | Still post-durable-apply | Core security invariant |
| Account recovery | None | Accountless product |

---

## 21. Next actions

1. Review and resolve P0 open questions (§12).  
2. Approve Phase 0 product freeze.  
3. Open implementation PR plan starting at Phase 1 (`GroupCredentials` + tests).  
4. Keep this document updated as wire details leave **TBD** state; protocol truth eventually lives in `PROTOCOL.md`.
