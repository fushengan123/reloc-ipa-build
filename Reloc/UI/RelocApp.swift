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
    @State private var showLocationGuide = false

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
            // iOS 10+ cannot deep-link straight into the system Location Services
            // page. Show the exact tap path first, then open this app's Settings
            // page (the closest officially supported destination).
            showLocationGuide = true
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
        .alert("前往定位服务", isPresented: $showLocationGuide) {
            Button("取消", role: .cancel) {}
            Button("打开设置") {
                LocationSettingsOpener.open()
            }
        } message: {
            Text("即将打开「设置 → Reloc」。进入后点顶部的「位置 / 定位」，即可到达系统定位服务页；关闭再打开「定位服务」总开关可恢复真实 GPS。")
        }
    }
}

/// Opens the location settings entry.
///
/// Reality check (verified): since iOS 10 Apple blocks all `prefs:root=...` deep
/// links into specific Settings sub-pages. `UIApplication.shared.open` still
/// returns `success = true`, but the OS silently redirects to the Settings home
/// screen. That is why the old implementation (which stopped at the first
/// "accepted" URL) always landed on the Settings home page.
///
/// The only officially supported, reliable destination is the app's own
/// Settings page via `UIApplication.openSettingsURLString`, where the "位置 /
/// Location" row leads to the system Location Services screen. We lead with
/// that, and keep the private schemes only as a low-priority best-effort for
/// older systems where they may still work.
private enum LocationSettingsOpener {
    static func open() {
        var candidates: [URL] = []

        // 1) Official and reliable: this app's Settings page. The "位置" row there
        //    opens the system Location Services screen (master switch + per-app).
        if let appSettings = URL(string: UIApplication.openSettingsURLString) {
            candidates.append(appSettings)
        }
        // 2) Best-effort private deep links for older iOS where they still work.
        //    Kept AFTER the official URL so modern iOS never gets stuck on home.
        if let privacy = URL(string: "prefs:root=Privacy&path=LOCATION") { candidates.append(privacy) }
        if let system = URL(string: "prefs:root=LOCATION_SERVICES") { candidates.append(system) }
        if let altSystem = URL(string: "App-prefs:root=LOCATION_SERVICES") { candidates.append(altSystem) }

        attempt(candidates, at: 0)
    }

    /// Opens only the first candidate that the system accepts. Because the official
    /// app-settings URL is first and is always accepted on modern iOS, the user
    /// reliably lands on this app's Settings page instead of the Settings home.
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
