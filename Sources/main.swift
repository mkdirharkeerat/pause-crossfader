import Cocoa
import CoreAudio
import Foundation
import Darwin

// MARK: - Supported Music Players
enum MusicPlayerTarget: String, CaseIterable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"
    
    var appName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }
    
    var icon: String {
        switch self {
        case .spotify: return "󰝚"
        case .appleMusic: return "󰎆"
        }
    }
}

// MARK: - Configuration & Preferences
class CrossfaderConfig {
    static let shared = CrossfaderConfig()
    private let defaults = UserDefaults.standard
    
    var isEnabled: Bool {
        get { defaults.object(forKey: "crossfade_enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "crossfade_enabled") }
    }
    
    var activePlayer: MusicPlayerTarget {
        get {
            let raw = defaults.string(forKey: "active_music_player") ?? MusicPlayerTarget.spotify.rawValue
            return MusicPlayerTarget(rawValue: raw) ?? .spotify
        }
        set { defaults.set(newValue.rawValue, forKey: "active_music_player") }
    }
    
    var targetVolume: Int {
        get { defaults.object(forKey: "target_volume") as? Int ?? 85 }
        set { defaults.set(newValue, forKey: "target_volume") }
    }
    
    var fadeInDuration: Double {
        get { defaults.object(forKey: "fade_in_duration") as? Double ?? 2.5 }
        set { defaults.set(newValue, forKey: "fade_in_duration") }
    }
    
    var fadeOutDuration: Double {
        get { defaults.object(forKey: "fade_out_duration") as? Double ?? 1.2 }
        set { defaults.set(newValue, forKey: "fade_out_duration") }
    }
    
    var debounceDelay: Double {
        get { defaults.object(forKey: "debounce_delay") as? Double ?? 0.90 }
        set { defaults.set(newValue, forKey: "debounce_delay") }
    }
    
    var monitorAllBrowsers: Bool {
        get { defaults.object(forKey: "monitor_all_browsers") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "monitor_all_browsers") }
    }
}

// MARK: - High-Performance CoreAudio HAL Browser Monitor
class BrowserAudioMonitor {
    static let shared = BrowserAudioMonitor()
    
    private let allBrowserSignatures = [
        "firefox", "chrome", "safari", "brave", "arc", "edge", "com.apple.webkit.gpu"
    ]
    
    private var cachedObjects: [(id: AudioObjectID, pid: pid_t)] = []
    private var lastFullScanTime: TimeInterval = 0
    private var lastAllBrowsersSetting: Bool = false
    
    func isBrowserAudioActive(allBrowsers: Bool = false) -> (isActive: Bool, activePIDs: [pid_t]) {
        let now = Date().timeIntervalSince1970
        
        if now - lastFullScanTime > 2.0 || allBrowsers != lastAllBrowsersSetting || cachedObjects.isEmpty {
            refreshProcessCache(allBrowsers: allBrowsers)
            lastFullScanTime = now
            lastAllBrowsersSetting = allBrowsers
        }
        
        var activePIDs = [pid_t]()
        var needsReScan = false
        
        for item in cachedObjects {
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(item.id, &runningAddr, 0, nil, &runSize, &isRunning)
            if status == noErr {
                if isRunning == 1 {
                    activePIDs.append(item.pid)
                }
            } else {
                needsReScan = true
            }
        }
        
        if needsReScan {
            refreshProcessCache(allBrowsers: allBrowsers)
        }
        
        return (!activePIDs.isEmpty, activePIDs)
    }
    
    private func refreshProcessCache(allBrowsers: Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return
        }
        
        var newCache: [(id: AudioObjectID, pid: pid_t)] = []
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        
        for id in processIDs {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }
            
            let res = proc_pidpath(pid, buf, 4096)
            guard res > 0 else { continue }
            let path = String(cString: buf).lowercased()
            
            let matches: Bool
            if allBrowsers {
                matches = allBrowserSignatures.contains(where: { path.contains($0) })
            } else {
                matches = path.contains("firefox")
            }
            
            if matches {
                newCache.append((id, pid))
            }
        }
        cachedObjects = newCache
    }
}

// MARK: - Generic Music Player Controller (Spotify & Apple Music)
class MusicPlayerController {
    static let shared = MusicPlayerController()
    
    private let serialQueue = DispatchQueue(label: "com.crossfader.music.fader", qos: .userInteractive)
    private var currentFadeTask: DispatchWorkItem? = nil
    
    private var targetPlayer: MusicPlayerTarget {
        return CrossfaderConfig.shared.activePlayer
    }
    
    var isRunning: Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: targetPlayer.bundleIdentifier)
        return !apps.isEmpty
    }
    
    @discardableResult
    func executeScript(_ source: String) -> String? {
        guard isRunning else { return nil }
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        return result?.stringValue
    }
    
    func getPlayerState() -> String {
        let app = targetPlayer.appName
        return executeScript("tell application \"\(app)\" to player state as string") ?? "paused"
    }
    
    func getVolume() -> Int {
        guard isRunning else { return CrossfaderConfig.shared.targetVolume }
        let app = targetPlayer.appName
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"\(app)\" to sound volume")
        let result = script?.executeAndReturnError(&error)
        return Int(result?.int32Value ?? 85)
    }
    
    func setVolume(_ volume: Int) {
        guard isRunning else { return }
        let app = targetPlayer.appName
        let clamped = max(0, min(100, volume))
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"\(app)\" to set sound volume to \(clamped)")
        _ = script?.executeAndReturnError(&error)
    }
    
    func play() {
        guard isRunning else { return }
        let app = targetPlayer.appName
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"\(app)\" to play")
        _ = script?.executeAndReturnError(&error)
    }
    
    func pause() {
        guard isRunning else { return }
        let app = targetPlayer.appName
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"\(app)\" to pause")
        _ = script?.executeAndReturnError(&error)
    }
    
    // MARK: - Smooth Ease-In
    func fadeIn(targetVolume: Int, duration: Double, completion: (() -> Void)? = nil) {
        serialQueue.async { [weak self] in
            guard let self = self, self.isRunning else {
                completion?()
                return
            }
            
            self.currentFadeTask?.cancel()
            
            // Set volume to 0 before starting to avoid audio burst
            self.setVolume(0)
            self.play()
            
            let steps = max(15, Int(round(duration * 10)))
            let stepInterval = max(0.02, duration / Double(steps))
            
            let task = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                for i in 1...steps {
                    if self.currentFadeTask?.isCancelled == true { break }
                    
                    let progress = Double(i) / Double(steps)
                    let easedProgress = 1.0 - pow(1.0 - progress, 2.0)
                    let stepVol = Int(round(Double(targetVolume) * easedProgress))
                    self.setVolume(stepVol)
                    
                    Thread.sleep(forTimeInterval: stepInterval)
                }
                if self.currentFadeTask?.isCancelled != true {
                    self.setVolume(targetVolume)
                }
                completion?()
            }
            
            self.currentFadeTask = task
            task.perform()
        }
    }
    
    // MARK: - Smooth Ease-Out
    func fadeOut(duration: Double, restoreVolume: Int, completion: (() -> Void)? = nil) {
        serialQueue.async { [weak self] in
            guard let self = self, self.isRunning else {
                completion?()
                return
            }
            
            self.currentFadeTask?.cancel()
            
            let startVol = self.getVolume()
            if startVol <= 2 {
                self.pause()
                self.setVolume(restoreVolume)
                completion?()
                return
            }
            
            let steps = max(14, Int(round(duration * 10)))
            let stepInterval = max(0.02, duration / Double(steps))
            
            let task = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                for i in 1...steps {
                    if self.currentFadeTask?.isCancelled == true { break }
                    
                    let progress = Double(i) / Double(steps)
                    let remaining = 1.0 - progress
                    let stepVol = max(0, Int(round(Double(startVol) * (remaining * remaining))))
                    self.setVolume(stepVol)
                    
                    Thread.sleep(forTimeInterval: stepInterval)
                }
                
                if self.currentFadeTask?.isCancelled != true {
                    self.setVolume(0)
                    self.pause()
                    Thread.sleep(forTimeInterval: 0.05)
                    self.setVolume(restoreVolume)
                }
                completion?()
            }
            
            self.currentFadeTask = task
            task.perform()
        }
    }
}

// MARK: - Main Crossfader Engine
class CrossfaderEngine {
    static let shared = CrossfaderEngine()
    
    enum State: CustomStringConvertible {
        case idleSilent
        case browserPlaying
        case debouncingPause
        case musicCrossfadingIn
        case musicPlaying
        case musicCrossfadingOut
        
        var description: String {
            let player = CrossfaderConfig.shared.activePlayer.appName
            switch self {
            case .idleSilent: return "Idle (Waiting for YouTube)"
            case .browserPlaying: return "YouTube Playing (\(player) Muted)"
            case .debouncingPause: return "YouTube Paused (Debouncing...)"
            case .musicCrossfadingIn: return "Fading In \(player)..."
            case .musicPlaying: return "YouTube Paused (\(player) Playing)"
            case .musicCrossfadingOut: return "YouTube Resumed (Fading Out \(player)...)"
            }
        }
    }
    
    private(set) var currentState: State = .idleSilent {
        didSet {
            onStateChanged?(currentState)
        }
    }
    
    var onStateChanged: ((State) -> Void)?
    
    private var wasBrowserActive: Bool = false
    private var didWeStartMusic: Bool = false
    private var debounceWorkItem: DispatchWorkItem? = nil
    private var pollTimer: Timer? = nil
    
    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }
    
    private func tick() {
        guard CrossfaderConfig.shared.isEnabled else { return }
        
        let allBrowsers = CrossfaderConfig.shared.monitorAllBrowsers
        let (isBrowserNowActive, _) = BrowserAudioMonitor.shared.isBrowserAudioActive(allBrowsers: allBrowsers)
        
        if isBrowserNowActive {
            if debounceWorkItem != nil {
                debounceWorkItem?.cancel()
                debounceWorkItem = nil
            }
            
            if !wasBrowserActive || didWeStartMusic || currentState == .musicPlaying || currentState == .musicCrossfadingIn {
                wasBrowserActive = true
                if MusicPlayerController.shared.isRunning {
                    let playerState = MusicPlayerController.shared.getPlayerState()
                    if playerState == "playing" || didWeStartMusic {
                        currentState = .musicCrossfadingOut
                        didWeStartMusic = false
                        let fadeOutSec = CrossfaderConfig.shared.fadeOutDuration
                        let targetVol = CrossfaderConfig.shared.targetVolume
                        MusicPlayerController.shared.fadeOut(duration: fadeOutSec, restoreVolume: targetVol) { [weak self] in
                            DispatchQueue.main.async {
                                self?.currentState = .browserPlaying
                            }
                        }
                        return
                    }
                }
                currentState = .browserPlaying
            }
        } else {
            if wasBrowserActive {
                if debounceWorkItem == nil && currentState != .musicPlaying && currentState != .musicCrossfadingIn {
                    currentState = .debouncingPause
                    let delay = CrossfaderConfig.shared.debounceDelay
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        let (stillActive, _) = BrowserAudioMonitor.shared.isBrowserAudioActive(allBrowsers: allBrowsers)
                        if !stillActive {
                            self.triggerMusicFadeIn()
                        } else {
                            self.currentState = .browserPlaying
                        }
                        self.debounceWorkItem = nil
                    }
                    self.debounceWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                }
            } else {
                if currentState != .musicPlaying && currentState != .musicCrossfadingIn && currentState != .musicCrossfadingOut {
                    currentState = .idleSilent
                }
            }
        }
    }
    
    private func triggerMusicFadeIn() {
        guard MusicPlayerController.shared.isRunning else {
            currentState = .idleSilent
            return
        }
        
        currentState = .musicCrossfadingIn
        didWeStartMusic = true
        let targetVol = CrossfaderConfig.shared.targetVolume
        let fadeInSec = CrossfaderConfig.shared.fadeInDuration
        
        MusicPlayerController.shared.fadeIn(targetVolume: targetVol, duration: fadeInSec) { [weak self] in
            DispatchQueue.main.async {
                self?.currentState = .musicPlaying
            }
        }
    }
    
    func manualFadeIn() {
        wasBrowserActive = true
        triggerMusicFadeIn()
    }
    
    func manualFadeOut() {
        let fadeOutSec = CrossfaderConfig.shared.fadeOutDuration
        let targetVol = CrossfaderConfig.shared.targetVolume
        currentState = .musicCrossfadingOut
        didWeStartMusic = false
        MusicPlayerController.shared.fadeOut(duration: fadeOutSec, restoreVolume: targetVol) { [weak self] in
            DispatchQueue.main.async {
                self?.currentState = .idleSilent
            }
        }
    }
}

// MARK: - Menu Bar Application Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var enableMenuItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        
        CrossfaderEngine.shared.onStateChanged = { [weak self] newState in
            DispatchQueue.main.async {
                self?.updateStatusUI(newState)
            }
        }
        
        CrossfaderEngine.shared.start()
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Pause Crossfader") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🎧"
            }
        }
        
        buildMenu()
    }
    
    private func buildMenu() {
        let menu = NSMenu()
        
        // Header
        let activeAppName = CrossfaderConfig.shared.activePlayer.appName
        let titleItem = NSMenuItem(title: "YT ⇄ \(activeAppName) Crossfader", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: 13)
        titleItem.attributedTitle = NSAttributedString(string: "YT ⇄ \(activeAppName) Crossfader", attributes: [.font: font])
        menu.addItem(titleItem)
        
        // Live Status
        statusMenuItem = NSMenuItem(title: "Status: Idle (Waiting for YouTube)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        // Toggle Enable
        enableMenuItem = NSMenuItem(title: "Auto-Crossfade Active", action: #selector(toggleEnabled), keyEquivalent: "e")
        enableMenuItem.target = self
        enableMenuItem.state = CrossfaderConfig.shared.isEnabled ? .on : .off
        menu.addItem(enableMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        // Submenu: Music Player Selection (Spotify vs Apple Music)
        let playerSubmenu = NSMenu()
        for player in MusicPlayerTarget.allCases {
            let item = NSMenuItem(title: player.rawValue, action: #selector(selectMusicPlayer(_:)), keyEquivalent: "")
            item.representedObject = player
            item.target = self
            item.state = (CrossfaderConfig.shared.activePlayer == player) ? .on : .off
            playerSubmenu.addItem(item)
        }
        let playerParent = NSMenuItem(title: "Music Player App", action: nil, keyEquivalent: "")
        playerParent.submenu = playerSubmenu
        menu.addItem(playerParent)
        
        // Submenu: Target Browser
        let browserSubmenu = NSMenu()
        let firefoxItem = NSMenuItem(title: "Firefox (Default)", action: #selector(selectBrowserFirefox), keyEquivalent: "")
        firefoxItem.target = self
        firefoxItem.state = !CrossfaderConfig.shared.monitorAllBrowsers ? .on : .off
        browserSubmenu.addItem(firefoxItem)
        
        let allBrowsersItem = NSMenuItem(title: "All Web Browsers (Firefox, Chrome, Safari, Brave)", action: #selector(selectBrowserAll), keyEquivalent: "")
        allBrowsersItem.target = self
        allBrowsersItem.state = CrossfaderConfig.shared.monitorAllBrowsers ? .on : .off
        browserSubmenu.addItem(allBrowsersItem)
        
        let browserParent = NSMenuItem(title: "Target Browser", action: nil, keyEquivalent: "")
        browserParent.submenu = browserSubmenu
        menu.addItem(browserParent)
        
        // Submenu: Target Volume
        let volumeSubmenu = NSMenu()
        for vol in [100, 85, 70, 50] {
            let label = vol == 85 ? "\(vol)% (Recommended)" : "\(vol)%"
            let item = NSMenuItem(title: label, action: #selector(selectTargetVolume(_:)), keyEquivalent: "")
            item.tag = vol
            item.target = self
            item.state = (CrossfaderConfig.shared.targetVolume == vol) ? .on : .off
            volumeSubmenu.addItem(item)
        }
        let volumeParent = NSMenuItem(title: "Music Target Volume", action: nil, keyEquivalent: "")
        volumeParent.submenu = volumeSubmenu
        menu.addItem(volumeParent)
        
        // Submenu: Debounce Delay (Anti-Scrub) + Custom Input
        let debounceSubmenu = NSMenu()
        let debounceOptions: [(Double, String)] = [
            (0.3, "300 ms (Fast)"),
            (0.6, "600 ms (Balanced)"),
            (0.9, "900 ms (Recommended)"),
            (1.2, "1200 ms (Scrub-safe)"),
            (1.6, "1600 ms (Patient)")
        ]
        for (sec, label) in debounceOptions {
            let item = NSMenuItem(title: label, action: #selector(selectDebouncePreset(_:)), keyEquivalent: "")
            item.representedObject = sec
            item.target = self
            item.state = (abs(CrossfaderConfig.shared.debounceDelay - sec) < 0.05) ? .on : .off
            debounceSubmenu.addItem(item)
        }
        debounceSubmenu.addItem(NSMenuItem.separator())
        let customDebounceMs = Int(round(CrossfaderConfig.shared.debounceDelay * 1000.0))
        let customDebounceItem = NSMenuItem(title: "⚙ Custom Debounce (Current: \(customDebounceMs)ms)...", action: #selector(promptCustomDebounce), keyEquivalent: "")
        customDebounceItem.target = self
        debounceSubmenu.addItem(customDebounceItem)
        
        let debounceParent = NSMenuItem(title: "Debounce Delay (Scrub Filter)", action: nil, keyEquivalent: "")
        debounceParent.submenu = debounceSubmenu
        menu.addItem(debounceParent)
        
        // Submenu: Fade In Duration + Custom Input
        let fadeInSubmenu = NSMenu()
        let fadeInOptions: [(Double, String)] = [
            (0.8, "0.8s (Quick)"),
            (1.5, "1.5s (Smooth)"),
            (2.5, "2.5s (Gentle & Slow - Recommended)"),
            (3.5, "3.5s (Lush Ambient)"),
            (5.0, "5.0s (Very Slow)")
        ]
        for (sec, label) in fadeInOptions {
            let item = NSMenuItem(title: label, action: #selector(selectFadeInPreset(_:)), keyEquivalent: "")
            item.representedObject = sec
            item.target = self
            item.state = (abs(CrossfaderConfig.shared.fadeInDuration - sec) < 0.1) ? .on : .off
            fadeInSubmenu.addItem(item)
        }
        fadeInSubmenu.addItem(NSMenuItem.separator())
        let customFadeInMs = Int(round(CrossfaderConfig.shared.fadeInDuration * 1000.0))
        let customFadeInItem = NSMenuItem(title: "⚙ Custom Fade-In (Current: \(customFadeInMs)ms)...", action: #selector(promptCustomFadeIn), keyEquivalent: "")
        customFadeInItem.target = self
        fadeInSubmenu.addItem(customFadeInItem)
        
        let fadeInParent = NSMenuItem(title: "Fade-In Duration (on Pause)", action: nil, keyEquivalent: "")
        fadeInParent.submenu = fadeInSubmenu
        menu.addItem(fadeInParent)
        
        // Submenu: Fade Out Duration + Custom Input
        let fadeOutSubmenu = NSMenu()
        let fadeOutOptions: [(Double, String)] = [
            (0.6, "0.6s (Snappy)"),
            (1.2, "1.2s (Smooth)"),
            (1.8, "1.8s (Gentle)"),
            (2.5, "2.5s (Slow)")
        ]
        for (sec, label) in fadeOutOptions {
            let item = NSMenuItem(title: label, action: #selector(selectFadeOutPreset(_:)), keyEquivalent: "")
            item.representedObject = sec
            item.target = self
            item.state = (abs(CrossfaderConfig.shared.fadeOutDuration - sec) < 0.1) ? .on : .off
            fadeOutSubmenu.addItem(item)
        }
        fadeOutSubmenu.addItem(NSMenuItem.separator())
        let customFadeOutMs = Int(round(CrossfaderConfig.shared.fadeOutDuration * 1000.0))
        let customFadeOutItem = NSMenuItem(title: "⚙ Custom Fade-Out (Current: \(customFadeOutMs)ms)...", action: #selector(promptCustomFadeOut), keyEquivalent: "")
        customFadeOutItem.target = self
        fadeOutSubmenu.addItem(customFadeOutItem)
        
        let fadeOutParent = NSMenuItem(title: "Fade-Out Duration (on Resume)", action: nil, keyEquivalent: "")
        fadeOutParent.submenu = fadeOutSubmenu
        menu.addItem(fadeOutParent)
        
        menu.addItem(NSMenuItem.separator())
        
        // Manual Action Tests
        let testFadeIn = NSMenuItem(title: "▶ Test Fade-In \(activeAppName) Now", action: #selector(testFadeInAction), keyEquivalent: "")
        testFadeIn.target = self
        menu.addItem(testFadeIn)
        
        let testFadeOut = NSMenuItem(title: "⏸ Test Fade-Out \(activeAppName) Now", action: #selector(testFadeOutAction), keyEquivalent: "")
        testFadeOut.target = self
        menu.addItem(testFadeOut)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Crossfader", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    private func updateStatusUI(_ state: CrossfaderEngine.State) {
        statusMenuItem?.title = "Status: \(state.description)"
        
        if let button = statusItem?.button {
            switch state {
            case .musicPlaying:
                button.title = " 󰝚"
            case .musicCrossfadingIn, .musicCrossfadingOut:
                button.title = " 󰓃"
            default:
                button.title = ""
            }
        }
    }
    
    @objc private func toggleEnabled() {
        let current = CrossfaderConfig.shared.isEnabled
        CrossfaderConfig.shared.isEnabled = !current
        enableMenuItem?.state = !current ? .on : .off
    }
    
    @objc private func selectMusicPlayer(_ sender: NSMenuItem) {
        if let player = sender.representedObject as? MusicPlayerTarget {
            CrossfaderConfig.shared.activePlayer = player
            buildMenu()
        }
    }
    
    @objc private func selectBrowserFirefox() {
        CrossfaderConfig.shared.monitorAllBrowsers = false
        buildMenu()
    }
    
    @objc private func selectBrowserAll() {
        CrossfaderConfig.shared.monitorAllBrowsers = true
        buildMenu()
    }
    
    @objc private func selectTargetVolume(_ sender: NSMenuItem) {
        CrossfaderConfig.shared.targetVolume = sender.tag
        buildMenu()
    }
    
    @objc private func selectDebouncePreset(_ sender: NSMenuItem) {
        if let sec = sender.representedObject as? Double {
            CrossfaderConfig.shared.debounceDelay = sec
            buildMenu()
        }
    }
    
    @objc private func selectFadeInPreset(_ sender: NSMenuItem) {
        if let sec = sender.representedObject as? Double {
            CrossfaderConfig.shared.fadeInDuration = sec
            buildMenu()
        }
    }
    
    @objc private func selectFadeOutPreset(_ sender: NSMenuItem) {
        if let sec = sender.representedObject as? Double {
            CrossfaderConfig.shared.fadeOutDuration = sec
            buildMenu()
        }
    }
    
    // MARK: - Native Custom Input Dialogs
    @objc private func promptCustomDebounce() {
        let currentMs = Int(round(CrossfaderConfig.shared.debounceDelay * 1000.0))
        if let input = showPromptDialog(title: "Custom Debounce Delay", message: "Enter debounce delay in milliseconds (e.g. 850):", defaultValue: "\(currentMs)") {
            if let ms = Double(input), ms >= 50 && ms <= 10000 {
                CrossfaderConfig.shared.debounceDelay = ms / 1000.0
                buildMenu()
            }
        }
    }
    
    @objc private func promptCustomFadeIn() {
        let currentMs = Int(round(CrossfaderConfig.shared.fadeInDuration * 1000.0))
        if let input = showPromptDialog(title: "Custom Fade-In Duration", message: "Enter fade-in duration in milliseconds (e.g. 2500):", defaultValue: "\(currentMs)") {
            if let ms = Double(input), ms >= 100 && ms <= 30000 {
                CrossfaderConfig.shared.fadeInDuration = ms / 1000.0
                buildMenu()
            }
        }
    }
    
    @objc private func promptCustomFadeOut() {
        let currentMs = Int(round(CrossfaderConfig.shared.fadeOutDuration * 1000.0))
        if let input = showPromptDialog(title: "Custom Fade-Out Duration", message: "Enter fade-out duration in milliseconds (e.g. 1200):", defaultValue: "\(currentMs)") {
            if let ms = Double(input), ms >= 100 && ms <= 30000 {
                CrossfaderConfig.shared.fadeOutDuration = ms / 1000.0
                buildMenu()
            }
        }
    }
    
    private func showPromptDialog(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    
    @objc private func testFadeInAction() {
        CrossfaderEngine.shared.manualFadeIn()
    }
    
    @objc private func testFadeOutAction() {
        CrossfaderEngine.shared.manualFadeOut()
    }
    
    @objc private func quitApp() {
        CrossfaderEngine.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - App Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
