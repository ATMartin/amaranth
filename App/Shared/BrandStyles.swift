import SwiftUI
import AppKit

/// Shared controls for the Inner Circle look. They draw with the named brand colours, so they follow the effective
/// appearance and Increase Contrast like every other view.

/// The one emphasised action on a surface (Start recording, Save, Link): an accent fill with the On Accent label
/// colour. `.borderedProminent` would put white on the dark-mode blush accent.
struct BrandProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.brandAccent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(contrast == .increased ? Color.brandText : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// A quiet outlined button (Delete audio…, Cancel in custom dialogs). `destructive` uses the Danger colour for its label.
struct BrandOutlineButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(destructive ? Color.statusFailed : Color.brandText)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Color.selection : Color.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.controlBorder, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension ButtonStyle where Self == BrandProminentButtonStyle {
    static var brandProminent: BrandProminentButtonStyle { BrandProminentButtonStyle() }
}

extension ButtonStyle where Self == BrandOutlineButtonStyle {
    static var brandOutline: BrandOutlineButtonStyle { BrandOutlineButtonStyle() }
    static var brandDestructive: BrandOutlineButtonStyle { BrandOutlineButtonStyle(destructive: true) }
}

/// A link back to the source ("12:18 ↗"): accent text with an underline, so it isn't told apart by colour alone.
struct SourceLinkStyle: ButtonStyle {
    var role: AppStyle.Role = .caption
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.label
            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
        }
        .appFont(role, monospacedDigit: true)
        .foregroundStyle(enabled ? Color.link : Color.brandSecondary)
        .underline(enabled, color: Color.link.opacity(0.6))
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(Rectangle())
    }
}

/// Small tracked capitals above a block ("TRANSCRIPT", "NEXT STEPS"): a heading for VoiceOver.
struct Eyebrow: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.grid) {
            Text(text).appFont(.eyebrow).foregroundStyle(Color.brandSecondary).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).appFont(.caption2).foregroundStyle(Color.brandSecondary) }
        }
    }
}

/// A structural hairline in the control-border colour.
struct Hairline: View {
    var opacity = 0.55
    var body: some View { Rectangle().fill(Color.controlBorder.opacity(opacity)).frame(height: 1).accessibilityHidden(true) }
}

/// Text tabs with an accent underline on the selected one (Notes · Transcript · Audio details). Each is a button with
/// the selected trait; ⌘1–⌘3 live in the Meeting menu.
struct UnderlineTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }
    @Environment(\.textScale) private var scale

    var body: some View {
        HStack(spacing: AppStyle.double + 4) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 4) {
                        Text(title(tab))
                        if let b = badge(tab) {
                            Image(systemName: "exclamationmark.circle").font(.system(size: AppStyle.iconSmall * scale))
                                .foregroundStyle(Color.statusAttention).help(b).accessibilityLabel(b)
                        }
                    }
                    .appFont(.callout, weight: selected ? .medium : .regular)
                    .foregroundStyle(selected ? Color.brandAccent : Color.brandText)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? Color.brandAccent : .clear).frame(height: 2).offset(y: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }
}

/// The speech ring and seed in colour (light: wine ring; dark: blush ring), for empty states and onboarding. Decorative.
struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View {
        Image("AmaranthMark").resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A segmented choice whose selected segment is the Selection colour with an accent label. The native segmented control
/// fills the selected segment with the accent and draws white on it, which is unreadable on the dark-mode blush.
struct BrandSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option)).appFont(.caption, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.brandAccent : Color.brandText)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.selection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.controlBorder.opacity(0.6), lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Plain text link in the accent colour, underlined (Recording Settings…, Use Defaults).
struct BrandLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color.link).underline(color: Color.link.opacity(0.6))
            .opacity(configuration.isPressed ? 0.7 : 1).contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == BrandLinkStyle {
    static var brandLink: BrandLinkStyle { BrandLinkStyle() }
}

/// An on/off chip (the live Scratchpad toggle): on is the Selection colour with an accent label and edge.
struct BrandChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .foregroundStyle(configuration.isOn ? Color.brandAccent : Color.brandText)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isOn ? Color.selection : Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(configuration.isOn ? Color.brandAccent : Color.controlBorder, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
