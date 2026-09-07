import SwiftUI

/// Unified view for creating and editing virtual displays.
/// Pass `editing` to edit an existing display, or nil to create a new one.
struct VirtualDisplayEditorView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel
    @Environment(LocaleManager.self) private var locale

    let editing: DisplayInfo?

    @State private var name: String
    @State private var width: Int
    @State private var height: Int
    @State private var hiDPI: Bool
    @State private var selectedPresetCategory: DevicePreset.PresetCategory = .tv

    private var isEditing: Bool { editing != nil }

    /// Panel size and zoom the display was created with. The live mode can differ
    /// (a zoom level picked from the row menu, or macOS's remembered mode), so
    /// the editor starts from the saved config, not from what is on screen.
    private let saved: VirtualDisplayService.VirtualDisplayConfig?

    init(editing: DisplayInfo? = nil, saved: VirtualDisplayService.VirtualDisplayConfig? = nil) {
        self.editing = editing
        self.saved = saved
        if let d = editing {
            _name = State(initialValue: d.name)
            _width = State(initialValue: saved?.width ?? d.currentMode.width)
            _height = State(initialValue: saved?.height ?? d.currentMode.height)
            _hiDPI = State(initialValue: saved?.hiDPI ?? d.currentMode.isHiDPI)
        } else {
            _name = State(initialValue: "Virtual Display")
            _width = State(initialValue: 1920)
            _height = State(initialValue: 1080)
            _hiDPI = State(initialValue: false)
        }
    }

    private var hasChanges: Bool {
        guard let d = editing else { return true }
        let baseW = saved?.width ?? d.currentMode.width
        let baseH = saved?.height ?? d.currentMode.height
        let baseHiDPI = saved?.hiDPI ?? d.currentMode.isHiDPI
        return width != baseW || height != baseH || hiDPI != baseHiDPI || name != d.name
    }

    /// What the desktop will look like: HiDPI renders the panel at 2x, so the
    /// usable area is half the pixels in each direction.
    private var looksLike: String {
        hiDPI ? "\(width / 2) x \(height / 2)" : "\(width) x \(height)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    nameSection
                    Divider()
                    resolutionSection
                    Divider()
                    presetsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // Warning (edit mode only)
            if isEditing && hasChanges {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(locale.t("recreate_warning"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.05))
            }

            // Sticky bottom bar
            Divider()
            bottomBar
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(.purple)
            Text(verbatim: isEditing ? name : locale.t("new_virtual_display"))
                .font(.headline)
            if isEditing {
                BadgeView(text: locale.t("badge_virtual"), color: .purple)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    close()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Name

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(locale.t("display_name"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(locale.t("virtual_display"), text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Resolution

    @ViewBuilder
    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                HStack {
                    Text(locale.t("active"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Spacer()
                    Text(verbatim: editing?.currentMode.localizedResolutionString(locale) ?? "")
                        .font(.caption).fontWeight(.medium)
                }
            }

            HStack {
                Text(locale.t("panel_size"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("W", value: $width, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 75)
                Text(verbatim: "x").foregroundStyle(.secondary)
                TextField("H", value: $height, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 75)
                Text(locale.t("pixels"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text(locale.t("zoom"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $hiDPI) {
                    Text(locale.t("zoom_1x")).tag(false)
                    Text(locale.t("zoom_2x")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Spacer()
                Text(verbatim: locale.t("looks_like_format", looksLike))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if isEditing {
                Text(locale.t("zoom_hint"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Presets

    @ViewBuilder
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(locale.t("device_presets"))
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(DevicePreset.PresetCategory.allCases, id: \.self) { cat in
                    presetTab(cat)
                }
            }

            let filtered = devicePresets.filter { $0.category == selectedPresetCategory }
            VStack(spacing: 0) {
                ForEach(filtered) { preset in
                    presetRow(preset)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
        }
    }

    @ViewBuilder
    private func presetTab(_ cat: DevicePreset.PresetCategory) -> some View {
        if selectedPresetCategory == cat {
            Button { selectedPresetCategory = cat } label: {
                Text(verbatim: cat.localizedName(locale)).font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.small).tint(.purple)
        } else {
            Button { selectedPresetCategory = cat } label: {
                Text(verbatim: cat.localizedName(locale)).font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.bordered).controlSize(.small).tint(.gray)
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: DevicePreset) -> some View {
        let isActive = width == preset.width && height == preset.height
        Button {
            width = preset.width
            height = preset.height
            name = preset.name
        } label: {
            HStack {
                Text(verbatim: preset.name).font(.caption)
                    .foregroundStyle(isActive ? .purple : .primary)
                Spacer()
                Text(verbatim: preset.dimensionString)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.purple.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 8) {
            if isEditing {
                // Set as Main
                if let d = editing, !d.isMain, d.isActive {
                    Button {
                        viewModel.setAsMainDisplay(d)
                    } label: {
                        Image(systemName: "star.fill").font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)
                }

                // Remove
                Button(role: .destructive) {
                    if let d = editing {
                        viewModel.removeVirtualDisplay(d)
                        viewModel.navigate(to: .displayList)
                    }
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isBusy)

                // Apply
                Button {
                    if let d = editing {
                        viewModel.reconfigureVirtualDisplay(
                            d, width: width, height: height,
                            hiDPI: hiDPI, name: name
                        )
                    }
                } label: {
                    Text(verbatim: locale.t("apply_format", width, height))
                        .font(.caption).fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(hasChanges && !viewModel.isBusy ? .purple : .gray)
                .disabled(!hasChanges || viewModel.isBusy)
            } else {
                Button(locale.t("cancel")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        close()
                    }
                }

                Button {
                    viewModel.newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig(
                        name: name, width: width, height: height, hiDPI: hiDPI
                    )
                    viewModel.createVirtualDisplay()
                } label: {
                    Text(verbatim: locale.t("create_format", width, height))
                        .font(.caption).fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isBusy ? .gray : .purple)
                .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func close() {
        viewModel.navigate(to: .displayList)
    }
}
