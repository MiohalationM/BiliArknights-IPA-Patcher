import SwiftUI

enum AppTheme {
    // Rhodes Island navy + Bilibili/tactical cyan palette echoing AppIcon.png
    static let brandCyan = Color(red: 0.08, green: 0.62, blue: 0.92)
    static let brandDeepBlue = Color(red: 0.04, green: 0.43, blue: 0.78)
    static let buttonGradientStart = Color(red: 0.01, green: 0.41, blue: 0.63) // #0369A1 (WCAG AA > 5.8:1 with white)
    static let buttonGradientEnd = Color(red: 0.03, green: 0.35, blue: 0.52)   // #075985 (WCAG AA > 7.5:1 with white)
    static let brandBrightCyan = Color(red: 0.22, green: 0.78, blue: 0.98)
    static let brandNavyStart = Color(red: 0.06, green: 0.14, blue: 0.24)
    static let brandNavyEnd = Color(red: 0.04, green: 0.25, blue: 0.40)

    static let primaryGradient = LinearGradient(
        colors: [buttonGradientStart, buttonGradientEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let progressGradient = LinearGradient(
        colors: [brandBrightCyan, brandCyan, brandDeepBlue],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// Subtle ambient background canvas that elevates grouped cards while staying 100% native in Light & Dark Mode.
struct AppBackgroundView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)

            LinearGradient(
                colors: [
                    AppTheme.brandCyan.opacity(colorScheme == .dark ? 0.14 : 0.07),
                    AppTheme.brandCyan.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Crisp vector brand mark echoing `AppIcon.png` (deep Rhodes navy + cyan diamond + upward arrow).
struct RhodesEmblemIcon: View {
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.brandNavyStart, AppTheme.brandNavyEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                        .strokeBorder(AppTheme.brandBrightCyan.opacity(0.32), lineWidth: 1)
                )

            // Outer diamond frame
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .stroke(AppTheme.brandBrightCyan, lineWidth: max(2.2, size * 0.055))
                .frame(width: size * 0.46, height: size * 0.46)
                .rotationEffect(.degrees(45))

            // Upward arrow glyph
            Image(systemName: "arrow.up")
                .font(.system(size: size * 0.28, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: AppTheme.brandCyan.opacity(0.22), radius: 8, y: 3)
    }
}

/// Sculpted grouped card surface with adaptive hairline border and soft ambient shadow.
struct AppCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.05),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(
                        color: colorScheme == .dark ? .clear : Color.black.opacity(0.04),
                        radius: 12,
                        x: 0,
                        y: 4
                    )
            )
    }
}

extension View {
    func appCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius))
    }
}

/// Tinted rounded-square icon pill used across option rows, status cards, and guides.
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 32
    var iconScale: CGFloat = 0.48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: size * iconScale, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

/// Compact capsule badge for status & adaptation mode labels.
struct StatusPill: View {
    let text: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Refined full-width gradient CTA button replacing oversized system capsule pills.
struct AppPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 42 : 52)
            .background(
                RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                    .fill(AppTheme.primaryGradient)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1.0) : 0.42)
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(isEnabled ? 0.22 : 0.0), lineWidth: 0.75)
                    )
            )
            .shadow(
                color: isEnabled ? AppTheme.brandCyan.opacity(configuration.isPressed ? 0.14 : 0.28) : .clear,
                radius: configuration.isPressed ? 4 : 10,
                x: 0,
                y: configuration.isPressed ? 2 : 5
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Clean secondary / destructive action button with subtle tinted surface and hairline border.
struct AppSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = AppTheme.brandCyan
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? tint : tint.opacity(0.45))
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 40 : 46)
            .background(
                RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.18 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous)
                            .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
