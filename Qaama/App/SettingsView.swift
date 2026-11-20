import SwiftUI

/// The keys of the app's settings, read with `@AppStorage` where they apply.
enum AppSettings {
    /// Show a card or a camera in the window as soon as it is plugged in.
    static let opensDevicesKey = "opensDevicesWhenPluggedIn"
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

    var body: some View {
        Form {
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
