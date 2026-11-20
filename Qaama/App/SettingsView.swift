import AppKit
import SwiftUI

/// The keys of the app's settings, read with `@AppStorage` where they apply.
enum AppSettings {
    /// Show a card or a camera in the window as soon as it is plugged in.
    static let opensDevicesKey = "opensDevicesWhenPluggedIn"
    /// The app's appearance (`AppAppearance`), whatever the system's.
    static let appearanceKey = "appearance"
}

/// Light or dark for the whole app, or whatever the system uses.
///
/// Applied through `NSApp.appearance` rather than `preferredColorScheme`: the latter only reaches
/// the windows of the scene it is set in, not menus, alerts, open panels or the Settings window,
/// and it doesn't go back to the system's appearance once set.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self {
        self
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Makes every window of the app follow this choice; `nil` hands it back to the system.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The Settings window (Qaama › Settings…): one pane for now.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.opensDevicesKey) private var opensDevices = true
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Import") {
                Toggle("Show a card or a camera when it is plugged in", isOn: $opensDevices)
                    .help("The window goes to the device in the sidebar, ready to import. A phone is never opened by itself.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
}
