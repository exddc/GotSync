import SwiftUI

enum RelayTheme {
    static let accent = Color(
        red: 0.075,
        green: 0.337,
        blue: 0.090
    )
    static let success = Color(
        red: 0.160,
        green: 0.500,
        blue: 0.270
    )
    static let warning = Color(
        red: 0.760,
        green: 0.470,
        blue: 0.080
    )
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color(uiColor: .separator).opacity(0.42)
    static let field = Color(uiColor: .tertiarySystemGroupedBackground)
}

struct RelayCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RelayTheme.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RelayTheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func relayCard() -> some View {
        modifier(RelayCardModifier())
    }
}

struct PrivacyDisclosureView: View {
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(RelayTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Private by construction")
                    .font(.headline)
                Text(
                    compact
                        ? "Task text is end-to-end encrypted. Opaque ciphertext is deleted after receipt or expires after 365 days."
                        : "No account, analytics, or readable cloud task database. The relay keeps ciphertext until the other iPhone applies it, or for at most 365 days by default. It can see timing and byte counts, but never task text or encryption keys."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard()
        .accessibilityElement(children: .combine)
    }
}

struct SyncStatusView: View {
    let phase: SyncPhase
    let title: String
    let detail: String
    let roundTripMilliseconds: Double?
    let lastSyncedAt: Date?
    var mailboxAvailable = false
    var mailboxNeedsAttention = false
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetail ? 10 : 7) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .overlay {
                        if phase == .connecting || phase == .reconciling {
                            Circle()
                                .stroke(statusColor.opacity(0.28), lineWidth: 5)
                        }
                    }
                    .accessibilityHidden(true)

                Text(title)
                    .font(.headline)

                Spacer(minLength: 8)

                if let roundTripMilliseconds {
                    Label(
                        "RTT \(roundTripMilliseconds, specifier: "%.1f") ms",
                        systemImage: "bolt.horizontal.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            if showsDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastSyncedAt {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text("Last change \(lastSyncedAt, style: .relative)")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard()
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if mailboxNeedsAttention, phase != .failed {
            return RelayTheme.warning
        }
        if mailboxAvailable, phase != .failed {
            return RelayTheme.success
        }
        switch phase {
        case .synced:
            return RelayTheme.success
        case .waitingForPeer, .verifying, .provisioning,
             .connecting, .reconciling:
            return RelayTheme.warning
        case .failed:
            return .red
        case .unpaired, .offline:
            return .secondary
        }
    }
}

struct PairingHeaderView: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
                .accessibilityHidden(true)

            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
