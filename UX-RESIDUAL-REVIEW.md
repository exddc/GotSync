# Residual code review (skill: my-code-review)

**Branch:** `agent/improve-sync-reliability` vs `main`  
**Base:** no `develop` — used `main`  
**Stance:** Senior Developer, Lead Engineer, Architect — strict, by the book  
**Note:** Planning artifact only; does not change product code by itself.

**Important:** Wave-1/2 backlog D1–D20 is largely **implemented** (`660c822`, `a5c9fb9`: `ProductSyncPolicy`, `UserPairingPresentation`, `KeepBothPreview`, BG mailbox scheduler, `UXSurfaceTests`, open-to-sync copy). This review does **not** re-open that list as if unfinished. It grades residual risk against the original UX complaints.

See also: [`UX-IMPROVEMENT-BACKLOG.md`](UX-IMPROVEMENT-BACKLOG.md) for the original D1–D20 list.

---

## What already passes (do not re-do)

| Original complaint | Evidence of fix | Grade |
| --- | --- | --- |
| Engineering jargon in consumer UI | `ConsumerCopyBanlist` + `UXSurfaceTests` | **Pass** |
| 120s invitation | `ProductSyncPolicy.pairingWindowTimeToLive` = 15 min, single product number | **Pass** |
| Protocol-shaped pairing UI | `UserPairingPresentation` / steps + VoiceOver actor | **Pass** |
| “Choose how to recover” | “Combine task lists?” | **Pass** |
| Babysit “keep app open” on save | Notices use outcome + auto-retry language | **Pass** |
| False set-and-forget receive | Documented **open-to-sync receive** in policy/README | **Pass (honest POC)** |
| No success / arrival / confidence | Celebration, inbound cue, “Updated just now” | **Pass** |
| Keep Both opaque | `KeepBothPreview` + auto-continue additive | **Pass** |
| Diagnostics always visible | DEBUG Diagnostics submenu | **Pass** |
| Support “is it broken?” | `SupportStatusSummary` sheet | **Pass** |

---

## Annotations still open (strict)

### Senior Software Developer

| ID | Severity | Annotation | Passing grade |
| --- | --- | --- | --- |
| **S-R1** | **High** | D2 is only **partially** proven. `SystemBackgroundMailboxScheduler` is best-effort (`BGProcessingTask` + 15s earliest begin). No automated proof of: local edit → kill before mailbox ACK → relaunch → peer receives. | Integration/unit path that simulates incomplete PUT, process death, relaunch, and peer apply; assert no “keep open” copy in happy path (already mostly true). |
| **S-R2** | **Medium** | Pairing still says **keep both apps open** (`pairingKeepOpenSummary`). Correct for live handshake, but reintroduces babysitting at the highest-friction moment. | Measure or design: finalization-safe leave where protocol allows; copy only when cancel/resume rules require both online. |
| **S-R3** | **Medium** | `statusTitle` when paired often equals celebration string (“Private Sync is on”) even for routine synced state — fine, but healthy path may still over-narrate if status chrome is shown outside support sheet. | Confirm healthy dashboard never shows permanent status card; only celebration + transient cues (code path audit + screenshot test). |
| **S-R4** | **Low** | `SyncAppModel` still owns presentation, transport, recovery — hard to change copy without touching the engine. | Keep presentation builders pure (already started); stop growing model with new string branches. |

### Lead Engineer

| ID | Severity | Annotation | Passing grade |
| --- | --- | --- | --- |
| **L-R1** | **High** | **Asymmetric unlink peer story incomplete.** Backlog itself marks peer “link ended” as PARTIAL (local CTA + repair, not a dedicated peer event). Other phone may still look “linked” until something fails. | Explicit peer-visible link-end (control message or mailbox tombstone) + UI “Link ended — tasks kept” without user diagnosis; recovery tests for one-side unlink. |
| **L-R2** | **High** | **Receive remains open-to-sync.** Original wonder bar (“tasks simply appear”) is **not** met under force-quit. Decision A is honest; wonder is still blocked. | Either accept forever and stop marketing magic, **or** ship push/BGAppRefresh receive with a proof on two devices. |
| **L-R3** | **Medium** | BG flush scheduling failures are swallowed (`catch` empty). Operators/support cannot tell “scheduled” vs “never scheduled.” | Log/metric or support-sheet field: last successful upload, last schedule attempt, pending count (no jargon). |
| **L-R4** | **Medium** | Capacity / archive walls fixed in copy; **no guided trim** UX — “trim tasks” without tools is a support ticket. | In-app guidance: count/size pressure, or “reset link keeps tasks” as single primary CTA when over limit. |
| **L-R5** | **Low** | Error taxonomy improved (expired / cancelled / unreachable) — keep expanding for remaining raw `.relay(code)` leaks if any remain in UI. | Grep consumer surfaces for raw relay codes; zero hits outside DEBUG. |

### Software Architect

| ID | Severity | Annotation | Passing grade |
| --- | --- | --- | --- |
| **A-R1** | **Critical** (if product claims “setup and forget”) | Product contract is **hybrid**: background send + open-to-sync receive. That is coherent as a POC, **incoherent** as Apple/Linear-grade wonder. | Explicit product tier: (1) ship as open-to-sync demo, or (2) new epic for true async receive. No third “sort of magic” middle. |
| **A-R2** | **High** | Two-device + no account recovery is documented; **lost-phone / untrusted-joiner** story still incomplete (revoke other device, wipe remote, re-key). | Threat/UX story: unlink = stop *this* phone; replacement = new invitation; lost phone = assume compromise → new pair both sides. In-app copy for each. |
| **A-R3** | **Medium** | Pairing protocol still multi-stage under a presentation veneer. Finalization lock + resume is strong; **first-time pairing still requires co-presence**. | Document “pairing is intentional, sync is quiet” as the UX law; don’t pretend pairing is AirDrop-one-tap until protocol allows. |
| **A-R4** | **Low** | Presentation layer exists but is not fully the only path (`statusTitle` special-cases paired mailbox states separately from builder). | Single presentation function for all phases, or document intentional dual path. |

### Compress / cut

| Cut / split | Why |
| --- | --- |
| Collapse paired `statusTitle`/`statusDetail` special cases into one `PairedSurfacePresentation` next to `UserPairingPresentation` | Avoids dual string systems |
| Keep `ProductSyncPolicy` as single source for TTL, durations, delivery sentences | Already good — do not fork strings in views |
| Do not add more banners | Wonder dies when chrome returns; prefer cues already shipped |

---

## Ranked residual severity

1. **A-R1 / L-R2** — Wonder vs open-to-sync honesty (strategic fork)
2. **L-R1** — Asymmetric unlink peer visibility
3. **S-R1** — Prove durable outbound across kill/relaunch
4. **S-R2 / A-R3** — Pairing still co-presence babysitting
5. **L-R3 / L-R4** — Supportability of BG schedule + capacity guidance
6. **A-R2** — Lost/replacement phone security story
7. **S-R3 / S-R4 / A-R4 / L-R5** — Presentation hygiene

---

## Residual doing list (fixes remaining complaints)

Original D1–D20: treat as **closed** except partials called out below.

### P0 — Truth vs wonder (product fork)

- [ ] **R1. Close the product fork in writing and UI chrome**  
  - Either: *“Open Got Done on each phone to catch up”* as permanent product truth (already mostly encoded), **or** open epic for push/BG receive.  
  - **Pass:** Marketing, empty state, support sheet, and README tell the **same** one-sentence receive story; no residual “it just appears” implication when peer is force-quit.

- [ ] **R2. Optional epic only if wonder is required: silent receive**  
  - Push or BGAppRefresh poll with two-device proof.  
  - **Pass:** Edit on A while B force-quit → B receives without manual open (or document why iOS forbids and keep R1).

### P0 — Reliability proofs / unlink

- [ ] **R3. Kill/relaunch outbound integration proof (complete D2)**  
  - Test: commit local op → interrupt before ACK → relaunch → peer applies.  
  - **Pass:** Automated test or scripted RESULTS.md proof; pending count survives; no user babysit copy.

- [ ] **R4. Peer-visible link end (complete D13)**  
  - After unlink on A, B shows “Link ended — tasks kept” without waiting for a failed sync.  
  - **Pass:** Pairing/recovery test for one-side unlink; both sides CTAs: create replacement / re-pair; tasks preserved.

### P1 — Pairing friction residual

- [ ] **R5. Pairing “keep both open” only when required**  
  - When finalization is durable and cancel locked, reaffirm “safe to leave.”  
  - **Pass:** Copy matrix: pre-handshake vs post-approval; UXSurfaceTests for both.

- [ ] **R6. Host-away joiner empathy**  
  - Joiner waiting on host approve: clearer “Ask them to approve the matching code on the main iPhone” + optional local timeout guidance.  
  - **Pass:** No dead “spinning forever” without next step after N minutes.

### P1 — Support & capacity

- [ ] **R7. Support sheet: last upload / pending / schedule health**  
  - Surface last successful mailbox store + pending count (already partial); add “upload waiting for background” if pending > 0 and backgrounded.  
  - **Pass:** Answers “did my edit leave this phone?” without DEBUG menu.

- [ ] **R8. Capacity guidance beyond “trim tasks”**  
  - Primary CTA when full: reset link / keep tasks; optional show rough size pressure.  
  - **Pass:** Mailbox-full path never points at Erase as peer of Retry.

### P2 — Security / lifecycle story

- [ ] **R9. Lost-phone / replacement copy pack**  
  - Three short paths in support sheet: replace phone, unlink this phone, I no longer trust the other phone (create new link on both).  
  - **Pass:** User never only sees Erase as the lifecycle tool.

- [ ] **R10. Presentation consolidation**  
  - One paired presentation builder; banlist tests cover it.  
  - **Pass:** No dual `statusTitle`/`UserPairingPresentation` divergence bugs.

### P2 — Wonder polish (only after R1 honesty)

- [ ] **R11. Arrival cue only for remote origins**  
  - Ensure local edits don’t flash “from your other iPhone.”  
  - **Pass:** Unit/UI test remote vs local apply.

- [ ] **R12. Reduce permanent encryption footnotes on every list footer**  
  - Trust once at link-complete + support; quiet list afterward.  
  - **Pass:** Healthy list feels like a todo app, not a crypto demo (DEBUG can keep footer).

---

## Explicitly still out of scope

| Item | Why |
| --- | --- |
| General todo Undo | Wrong product; keep delete grace only |
| Multi-device family sync | Separate architecture |
| Full crypto audit | Security program |
| Removing DEBUG diagnostics | Prototype needs them |

---

## Lead / Architect bottom line

**Presentation complaints from the multi-expert UX review are largely addressed.** The remaining failures are structural:

1. **Receive is still open-to-sync** → wonder incomplete by design until R1/R2.
2. **Unlink is still asymmetric** → support tickets until R4.
3. **Background send is implemented but under-proven** → R3 before claiming D2 fully closed.
4. **Pairing still needs co-presence** → acceptable if named; not “setup and forget” until after first successful link.

**Minimum residual bar to close the original UX review for a honest POC:**

| Priority | Doings |
| --- | --- |
| Must | **R1**, **R3**, **R4** |
| Should | **R5**, **R7**, **R8**, **R9** |
| Wonder track | **R2**, **R11**, **R12** |

**Minimum bar for true set-and-forget wonder:** R2 + R3 + R4, then stop teaching users to open the app for catch-up.

---

## Context notes (from original UX review)

- Engineering vocabulary in a prototype is acceptable when quarantined (Diagnostics / DEBUG).
- A todo app does not need general Undo; the 5s delete grace is a sync-safety pattern and should remain.
- Target feeling: *I linked them once. Now tasks simply appear on the other phone. I never think about sync.*
- The enemy of that feeling is recruiting the user as a sync operator (keep apps open, beat the clock, babysit uploads, reopen to receive).
- After D1–D20, the remaining enemy is **asymmetric state**, **unproven background send**, and **open-to-sync receive** vs wonder claims.
