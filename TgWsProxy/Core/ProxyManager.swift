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

final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning = false
    @Published var stats = ProxyStats()

    private var statsTimer: Timer?
    private let statsQueue = DispatchQueue(label: "com.tgwsproxy.stats", qos: .utility)
    private let logger = Logger(subsystem: "com.tgwsproxy", category: "Proxy")
    private let appLog = LogManager.shared

    private init() {}

    private func log(_ message: String, level: LogLevel = .info) {
        appLog.addLog(message, level: level)
        switch level {
        case .error: logger.error("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        }
    }

    func start(port: Int, dcIps: String, poolSize: Int, cfEnabled: Bool, cfPriority: Bool, cfDomain: String, secretKey: String) -> Bool {
        guard !isRunning else {
            log("Start requested while proxy is already running", level: .warn)
            return false
        }

        log("Starting proxy: port=\(port), pool=\(poolSize), cf=\(cfEnabled), cfPriority=\(cfPriority), dcIps=\(dcIps.isEmpty ? \"auto\" : dcIps), secretConfigured=\(!secretKey.isEmpty)")

        SetPoolSize(Int32(poolSize))
        SetCfProxyCacheDir(cachesDirectory().path)
        SetCfProxyConfig(cfEnabled ? 1 : 0, cfPriority ? 1 : 0, cfDomain)
        log("Native proxy configuration applied", level: .debug)

        let result = StartProxy("127.0.0.1", Int32(port), dcIps, secretKey, 1)
        log("StartProxy returned \(result)", level: result == 0 ? .info : .error)

        if result == 0 {
            DispatchQueue.main.async {
                self.isRunning = true
                BackgroundManager.shared.startBackgroundTask()
            }
            startStatsPolling()
            if let initial = getStats() {
                DispatchQueue.main.async { self.stats = initial }
                log("Initial stats: \(initial.description)")
            } else {
                log("GetStats returned nil immediately after StartProxy", level: .error)
            }
            return true
        }

        log("Proxy failed to start, result=\(result)", level: .error)
        return false
    }

    func stop() {
        guard isRunning else {
            log("Stop requested while proxy is not running", level: .warn)
            return
        }

        log("Stopping proxy")
        stopStatsPolling()
        statsQueue.async {
            StopProxy()
            self.log("StopProxy completed")
            DispatchQueue.main.async {
                self.isRunning = false
                self.stats = ProxyStats()
                BackgroundManager.shared.stopBackgroundTask()
            }
        }
    }

    func getSecretWithPrefix() -> String? {
        guard let ptr = GetSecretWithPrefix() else {
            log("GetSecretWithPrefix returned nil", level: .error)
            return nil
        }
        let result = String(cString: ptr)
        FreeString(ptr)
        return result
    }

    func getStats() -> ProxyStats? {
        guard let ptr = GetStats() else {
            log("GetStats returned nil", level: .error)
            return nil
        }
        let raw = String(cString: ptr)
        FreeString(ptr)
        log("GetStats raw: \(raw)", level: .debug)
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
            self.log("Live stats polling started")
        }
    }

    private func stopStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = nil
            self.log("Live stats polling stopped")
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
        let rest = String(raw[range.upperBound...])
        let value = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        return Int64(value)
    }

    private func extractString(_ raw: String, key: String) -> String? {
        guard let range = raw.range(of: key) else { return nil }
        let rest = String(raw[range.upperBound...])
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
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}
