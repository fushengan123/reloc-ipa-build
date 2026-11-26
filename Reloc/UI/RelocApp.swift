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
    @Environment(\.scenePhase) private var scenePhase
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
        .overlay {
            if viewModel.cellularGuidance != .none {
                CellularGuidanceCard(viewModel: viewModel)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.appDidBecomeActive() }
        }
    }
}

/// WrapPin-style mobile-data guidance card. Shown on top of the tab view whenever
/// the system-level session is negotiating a cellular connection.
private struct CellularGuidanceCard: View {
    @ObservedObject var viewModel: RelocViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.cellularGuidance == .turnOffData {
                Text(viewModel.cellularDiscoveryStatus)
                    .font(.caption)
                    .foregroundStyle(RelocTheme.accent)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                if viewModel.cellularGuidance == .turnBackOnData {
                    Button("知道了") {
                        viewModel.dismissCellularGuidance()
                    }
                    .buttonStyle(.borderedProminent)
                } else if viewModel.cellularGuidance == .turnOffData {
                    Button("取消") {
                        viewModel.stopAndRestore()
                    }
                    .buttonStyle(.bordered)
                    Button("已关闭数据，继续") {
                        viewModel.userDidTurnOffMobileData()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("取消") {
                        viewModel.stopAndRestore()
                    }
                    .buttonStyle(.bordered)
                    Button("重试") {
                        viewModel.retryCellularConnection()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 28)
    }

    private var title: String {
        switch viewModel.cellularGuidance {
        case .turnOffData: return "蜂窝网络定位设置"
        case .turnBackOnData: return "定位已建立"
        case .connectionHelp: return "连接未成功"
        case .none: return ""
        }
    }

    private var message: String {
        switch viewModel.cellularGuidance {
        case .turnOffData:
            return "请保持外部代理的 10.7.0.1 隧道连接，然后临时关闭这台 iPhone 的蜂窝数据，再返回 Reloc。App 会自动发现设备并开始定位；成功后会提示你恢复数据。"
        case .turnBackOnData:
            return "定位模拟已开始。现在可以重新打开蜂窝数据，模拟会继续通过 5G 运行。"
        case .connectionHelp:
            return viewModel.cellularDiscoveryStatus.isEmpty
                ? "请确认代理隧道已连接并重试。"
                : viewModel.cellularDiscoveryStatus
        case .none: return ""
        }
    }

    private var iconName: String {
        switch viewModel.cellularGuidance {
        case .turnOffData: return "antenna.radiowaves.left.and.right"
        case .turnBackOnData: return "checkmark.circle.fill"
        case .connectionHelp: return "exclamationmark.triangle.fill"
        case .none: return "questionmark"
        }
    }

    private var tint: Color {
        switch viewModel.cellularGuidance {
        case .turnBackOnData: return RelocTheme.emerald
        case .connectionHelp: return RelocTheme.amber
        default: return RelocTheme.accent
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
