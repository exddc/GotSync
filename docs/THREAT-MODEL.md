# Threat model

Task payloads are end-to-end encrypted with MLS. The relay is untrusted for
content confidentiality and integrity. It is necessarily trusted for delivery
availability and a consistent ordering view. It can withhold, replay, reorder,
fork or delete traffic; clients fail closed when validation fails.

Mutual role-specific scans bind the inviter signing identity and joiner
KeyPackage. A post-Welcome confirmation from the pinned inviter authenticates
the actual MLS context before local tasks leave the joiner. Transport uses
separate random device capabilities. No account, recovery key or server-side
content key exists.

Every member can read and edit the shared task set and authorize membership
changes. Malicious co-members can alter task content or deny service. Initial
history transfer trusts the scanned inviter's checkpoint. Device compromise
exposes available plaintext and current device secrets. MLS removal excludes
a member from subsequent epochs; it does not erase previous plaintext or
promise physical key erasure.

Headers reveal group IDs, epochs and plaintext commit membership information.
Timing, sizes and IP addresses are visible. No anonymity or within-group
privacy is claimed. No independent audit has been completed.

See [the integration limits and release gates](WIRE-CORECRYPTO.md) and
[the red-team record](SECURITY-RED-TEAM.md).
