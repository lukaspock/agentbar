import SwiftUI
import AgentBarCore

extension MascotEyeStyle {
    var settingsTitle: String {
        switch self {
        case .round: return "Round"
        case .pill: return "Pill"
        case .sleepy: return "Sleepy"
        case .happy: return "Happy"
        }
    }
}

extension MascotAccessory {
    var settingsTitle: String {
        switch self {
        case .none: return "None"
        case .hat: return "Hat"
        case .glasses: return "Glasses"
        case .bow: return "Bow"
        case .antenna: return "Antenna"
        }
    }
}

/// Settings > Mascot: the owner's own character that the bar shows while no agent is running.
struct MascotSettingsView: View {
    @ObservedObject var hub: PreferencesHub
    @State private var error: String?

    var body: some View {
        let _ = hub.revision
        let m = hub.store.mascot()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Mascot").font(.headline)
                Text("Your mascot is what the bar shows while no agent is running. It breathes, blinks and falls asleep when nothing happens.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        field("Name") {
                            CommitTextField(placeholder: "Mascot name", text: m.name, limit: PreferenceText.maxNameLength) { value in
                                if value.isEmpty { error = PreferencesError.invalidName.settingsMessage; return }
                                update { $0.name = value }
                            }
                        }
                        field("Body") {
                            HStack(spacing: 8) { ForEach(BlobKind.allCases, id: \.self) { bodyButton($0, current: m) } }
                        }
                        field("Color") {
                            HStack(spacing: 10) {
                                ColorPicker("Color", selection: Binding(
                                    get: { Color(hex: m.colorHex) ?? .gray },
                                    set: { c in update { $0.colorHex = c.hexString } }), supportsOpacity: false)
                                    .labelsHidden()
                                Text(m.colorHex).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        field("Eyes") {
                            Picker("Eyes", selection: Binding(get: { m.eyeStyle }, set: { v in update { $0.eyeStyle = v } })) {
                                ForEach(MascotEyeStyle.allCases, id: \.self) { Text($0.settingsTitle).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        field("Accessory") {
                            Picker("Accessory", selection: Binding(get: { m.accessory }, set: { v in update { $0.accessory = v } })) {
                                ForEach(MascotAccessory.allCases, id: \.self) { Text($0.settingsTitle).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    preview(m)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("Reset") { hub.store.resetMascot(); error = nil }.disabled(m == .standard)
                }
            }
            .padding(20)
        }
    }

    private func preview(_ m: MascotAppearance) -> some View {
        VStack(spacing: 10) {
            Text("Preview").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black)
                MascotView(appearance: m, size: 120)
            }
            .frame(width: 170, height: 170)
            // How it looks in the collapsed bar.
            ZStack {
                Capsule().fill(Color.black)
                MascotView(appearance: m, size: 24)
            }
            .frame(width: 70, height: 32)
            Text(m.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 170)
        }
        .frame(width: 170)
    }

    private func bodyButton(_ kind: BlobKind, current m: MascotAppearance) -> some View {
        let selected = m.bodyKindName == kind.storageName
        return Button { update { $0.bodyKindName = kind.storageName } } label: {
            BlobShape(kind: kind).fill(Color(hex: m.colorHex) ?? .gray)
                .padding(7).frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(kind.settingsTitle)
        .accessibilityLabel("\(kind.settingsTitle) body")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func update(_ f: (inout MascotAppearance) -> Void) {
        var m = hub.store.mascot()
        f(&m)
        do { try hub.store.setMascot(m); error = nil }
        catch let e as PreferencesError { error = e.settingsMessage }
        catch { self.error = error.localizedDescription }
    }
}
