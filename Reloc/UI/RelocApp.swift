import SwiftUI
import UIKit

@main
struct RelocApp: App {
    @StateObject private var viewModel = RelocViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .tint(RelocTheme.accent)
                .preferredColorScheme(viewModel.appearanceMode.colorScheme)
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: RelocViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MapPickerView(viewModel: viewModel, switchToConfig: { selectedTab = 1 })
                .tabItem {
                    Label("定位", systemImage: "location.north.circle.fill")
                }
                .tag(0)

            ConfigurationView(viewModel: viewModel)
                .tabItem {
                    Label("设备连接", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(1)

            ProtocolLogsView(viewModel: viewModel)
                .tabItem {
                    Label("实测与日志", systemImage: "waveform.path.ecg")
                }
                .tag(2)
        }
        .onChange(of: viewModel.requestOpenLocationSettings) { _, shouldOpen in
            guard shouldOpen else { return }
            viewModel.requestOpenLocationSettings = false
            LocationSettingsOpener.open()
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }
}

/// Opens the system Location Services screen. This is needed both after a send
/// session starts and after it stops: toggling Location Services off/on is what
/// clears the injected coordinates and restores the device's real location.
/// The `prefs:` deep links are not public API; the public app-settings URL is the last fallback.
private enum LocationSettingsOpener {
    static func open() {
        var candidates: [URL] = []
        // 目标：系统「设置 → 隐私与安全性 → 定位服务」总开关页面
        if let system = URL(string: "prefs:root=LOCATION_SERVICES") { candidates.append(system) }
        if let altSystem = URL(string: "App-prefs:root=LOCATION_SERVICES") { candidates.append(altSystem) }
        if let privacy = URL(string: "prefs:root=Privacy&path=LOCATION") { candidates.append(privacy) }
        if let appSettings = URL(string: UIApplication.openSettingsURLString) { candidates.append(appSettings) }
        attempt(candidates, at: 0)
    }

    private static func attempt(_ urls: [URL], at index: Int) {
        guard index < urls.count else { return }
        UIApplication.shared.open(urls[index], options: [:]) { success in
            guard !success else { return }
            DispatchQueue.main.async {
                attempt(urls, at: index + 1)
            }
        }
    }
}
