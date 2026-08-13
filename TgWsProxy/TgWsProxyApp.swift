import SwiftUI

@main
struct TgWsProxyApp: App {
    @StateObject private var proxyManager = ProxyManager.shared
    @StateObject private var settings = SettingsStore()
    @StateObject private var logManager = LogManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(proxyManager)
                .environmentObject(settings)
                .environmentObject(logManager)
                .preferredColorScheme(AppTheme(from: settings.themeMode).colorScheme)
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "tgwsproxy" else { return }

        if !proxyManager.isRunning {
            startProxy()
        }
    }

    private func startProxy() {
        let dcIps = settings.buildDcIps()
        let port = Int(settings.port) ?? 1443
        let cfDomain = settings.customCfDomainEnabled ? settings.customCfDomain : ""

        DispatchQueue.global(qos: .userInitiated).async {
            _ = proxyManager.start(
                port: port,
                dcIps: dcIps,
                poolSize: settings.poolSize,
                cfEnabled: settings.cfproxyEnabled,
                cfPriority: true,
                cfDomain: cfDomain,
                secretKey: settings.secretKey
            )
        }
    }
}
