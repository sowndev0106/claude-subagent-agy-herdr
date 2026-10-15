import Foundation
import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate, QuotaManagerDelegate {
    
    private var statusItem: NSStatusItem!
    private var displayMode: DisplayMode = .gemini5h
    private var refreshIntervalSeconds: Int = 120
    private var launchAtLogin: Bool = false
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Load preferences
        let savedMode = UserDefaults.standard.integer(forKey: "DisplayMode")
        if let mode = DisplayMode(rawValue: savedMode) {
            displayMode = mode
        }
        
        let savedInterval = UserDefaults.standard.integer(forKey: "RefreshIntervalSeconds")
        if savedInterval > 0 {
            refreshIntervalSeconds = savedInterval
        }
        
        launchAtLogin = checkLaunchAtLoginStatus()
        
        // Setup Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Agy Quota")
            button.imagePosition = .imageLeft
            button.title = " --%"
        }
        
        QuotaManager.shared.delegate = self
        QuotaManager.shared.loadData()
        
        updateStatusBarTitle()
        rebuildMenu()
    }
    
    // MARK: - QuotaManagerDelegate
    
    public func quotaManagerDidUpdate(profiles: [ProfileUsage], defaultProfile: ProfileUsage?, isRefreshing: Bool) {
        updateStatusBarTitle()
        rebuildMenu()
    }
    
    private func updateStatusBarTitle() {
        guard let button = statusItem.button else { return }
        let isRefreshing = QuotaManager.shared.isRefreshing
        let defaultProfile = QuotaManager.shared.defaultProfile
        
        guard let p = defaultProfile else {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Agy Quota")
            button.title = isRefreshing ? " ⟳" : " --%"
            return
        }
        
        let g5 = p.gemini5h.pct
        
        if isRefreshing {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Refreshing")
            button.title = " \(p.gemini5h.formattedPct)"
            return
        }
        
        if g5 >= 0 && g5 < 20 {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Low Quota")
        } else {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Agy Quota")
        }
        
        switch displayMode {
        case .gemini5h:
            button.title = " \(p.gemini5h.formattedPct)"
        case .geminiBoth:
            button.title = " \(p.gemini5h.formattedPct) · \(p.geminiWeek.formattedPct)"
        case .nameAndQuota:
            button.title = " \(p.name): \(p.gemini5h.formattedPct)"
        case .geminiAndClaude:
            button.title = " G:\(p.gemini5h.formattedPct) C:\(p.claude5h.formattedPct)"
        }
    }
    
    private func rebuildMenu() {
        let menu = MenuViewBuilder.buildMenu(
            profiles: QuotaManager.shared.profiles,
            defaultProfile: QuotaManager.shared.defaultProfile,
            isRefreshing: QuotaManager.shared.isRefreshing,
            lastUpdated: QuotaManager.shared.lastUpdated,
            target: self,
            displayMode: displayMode,
            refreshInterval: refreshIntervalSeconds,
            launchAtLogin: launchAtLogin
        )
        statusItem.menu = menu
    }
    
    // MARK: - Menu Actions
    
    @objc public func selectProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        QuotaManager.shared.switchProfile(name: name)
    }
    
    @objc public func switchAutoAction(_ sender: NSMenuItem) {
        QuotaManager.shared.switchAuto()
    }
    
    @objc public func refreshAction(_ sender: NSMenuItem) {
        QuotaManager.shared.refreshUsage(maxAge: 0)
    }
    
    @objc public func openDashboardAction(_ sender: NSMenuItem) {
        QuotaManager.shared.openDashboard()
    }
    
    @objc public func openTerminalForProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        QuotaManager.shared.openTerminal(profile: name)
    }
    
    @objc public func changeDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let mode = DisplayMode(rawValue: raw) else { return }
        displayMode = mode
        UserDefaults.standard.set(raw, forKey: "DisplayMode")
        updateStatusBarTitle()
        rebuildMenu()
    }
    
    @objc public func changeRefreshInterval(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Int else { return }
        refreshIntervalSeconds = sec
        UserDefaults.standard.set(sec, forKey: "RefreshIntervalSeconds")
        QuotaManager.shared.updateRefreshInterval(sec)
        rebuildMenu()
    }
    
    @objc public func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin = !launchAtLogin
        setLaunchAtLogin(enabled: launchAtLogin)
        rebuildMenu()
    }
    
    @objc public func quitAction(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Launch at Login Management
    
    private var launchAgentPlistPath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/LaunchAgents/dev.agy.menubar.plist"
    }
    
    private func checkLaunchAtLoginStatus() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentPlistPath)
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        let path = launchAgentPlistPath
        let fm = FileManager.default
        
        if enabled {
            let appPath = Bundle.main.bundlePath
            let executablePath: String
            if appPath.hasSuffix(".app") {
                executablePath = "\(appPath)/Contents/MacOS/AgyBar"
            } else {
                executablePath = CommandLine.arguments[0]
            }
            
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>dev.agy.menubar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(executablePath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
                <key>StandardErrorPath</key>
                <string>\(NSHomeDirectory())/.agy-profiles/.agy-bar.log</string>
            </dict>
            </plist>
            """
            
            let dir = (path as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plistContent.write(toFile: path, atomically: true, encoding: .utf8)
            
            // Register with launchctl
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["load", "-w", path]
            try? proc.run()
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["unload", "-w", path]
            try? proc.run()
            try? fm.removeItem(atPath: path)
        }
    }
}
