import Foundation
import Combine
import os.log

struct ProxyStats {
    var total: Int64 = 0
    var active: Int64 = 0
    var ws: Int64 = 0
    var tcpFallback: Int64 = 0
    var cfproxy: Int64 = 0
    var bad: Int64 = 0
    var errors: Int64 = 0
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
    var poolHits: Int64 = 0
    var poolMisses: Int64 = 0

    var description: String {
        var parts: [String] = []
        parts.append("act:\(active)")
        if ws > 0 { parts.append("ws:\(ws)") }
        if cfproxy > 0 { parts.append("cf:\(cfproxy)") }
        if tcpFallback > 0 { parts.append("tcp:\(tcpFallback)") }
        if errors > 0 { parts.append("err:\(errors)") }
        parts.append("↑\(formatBytes(bytesUp)) ↓\(formatBytes(bytesDown))")
        return parts.joined(separator: " | ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        if absBytes < 1024 { return "\(bytes)B" }
        if absBytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        if absBytes < 1024 * 1024 * 1024 { return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0)) }
        return String(format: "%.2fGB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }
}

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning = false
    @Published var stats = ProxyStats()

    private var statsTimer: Timer?
    private let statsQueue = DispatchQueue(label: "com.tgwsproxy.stats", qos: .utility)
    private let logger = Logger(subsystem: "com.tgwsproxy", category: "Proxy")

    private init() {}

    func start(port: Int, dcIps: String, poolSize: Int, cfEnabled: Bool, cfPriority: Bool, cfDomain: String, secretKey: String) -> Bool {
        guard !isRunning else {
            logger.info("Start requested while proxy is already running")
            return false
        }

        logger.info("Starting proxy: port=\(port), pool=\(poolSize), cf=\(cfEnabled), cfPriority=\(cfPriority), dcIps=\(dcIps, privacy: .private(mask: .hash)), secretConfigured=\(!secretKey.isEmpty)")

        SetPoolSize(Int32(poolSize))
        SetCfProxyCacheDir(cachesDirectory().path)
        SetCfProxyConfig(cfEnabled ? 1 : 0, cfPriority ? 1 : 0, cfDomain)

        logger.debug("Native proxy configuration applied")
        let host = "127.0.0.1"
        let result = StartProxy(host, Int32(port), dcIps, secretKey, 1)
        logger.info("StartProxy returned \(result)")

        if result == 0 {
            DispatchQueue.main.async {
                self.isRunning = true
                BackgroundManager.shared.startBackgroundTask()
            }
            startStatsPolling()
            if let initial = getStats() {
                DispatchQueue.main.async { self.stats = initial }
                logger.info("Initial stats: \(initial.description, privacy: .public)")
            } else {
                logger.error("GetStats returned nil immediately after StartProxy")
            }
            return true
        }

        logger.error("Proxy failed to start, result=\(result)")
        return false
    }

    func stop() {
        guard isRunning else {
            logger.info("Stop requested while proxy is not running")
            return
        }

        logger.info("Stopping proxy")
        stopStatsPolling()
        statsQueue.async {
            StopProxy()
            self.logger.info("StopProxy completed")
            DispatchQueue.main.async {
                self.isRunning = false
                self.stats = ProxyStats()
                BackgroundManager.shared.stopBackgroundTask()
            }
        }
    }

    func getSecretWithPrefix() -> String? {
        guard let ptr = GetSecretWithPrefix() else {
            logger.error("GetSecretWithPrefix returned nil")
            return nil
        }
        let result = String(cString: ptr)
        FreeString(ptr)
        return result
    }

    func getStats() -> ProxyStats? {
        guard let ptr = GetStats() else {
            logger.error("GetStats returned nil")
            return nil
        }
        let raw = String(cString: ptr)
        FreeString(ptr)
        logger.debug("GetStats raw: \(raw, privacy: .public)")
        return parseStats(raw)
    }

    private func startStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                self.statsQueue.async {
                    guard let newStats = self.getStats() else { return }
                    DispatchQueue.main.async {
                        self.stats = newStats
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.statsTimer = timer
            self.logger.info("Live stats polling started")
        }
    }

    private func stopStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = nil
            self.logger.info("Live stats polling stopped")
        }
    }

    private func parseStats(_ raw: String) -> ProxyStats {
        var s = ProxyStats()
        s.total = extractStat(raw, key: "total=") ?? 0
        s.active = extractStat(raw, key: "active=") ?? 0
        s.ws = extractStat(raw, key: "ws=") ?? 0
        s.tcpFallback = extractStat(raw, key: "tcp_fb=") ?? 0
        s.cfproxy = extractStat(raw, key: "cf=") ?? 0
        s.bad = extractStat(raw, key: "bad=") ?? 0
        s.errors = extractStat(raw, key: "err=") ?? 0
        s.poolHits = extractStat(raw, key: "pool=") ?? 0
        s.bytesUp = parseHumanBytes(extractString(raw, key: "up=") ?? "0B")
        s.bytesDown = parseHumanBytes(extractString(raw, key: "down=") ?? "0B")
        return s
    }

    private func extractStat(_ raw: String, key: String) -> Int64? {
        guard let range = raw.range(of: key) else { return nil }
        let start = range.upperBound
        let rest = String(raw[start...])
        let value = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        return Int64(value)
    }

    private func extractString(_ raw: String, key: String) -> String? {
        guard let range = raw.range(of: key) else { return nil }
        let start = range.upperBound
        let rest = String(raw[start...])
        return rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).first.map(String.init)
    }

    private func parseHumanBytes(_ s: String) -> Int64 {
        let numStr = s.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        let num = Double(numStr) ?? 0.0
        if s.hasSuffix("TB") { return Int64(num * 1024.0 * 1024.0 * 1024.0 * 1024.0) }
        if s.hasSuffix("GB") { return Int64(num * 1024.0 * 1024.0 * 1024.0) }
        if s.hasSuffix("MB") { return Int64(num * 1024.0 * 1024.0) }
        if s.hasSuffix("KB") { return Int64(num * 1024.0) }
        return Int64(num)
    }

    private func cachesDirectory() -> URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return paths[0]
    }
}
