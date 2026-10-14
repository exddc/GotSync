import GotSync
import SwiftUI
import UIKit

/// Black / white industrial language: pure grayscale field, hairline panels,
/// mono technical labels. Accent is light gray `#f5f5f5`.
enum RelayTheme {
    /// Single accent — light gray signal on black.
    static let accent = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)

    /// Ink drawn on accent fills (primary CTAs, completed chips).
    static let onAccent = Color.black

    /// Black canvas.
    static let background = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0, alpha: 1)
        }
        return UIColor(white: 0.96, alpha: 1)
    })

    /// Elevated panel — pure gray step above canvas.
    static let card = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0.08, alpha: 1)
        }
        return UIColor(white: 1, alpha: 1)
    })

    static let field = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0.05, alpha: 1)
        }
        return UIColor(white: 0.92, alpha: 1)
    })

    /// Primary text — white on black / black on white.
    static let ink = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 1, alpha: 1)
        }
        return UIColor(white: 0, alpha: 1)
    })

    static let inkMuted = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 1, alpha: 0.48)
        }
        return UIColor(white: 0, alpha: 0.48)
    })

    /// QR plate — pure white for scannability.
    static let qrPlate = Color.white

    static let border = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 1, alpha: 0.12)
        }
        return UIColor(white: 0, alpha: 0.12)
    })

    static let live = accent
    static let pending = inkMuted
    static let danger = Color(uiColor: .systemRed)

    static let displayName = "Accountless Sync"
    static let productSlug = "accountless-sync"
    static let proofLabel = "Proof of concept"

    /// Tighter industrial radii (Cursor/SpaceX panels, not consumer soft-UI).
    static let cornerCard: CGFloat = 12
    static let cornerRow: CGFloat = 10
    static let cornerControl: CGFloat = 10

    static let springSnappy = Animation.smooth(duration: 0.18)
    static let springSoft = Animation.smooth(duration: 0.24)

    static var mono: Font {
        .system(.footnote, design: .monospaced)
    }

    static var monoCaption: Font {
        .system(size: 11, weight: .medium, design: .monospaced)
    }
}

// MARK: - Surfaces: hairline industrial panels (+ optional glass on iOS 26)

struct RelayCardModifier: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = RelayTheme.cornerCard
    var interactive: Bool = false
    var tinted: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .modifier(
                IndustrialPanelModifier(
                    cornerRadius: cornerRadius,
                    interactive: interactive,
                    tinted: tinted
                )
            )
    }
}

/// SpaceX-style panel: solid elevated fill + hairline. Optional thin glass wash on iOS 26.
struct IndustrialPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool
    var tinted: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, *) {
            content
                .background {
                    shape.fill(RelayTheme.card)
                }
                .glassEffect(
                    panelGlass(tinted: tinted, interactive: interactive),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(RelayTheme.border, lineWidth: 1)
                }
        } else {
            content
                .background(shape.fill(RelayTheme.card))
                .overlay {
                    shape.strokeBorder(RelayTheme.border, lineWidth: 1)
                }
        }
    }

    @available(iOS 26, *)
    private func panelGlass(tinted: Bool, interactive: Bool) -> Glass {
        var g: Glass = .regular
        if tinted {
            g = g.tint(RelayTheme.accent.opacity(0.12))
        }
        if interactive {
            g = g.interactive()
        }
        return g
    }
}

/// Alias so existing call sites keep compiling.
typealias GlassSurfaceModifier = IndustrialPanelModifier

struct SoftFieldBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RelayTheme.background
            // Sparse telemetry wash — restrained, not soft consumer glow.
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        RelayTheme.accent.opacity(0.06),
                        .clear,
                        RelayTheme.accent.opacity(0.03),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    func relayCard(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = RelayTheme.cornerCard,
        interactive: Bool = false,
        tinted: Bool = false
    ) -> some View {
        modifier(
            RelayCardModifier(
                padding: padding,
                cornerRadius: cornerRadius,
                interactive: interactive,
                tinted: tinted
            )
        )
    }

    /// Primary CTA — solid accent block (mission action).
    func pocPrimaryButtonStyle() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(RelayTheme.accent)
            .foregroundStyle(RelayTheme.onAccent)
            .buttonBorderShape(.roundedRectangle(radius: RelayTheme.cornerControl))
    }

    /// Secondary — hairline outlined control.
    @ViewBuilder
    func pocSecondaryButtonStyle() -> some View {
        if #available(iOS 26, *) {
            self
                .buttonStyle(.glass)
                .tint(RelayTheme.ink)
                .buttonBorderShape(.roundedRectangle(radius: RelayTheme.cornerControl))
        } else {
            self
                .buttonStyle(.bordered)
                .tint(RelayTheme.ink)
                .buttonBorderShape(.roundedRectangle(radius: RelayTheme.cornerControl))
        }
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
                        .controlSize(.small)
                        .tint(RelayTheme.accent)
                } else {
                    Image(systemName: notice.kind == .repair
                        ? "exclamationmark.triangle.fill"
                        : "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(notice.kind == .repair ? RelayTheme.danger : RelayTheme.pending)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RelayTheme.ink)
                Text(notice.detail)
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if notice.kind == .repair {
                    Button("Keep tasks · create new link", action: repairAction)
                        .pocPrimaryButtonStyle()
                        .controlSize(.regular)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct SyncStatusView: View {
    let phase: SyncPhase
    let title: String
    let detail: String
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetail ? 8 : 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .overlay {
                        if phase == .connecting || phase == .reconciling {
                            Circle()
                                .stroke(statusColor.opacity(0.3), lineWidth: 3)
                        }
                    }
                    .accessibilityHidden(true)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RelayTheme.ink)

                Spacer(minLength: 8)
            }

            if showsDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch phase {
        case .synced:
            return RelayTheme.live
        case .waitingForPeer, .verifying, .provisioning, .finalizing,
             .connecting, .reconciling:
            return RelayTheme.pending
        case .failed:
            return RelayTheme.danger
        case .unpaired, .offline:
            return RelayTheme.inkMuted
        }
    }
}

struct PairingHeaderView: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(RelayTheme.accent)
                    .symbolRenderingMode(.monochrome)
                    .accessibilityHidden(true)
                
                Text(title)
                    .font(.system(.title, design: .default, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(RelayTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(RelayTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Buttons") {
    VStack(spacing: 16) {
        Button {
        } label: {
            Text("Create link")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .pocPrimaryButtonStyle()
        .controlSize(.large)

        Button {
        } label: {
            Text("Join link")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .pocSecondaryButtonStyle()
        .controlSize(.large)

        Button {
        } label: {
            Text("New code")
                .frame(maxWidth: .infinity)
        }
        .pocSecondaryButtonStyle()
        .controlSize(.large)

        Button("Codes don’t match", role: .destructive) {}
            .pocSecondaryButtonStyle()
            .controlSize(.large)
            .frame(maxWidth: .infinity)

        Button {
        } label: {
            Text("Disabled primary")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .pocPrimaryButtonStyle()
        .controlSize(.large)
        .disabled(true)

        Button {
        } label: {
            Text("Disabled secondary")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .pocSecondaryButtonStyle()
        .controlSize(.large)
        .disabled(true)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(SoftFieldBackground())
    .preferredColorScheme(.dark)
}

#Preview("Sync notice") {
    VStack(spacing: 16) {
        SyncNoticeView(
            notice: SyncNotice(
                kind: .saving,
                title: "Saving…",
                detail: "Upload in progress."
            ),
            repairAction: {}
        )
        SyncNoticeView(
            notice: SyncNotice(
                kind: .retrying,
                title: "Retrying upload",
                detail: "Will try again when the mailbox is reachable."
            ),
            repairAction: {}
        )
        SyncNoticeView(
            notice: SyncNotice(
                kind: .repair,
                title: "Link needs repair",
                detail: "Keep tasks and create a new link."
            ),
            repairAction: {}
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(SoftFieldBackground())
    .preferredColorScheme(.dark)
}

#Preview("Sync status") {
    VStack(spacing: 16) {
        SyncStatusView(
            phase: .synced,
            title: "Linked",
            detail: "3 phones share this list."
        )
        SyncStatusView(
            phase: .waitingForPeer,
            title: "Waiting",
            detail: "Keep both apps open."
        )
        SyncStatusView(
            phase: .failed,
            title: "Could not link",
            detail: "Create a new invitation."
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(SoftFieldBackground())
    .preferredColorScheme(.dark)
}

#Preview("Pairing header") {
    PairingHeaderView(
        title: "Show this code",
        detail: "On the other phone, tap Join link and scan.",
        symbol: "qrcode"
    )
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(SoftFieldBackground())
    .preferredColorScheme(.dark)
}
#endif

