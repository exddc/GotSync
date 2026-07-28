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
                        ? "Task text is end-to-end encrypted. The relay only routes opaque bytes."
                        : "No account, analytics, or cloud task database. The relay can see connection timing and byte counts, but never task text or encryption keys."
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
        switch phase {
        case .synced:
            RelayTheme.success
        case .waitingForPeer, .verifying, .provisioning,
             .connecting, .reconciling:
            RelayTheme.warning
        case .failed:
            .red
        case .unpaired, .offline:
            .secondary
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
