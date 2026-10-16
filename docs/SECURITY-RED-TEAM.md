# Security red-team findings

This branch cuts the active `SyncEngine` over to Wire CoreCrypto MLS. Internal
Opus reviews informed the implementation; they are not an external audit.
Statuses below describe implementation evidence, not approval for release.

| ID | Status | Current evidence or remaining work |
| --- | --- | --- |
| C1: shared pairwise mailbox keys | Custom key derivation removed | MLS replaces the pairwise mailbox design. Every member still intentionally shares task access. No within-group privacy is claimed. |
| C2: unpinned signing keys | Cut over and adversarial regression tested | Two scans pin the exact KeyPackage and SDK signing identity. A signed MLS confirmation gates Welcome activation. QR substitution, wrong direct origins, unsolicited checkpoints and a forged Welcome containing the real inviter leaf are tested. External integration review remains pending. |
| C3: removed device reads future traffic | Active path replaced and regression tested | Three-client removal and relay write revocation are tested. A direct raw-SDK attempt using saved pre-removal state also fails to decrypt a subsequent message. Physical-device and external validation remain pending. |
| C4: invitation theft | Admission capability narrowed | A photographed invitation lacks the joiner's secret member token. Both scans are required. Directory/pre-admission exhaustion remains an availability risk. Physical camera validation is pending. |
| H1: anonymous capacity exhaustion | Open deployment gate | Per-group live limits and cursor-based pruning bound storage. Pairing records expire. Empty groups retire on local unlink; public-service rate limiting/admission is still required; anonymous callers can exhaust the global group quota. |
| H2: retained-root compromise | Custom root removed, assurance gate open | CoreCrypto supplies MLS ratchets and epochs. Backup exclusion and protected local state are implemented. SIGKILL recovery is tested. External review and device power-loss testing remain required before a forward-secrecy claim. |
| H3: loss of every device | Intentional product boundary | No accounts or recovery were added. Losing every copy permanently loses the tasks. |
| M1: relay metadata | Open, disclosed boundary | Group IDs and epochs occur in MLS headers; PublicMessage commits expose membership/public keys. Timing, sizes, routes and IP addresses remain visible. |

## Internal review regressions

The implementation review identified invitation-expiry freezes, empty host
KeyPackage cancellation, broad inbox acknowledgement, provisional traffic
ordering, self-removal, relinking, exposed joiner transport capabilities,
receipt bookkeeping and candidate-file leaks. Regression coverage now includes
expiry/cancel, three-client admission ordering, prefix acknowledgement,
authenticated leave requests, token-directory separation and concurrent commits.
The iOS database adapter also covers relocation with an accepted pending commit
and obsolete salt-entry cleanup. The dependency-specific salt convention is
a maintenance obligation, documented in WIRE-CORECRYPTO.md.
Review rounds and their final outcomes are recorded in the PR validation notes.

## Release gates

Physical iPhone tests remain pending because the device was locked. Do not
interpret simulator builds or host reopening tests as physical-device success.
Device power loss, physical camera verification,
external integration review and GPL/distribution compatibility remain open.
Deletion does not guarantee erasure from flash, backups already made, filesystem
snapshots, vendor Keychain internals or other members' saved plaintext.

The obsolete custom-crypto protocol-vector, handshake and mailbox-journal
suites were removed with those implementations. Replica, keep-both and
configuration tests remain. Wire/relay regressions replace the active sync
coverage; old test deletion is not presented as a security improvement.
