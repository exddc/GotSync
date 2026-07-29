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
                Text("End-to-end encrypted")
                    .font(.headline)
                Text(
                    compact
                        ? "The relay temporarily stores encrypted payloads for offline delivery. It can see timing and size, not task text."
                        : "No account, ad tracking, or per-user analytics. The relay temporarily stores encrypted payloads for offline delivery and can see timing and size, not task text or encryption keys."
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

struct SyncNoticeView: View {
    let notice: SyncNotice
    let repairAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if notice.kind == .saving {
                    ProgressView()
                } else {
                    Image(systemName: notice.kind == .repair
                        ? "exclamationmark.triangle.fill"
                        : "arrow.trianglehead.2.clockwise.rotate.90")
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(notice.kind == .repair ? .red : RelayTheme.warning)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.headline)
                Text(notice.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if notice.kind == .repair {
                    Button("Keep Tasks and Replace Link", action: repairAction)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
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
            }

            if showsDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard()
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch phase {
        case .synced:
            return RelayTheme.success
        case .waitingForPeer, .verifying, .provisioning, .finalizing,
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
