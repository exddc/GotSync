# TW-303 — Design analysis (iteration 2): Liquid Glass + POC honesty

**Product:** Accountless Sync — a *proof of concept* shell that demos multi-device encrypted sync. Not a shipping todo product. Not Got Done.

**Platform bar:** iOS 26 Liquid Glass (native `glassEffect` / glass buttons), Apple HIG materials & type. Fallbacks for earlier OS.

---

## Round 1 — multi-POV critique of iteration-1 “Relay” design

### Apple Chief Design
| Finding | Severity | Success |
|---------|----------|---------|
| Opaque warm cards ignore platform material language | P0 | Floating chrome uses Liquid Glass; content sits on a calm field |
| Custom solid indigo CTAs fight system glass buttons | P0 | Primary = `.glassProminent`, secondary = `.glass` |
| Composer bar is a hard material strip | P0 | Glass composer floating above content |
| Tracking/leading not optical on large titles | P1 | Large titles slightly tight tracking; body near default |
| Motion still structural only | P2 | Subtle glass morph via hierarchy change; no bounce |

### Linear Lead
| Finding | Severity | Success |
|---------|----------|---------|
| “Relay” still feels productized | P0 | Name + badge say **proof of concept** |
| Dense privacy cards compete with CTAs | P1 | Privacy as glass footnote, not second hero |
| Status copy long on Manage | P1 | Short headline + disclosure footnote |

### Cursor Lead
| Finding | Severity | Success |
|---------|----------|---------|
| Sync engine not named in chrome | P0 | Title **Accountless Sync** + “POC” chip |
| Empty state soft-sells product | P0 | Empty state: “Demo list · sync is the feature” |

### SpaceX Head of Design
| Finding | Severity | Success |
|---------|----------|---------|
| Pairing path must stay sparse under glass | P0 | QR/code remain highest contrast; glass frames them, doesn’t compete |
| One accent only (keep) | P0 | Accent only for live/check; glass carries structure |

### Senior product designer
| Finding | Severity | Success |
|---------|----------|---------|
| Social demo must read as POC in first frame | P0 | Eyebrow `accountless-sync` + Proof of concept label |
| Scope honesty | P0 | Copy never promises full todo / accounts / push |

---

## Round 2 — target system (implementation brief)

### Naming
| Surface | Copy |
|---------|------|
| Display name | Accountless Sync |
| Technical eyebrow | accountless-sync |
| Badge | Proof of concept |
| Primary CTAs | Create link / Join link |
| Empty (linked) | Demo tasks sync across linked phones |

### Liquid Glass map
| Element | Treatment |
|---------|-----------|
| Cards / notices / privacy | `.glassEffect(.regular, in: .rect(cornerRadius: 22))` |
| Primary button | `.buttonStyle(.glassProminent)` |
| Secondary button | `.buttonStyle(.glass)` |
| Task rows | light glass rect, continuous corner 16 |
| Composer | glass capsule/rect, interactive |
| Toolbar menu | system (inherits glass nav on 26) |
| QR plate | near-opaque plate *inside* glass (scannability) |
| Background | soft system field + subtle accent wash (so glass has something to refract) |

### Constraints (unchanged)
- No pure `#000` / `#FFF` fills (QR plate near-white only)
- One accent color
- Minimal motion (≤280ms, reduce-motion → opacity)

### Availability
```swift
#if available iOS 26 → native glass
#else → .ultraThinMaterial continuous rect (same radii)
#endif
```

---

## Round 3 — acceptance (designers “satisfied”)

Must pass visual review on **iOS 26 simulator**:

1. Welcome: POC badge + accountless-sync + glass CTAs, no Got Done/Relay product tone  
2. Invite: QR hero in glass stage  
3. Dashboard empty: glass composer, sync-forward empty copy  
4. Manage: short status, glass sheet chrome  
5. No stacked light-on-light illegible glass  
6. Reduced Transparency / fallback still usable  

---

## Round 4 — sim review loop (executed)

### Pass A (v2) — **rejected**
- `glassProminent` / pure glass CTAs on soft field painted **invisible** (no labels).
- Proof chip + privacy collapsed with glass-only treatment.
- Apple CD: “Glass without light/contrast is fog, not material.”

### Pass B (v3) — **rejected**
- Tint/container tweaks insufficient; primary still failed legibility.

### Pass C (v4) — **accepted**
| Role | Verdict |
|------|---------|
| Apple CD | Primary = solid prominent (clear agency). Surfaces + secondary = Liquid Glass. Soft field gives glass depth. Type tracking OK. |
| Linear | One accent, POC chip, short hierarchy. Pass. |
| Cursor | `accountless-sync` + “Proof of concept” + demo-task language. Pass. |
| SpaceX | Invite QR remains high-contrast hero; chrome recedes. Pass. |
| Senior product | First frame reads as POC shell for sync, not a todo product. Pass. |

**Rule locked in:** Liquid Glass for **surfaces / secondary / chrome**; **solid accent** for the primary mission CTA (Create link / Approve). Never put critical labels only on untinted glass over a light field.

Proof shots: `docs/screenshots/tw-303/welcome.png`, `invite.png`, `dashboard.png`, `manage-sync.png`.

---

## Out of scope
- Crypto URL scheme rename (`gotdone://`)
- Full todo features
- Raising deployment target above 18.6 (glass is runtime-gated)
