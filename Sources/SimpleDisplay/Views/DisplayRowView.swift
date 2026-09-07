import SwiftUI

struct DisplayRowView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel
    @Environment(LocaleManager.self) private var locale
    let display: DisplayInfo

    private var isConfiguring: Bool {
        viewModel.navigationState == .configuringDisplay(display.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Configure button (virtual displays only)
            if display.isVirtual {
                Button {
                    if isConfiguring {
                        viewModel.navigate(to: .displayList)
                    } else {
                        viewModel.navigate(to: .configuringDisplay(display.id))
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.callout)
                        .foregroundStyle(isConfiguring ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isBusy || viewModel.isNavigating)
            }

            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if display.isMain {
                        BadgeView(text: locale.t("badge_main"), color: .blue)
                    } else if display.isActive && !display.isVirtual && !display.isMirrored {
                        Button {
                            viewModel.setAsMainDisplay(display)
                        } label: {
                            BadgeView(text: locale.t("badge_set_main"), color: .secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isBusy)
                    }
                    Text(verbatim: display.name)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(display.isActive ? .primary : .secondary)
                    if display.isVirtual {
                        BadgeView(text: locale.t("badge_virtual"), color: .purple)
                    }
                    if !display.isActive {
                        BadgeView(text: locale.t("badge_disabled"), color: .orange)
                    }
                    if display.isMirrored {
                        BadgeView(
                            text: locale.t("badge_mirror_of_format", viewModel.displayName(for: display.mirroredToDisplayID)),
                            color: .teal
                        )
                    }
                }
                if !display.isPlaceholder {
                    Text(verbatim: display.currentMode.localizedResolutionString(locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Mirror onto main / stop mirroring: a separate, reversible state
            // from on/off. Physical displays only: a virtual display as a mirror
            // slave crashes the window server. Needs another display to mirror onto.
            if display.isActive && !display.isVirtual {
                Button {
                    viewModel.toggleMirror(display)
                } label: {
                    Image(systemName: display.isMirrored ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                        .font(.callout)
                        .foregroundStyle(display.isMirrored ? .teal : .secondary)
                }
                .buttonStyle(.borderless)
                .help(locale.t(display.isMirrored ? "unmirror_button_help" : "mirror_button_help"))
                .disabled(viewModel.isBusy || (!display.isMirrored && viewModel.activeDisplays.count < 2))
            }

            // Enable/Disable toggle
            Toggle("", isOn: Binding(
                get: { display.isActive },
                set: { _ in viewModel.toggleDisplay(display) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(viewModel.isBusy || (display.isActive && viewModel.activeDisplays.count <= 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(display.isActive ? 0.5 : 0.25))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .opacity(display.isActive ? 1.0 : 0.7)
    }

    private var iconName: String {
        if display.isVirtual { return "rectangle.dashed" }
        if display.isBuiltIn { return "laptopcomputer" }
        return "display"
    }

    private var iconColor: Color {
        if !display.isActive { return .gray }
        if display.isVirtual { return .purple }
        return .blue
    }
}

struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
