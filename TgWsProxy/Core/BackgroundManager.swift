import Foundation
import Combine
import UIKit
import AVFoundation
import CoreLocation

final class BackgroundManager: NSObject, ObservableObject {
    static let shared = BackgroundManager()

    @Published private(set) var isBackgroundActive = false

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?
    private var locationManager: CLLocationManager?
    private var bgRefreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        registerLifecycleObservers()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func startBackgroundTask() {
        guard !isBackgroundActive else {
            ensureBackgroundServicesRunning()
            return
        }

        isBackgroundActive = true
        ensureBackgroundServicesRunning()
        NSLog("[Background] Proxy background protection started")
    }

    func stopBackgroundTask() {
        isBackgroundActive = false
        endBackgroundTask()
        stopSilentAudio()
        stopLocationUpdates()
        stopKeepAliveTimer()
        stopBackgroundRefresh()
        NSLog("[Background] Proxy background protection stopped")
    }

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isBackgroundActive else { return }
            NSLog("[Background] App entered background - keeping proxy services active")
            self.ensureBackgroundServicesRunning()
        })

        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isBackgroundActive else { return }
            NSLog("[Background] App entering foreground - restoring proxy services")
            self.ensureBackgroundServicesRunning()
        })

        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isBackgroundActive else { return }
            self.ensureBackgroundServicesRunning()
        })
    }

    private func ensureBackgroundServicesRunning() {
        guard isBackgroundActive else { return }

        beginBackgroundTask()
        startSilentAudio()
        startLocationUpdates()
        startKeepAliveTimer()
        startBackgroundRefresh()
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        guard bgTask == .invalid else { return }

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "TgWsProxyKeepAlive") { [weak self] in
            NSLog("[Background] System background task expired")
            self?.bgTask = .invalid

            // Audio/location are the mechanisms intended to keep this service alive.
            // Re-arm the task without stopping the proxy itself.
            guard let self = self, self.isBackgroundActive else { return }
            self.beginBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Background audio

    private func startSilentAudio() {
        guard audioPlayer?.isPlaying != true else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])

            if let url = Bundle.main.url(forResource: "silence", withExtension: "mp3") {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
            } else {
                audioPlayer = try createSilentAudioFile()
            }

            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.001
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            NSLog("[Background] Silent audio keep-alive started")
        } catch {
            NSLog("[Background] Audio keep-alive error: \(error)")
        }
    }

    private func createSilentAudioFile() throws -> AVAudioPlayer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("tgwsproxy_silence.caf")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            if let channelData = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) {
                    channelData[i] = 0.0001
                }
            }
            try file.write(from: buffer)
        }

        return try AVAudioPlayer(contentsOf: fileURL)
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Location

    private func startLocationUpdates() {
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = false
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            manager.distanceFilter = 1000
            locationManager = manager
        }

        guard let manager = locationManager else { return }

        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }

        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    private func stopLocationUpdates() {
        locationManager?.stopUpdatingLocation()
        locationManager = nil
    }

    // MARK: - Keep alive timers

    private func startKeepAliveTimer() {
        guard keepAliveTimer == nil else { return }
        let timer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isBackgroundActive else { return }
            self.beginBackgroundTask()
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func startBackgroundRefresh() {
        guard bgRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isBackgroundActive else { return }
            self.beginBackgroundTask()
            self.startSilentAudio()
            self.startLocationUpdates()
        }
        RunLoop.main.add(timer, forMode: .common)
        bgRefreshTimer = timer
    }

    private func stopBackgroundRefresh() {
        bgRefreshTimer?.invalidate()
        bgRefreshTimer = nil
    }
}

extension BackgroundManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        NSLog("[Background] Location update received")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[Background] Location error: \(error)")
    }
}
