# Code review: UX findings → improvement backlog

**Scope:** `agent/improve-sync-reliability` vs `main` (no `develop`), reviewed against the multi-expert UX analysis.  
**Skill stance:** Senior Developer, Lead Engineer, Architect — strict, by the book.  
**Note:** This document is a planning artifact; it does not change product code by itself.

---

## What the branch already fixed (credit before complaints)

| Area | Evidence |
| --- | --- |
| Quiet healthy dashboard | `syncNotice` only for saving / retry / repair |
| Pairing durability | finalization states, cancel until commit lock, resume after restart |
| Keep Both preflight | merge candidate validation before ready |
| Local tasks after unlink | dashboard + join from local history |
| Phrase validation before state | `JoinSyncSheet` |
| Invitation expiry UI | countdown + VoiceOver |
| Delete grace (sync-safe) | 5s pre-commit Undo — **not** general undo; keep |

Those are real product wins. The remaining list is what still fails a ship bar for *wonder / setup-and-forget*.

---

## Annotations by role (strict)

### Senior Software Developer

| ID | Severity | Annotation | Passing grade |
| --- | --- | --- | --- |
| S1 | **High** | Invitation TTL hard-coded at **120s** in multiple places (`createPrivateSync`, pending pair expiry). Physical QR + 17-word phrase cannot reliably complete. | Single named constant (e.g. ≥10 min); countdown UI; tests for expiry boundary; phrase-entry path still valid at T−30s. |
| S2 | **High** | User-facing `statusDetail` / notices still leak protocol: *ciphertext*, *version vectors*, *durably applies*, *Keep Got Done open…*. | Prod-facing strings map to outcomes only; engineering strings only behind Diagnostics / `#if DEBUG`. Unit tests assert banned tokens absent from UI surface APIs. |
| S3 | **Medium** | Pairing UI mirrors internal phases (`waitingForProvision`, `readyMayHaveBeenStored`, …) instead of a 3-step user model. | `userPairingStep` (or similar) collapses phases → *Waiting for other phone / Waiting for you / Finishing*; VoiceOver announces owner of the wait. |
| S4 | **Medium** | Merge conflict title **“Choose how to recover”** treats normal Keep Both as disaster recovery. | Title/copy = combine lists; confirmation shows counts (shared / local-only / will-duplicate); cancel leaves replica unchanged (already true — keep tested). |
| S5 | **Medium** | Saving/retry banners teach babysitting; no progressive disclosure of *how long / what happens if I leave*. | Notices only after N seconds pending or failed upload; copy never requires “keep app open” unless background flush actually cannot finish; if it can, say *Saved on this iPhone*. |
| S6 | **Low** | Menu always shows RTT / relay / mailbox hosts — fine for POC, wrong default for consumers. | Diagnostics section gated; default menu = Unlink / Erase only. |

### Lead Engineer

| ID | Severity | Annotation | Passing grade |
| --- | --- | --- | --- |
| L1 | **Critical** (prod product bar) | Offline receive is **foreground-poll only**; no push. Day-2 promise (“on your devices”) is false under force-quit. | Either (A) document product as open-to-sync + truthful empty/footer copy, **or** (B) push/BG receive path with integration proof that B receives without manual open after A edited. |
| L2 | **High** | Outbound can be lost if app dies before mailbox PUT; UI says keep open but iOS will kill anyway. | Background task path verified for in-flight upload; if incomplete, durable “pending send” survives relaunch and retries without user instruction; test: kill after local commit, relaunch, peer eventually receives. |
| L3 | **High** | Asymmetric unlink / repair: one side “not syncing,” other may still think paired. | Unlink publishes terminal forget; peer shows calm “Link ended — tasks kept”; both sides get same recovery CTA; recovery tests cover one-side unlink. |
| L4 | **Medium** | Keep Both has no outcome model in UI; support will get “I have duplicates.” | Preflight DTO: `reusedCount`, `localOnlyCount`, `conflictCount`; UI preview; optional future: prefer-host / prefer-local (can defer). |
| L5 | **Medium** | Hard limits (280 KiB, mailbox capacity, recovery journal full) surface as scary walls next to Erase. | Capacity errors: tasks first, one primary CTA, Erase not adjacent as peer action; guided “trim or reset link” copy. |
| L6 | **Low** | `lastSyncedAt` exists but is unused in UI — no confidence signal. | Optional subtle “Updated just now” that auto-hides; never a permanent traffic light. |

### Software Architect

| ID | Severity | Annotation | Passing grade |
| --- | --- | --- | --- |
| A1 | **Critical** (if claiming set-and-forget) | Delivery SLAs not productized: live + mailbox + poll intervals are implementation details, not UX contracts. | Written UX contract: max pairing wall-time, invitation TTL, “edit reaches mailbox before background expiry,” “receive latency when peer opens / when push exists.” Code + docs + tests align. |
| A2 | **High** | Pairing protocol v2 is multi-stage; UI is a state dump of the protocol. Architecture needs a **presentation layer** over finalization states. | Pure mapping function protocol state → user step + blocking actor + cancel allowed; no raw finalization enum names in copy. |
| A3 | **High** | Two-device-only + no account recovery is a product boundary, not a bug — but UX never ends the story (replacement phone, lost phone). | Explicit flows: *Replace this phone*, *Unlink and keep tasks*; welcome/local dashboard CTAs match; no dead ends that only say Erase. |
| A4 | **Medium** | Success is silent; failure is verbose — inverted emotional architecture. | Link-complete transition + optional inbound arrival cue; healthy path stays quiet after that. |
| A5 | **Low** | Prototype engineering surface mixed into consumer navigation (⋯ menu metrics). | Split `SyncDiagnostics` from product chrome; architecturally keep one `SyncAppModel` but two presentation policies (demo vs consumer). |

---

## Ranked severity (merged)

1. **Critical** — L1 / A1: day-2 delivery contract (open-to-sync honesty **or** real background/push)
2. **Critical-for-wonder** — L2: durable outbound without babysitting
3. **High** — S1: invitation TTL
4. **High** — S2 / A2: outcome language + user pairing steps
5. **High** — L3 / A3: unlink / replace-phone story
6. **Medium** — S3–S5, L4–L5, A4: ceremony collapse, merge preview, notice policy, success beat
7. **Low** — S6, L6, A5: diagnostics, subtle last-sync, polish

---

## Doing list (improvements to fix the complaints)

Ordered for impact and dependency. Each item is a **doing** with acceptance criteria (passing grade).

### P0 — Stop false promises / stop babysitting

- [ ] **D1. Product delivery contract (decide and encode)**  
  - Decide: *Open-to-sync POC* vs *Set-and-forget*.  
  - **Pass:** README + in-app empty/footer/retry copy match the decision; no claim that edits appear while peer is force-quit unless push/BG exists.

- [ ] **D2. Durable outbound without “keep app open”**  
  - Finish mailbox upload in background task; retry on next launch if incomplete.  
  - **Pass:** Local edit → kill app before ACK → relaunch → peer receives; UI does not say “keep open” for the happy path.

- [ ] **D3. Inbound path honesty or push**  
  - If no push: clear “appears when the other iPhone opens Got Done.”  
  - If push: silent receive while backgrounded (scoped POC ok).  
  - **Pass:** Support script can answer “when does the other phone see it?” in one sentence that matches telemetry/tests.

### P1 — Pairing: high completion, low panic

- [ ] **D4. Raise invitation TTL + single constant**  
  - e.g. 10–15 minutes; regenerate remains available.  
  - **Pass:** One constant/config; UI countdown; tests; realistic phrase entry does not expire mid-type in manual QA.

- [ ] **D5. User pairing steps (presentation layer)**  
  - Map internal finalization → 3 user steps + blocking actor (“you” / “other phone” / “background”).  
  - **Pass:** No raw recovery-engineer titles; VoiceOver announces who must act; cancel rules unchanged and tested.

- [ ] **D6. Link-complete success beat**  
  - Short confirmation → dashboard; light haptic.  
  - **Pass:** After commit/receipt, user sees *Private Sync is on* (or equivalent) once; not a silent phase flip only.

- [ ] **D7. Join default = QR; phrase as fallback**  
  - Already partial; ensure camera-denied path is excellent.  
  - **Pass:** First-time joiner can complete without typing 17 words when camera works.

### P1 — Copy / trust surface (quick wins, high ticket reduction)

- [ ] **D8. Ban protocol jargon from consumer strings**  
  - Strip ciphertext / version vectors / durably applies / RTT from default UI.  
  - **Pass:** Grep/tests on `statusTitle`/`statusDetail`/`syncNotice`/welcome; Diagnostics retains detail for prototype.

- [ ] **D9. Rewrite saving / retry / repair notices**  
  - Tasks safe first; one CTA; no babysit language unless D2 incomplete.  
  - **Pass:** Capacity/unavailable copy matches MailboxTests intent but user-outcome wording; Erase not primary peer of Retry.

- [ ] **D10. Rename merge path away from “recover”**  
  - “Combine task lists?” + clearer dialog.  
  - **Pass:** Title no longer implies failure; cancel still leaves main replica untouched.

### P2 — Conflicts, unlink, replacement phone

- [ ] **D11. Keep Both outcome preview**  
  - Show reused / local-only / conflict (may appear twice) counts before confirm.  
  - **Pass:** UI bound to validated candidate stats; dialog matches actual install; tests for count accuracy.

- [ ] **D12. Auto-continue when merge is additive-only**  
  - Optional: skip dialog if `conflictCount == 0`.  
  - **Pass:** Local-only add + identical shared set links without extra tap; true conflicts still confirm.

- [ ] **D13. Unlink / replace-phone flow**  
  - Calm copy; peer-side “link ended”; host CTA “Create Private Sync for replacement.”  
  - **Pass:** One-side unlink leaves both sides with clear next step; tasks preserved; no “erase to fix” as first action.

- [ ] **D14. Recovery journal full / damaged**  
  - “Keep tasks · reset link” as primary; never lead with erase.  
  - **Pass:** `pairingRecoveryResetRequired` UI matches; tests already exist — add UI copy assertions.

### P2 — Wonder (after reliability)

- [ ] **D15. Inbound task arrival cue**  
  - Soft insert / brief “from your other iPhone” (reduce motion safe).  
  - **Pass:** New remote task is perceptible without a permanent banner.

- [ ] **D16. Subtle confidence (optional, auto-hide)**  
  - Use `lastSyncedAt` sparingly after activity.  
  - **Pass:** Healthy idle dashboard remains quiet (no permanent status pill).

- [ ] **D17. Gate diagnostics in ⋯ menu**  
  - RTT, hosts, last mailbox error under Diagnostics.  
  - **Pass:** Default menu is Unlink / Erase only for consumer mode.

### P3 — Limits & supportability (prod hardening)

- [ ] **D18. Capacity / archive size guided recovery**  
  - Explain limit; suggest unlink/reset link; no panic erase.  
  - **Pass:** 280 KiB / mailbox full paths have unique actionable copy + tests.

- [ ] **D19. Explicit two-device product boundary**  
  - Copy: two iPhones; no third device yet.  
  - **Pass:** User never discovers limit only via cryptic relay errors.

- [ ] **D20. Support self-serve status sheet**  
  - “Link OK · last update · pending sends · other phone not required online for local edit.”  
  - **Pass:** One screen answers 80% of “is it broken?” without engineering terms.

---

## Explicitly out of scope

| Not a doing | Why |
| --- | --- |
| General multi-step Undo for todos | Wrong product model; delete grace is enough |
| Removing all engineering visibility in this POC | Keep under Diagnostics / DEBUG |
| Full multi-device family sync | Architecture scope expansion — separate design |
| Cryptographic audit | Security program, not UX ticket |

---

## Suggested implementation waves

| Wave | Doings | Outcome |
| --- | --- | --- |
| **Wave 1 — Copy & ceremony (days)** | D4, D5, D8, D9, D10, D17 | Fewer pairing aborts and angry tickets; still honest POC |
| **Wave 2 — Reliability UX (week)** | D1, D2, D3, D13, D14 | Stop babysitting; clear delivery contract |
| **Wave 3 — Merge & replacement** | D11, D12, D6, D18, D19 | Fear-free join / phone replace |
| **Wave 4 — Delight** | D15, D16, D20 | Wonder without reintroducing chrome |

---

## Lead / Architect summary

The branch is a **strong reliability and recovery engine** with a **presentation layer that still exposes the engine**. Shipping as a concept demo is fine. Shipping as *setup and forget* fails until **D1–D3** and **D4–D6** land: delivery contract, durable send, honest receive, longer invite, collapsed pairing steps, and a success beat.

**Minimum bar to close the UX review complaints:**

1. D1 + D2 + D3 (truth or real async)
2. D4 + D5 + D8 + D9 + D10 (ceremony + language)
3. D11 + D13 (merge + unlink)
4. D6 + D15 (wonder)

---

## Context notes (from UX review)

- Engineering vocabulary in a prototype is acceptable when quarantined (Diagnostics / DEBUG).
- A todo app does not need general Undo; the 5s delete grace is a sync-safety pattern and should remain.
- Target feeling: *I linked them once. Now tasks simply appear on the other phone. I never think about sync.*
- The enemy of that feeling is recruiting the user as a sync operator (keep apps open, beat the clock, babysit uploads, reopen to receive).
