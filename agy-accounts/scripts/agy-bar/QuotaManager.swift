import Foundation
import AppKit

public protocol QuotaManagerDelegate: AnyObject {
    func quotaManagerDidUpdate(profiles: [ProfileUsage], defaultProfile: ProfileUsage?, isRefreshing: Bool)
}

public class QuotaManager {
    public static let shared = QuotaManager()
    
    public weak var delegate: QuotaManagerDelegate?
    
    public private(set) var profiles: [ProfileUsage] = []
    public private(set) var defaultProfile: ProfileUsage?
    public private(set) var isRefreshing: Bool = false
    public private(set) var lastUpdated: Date?
    
    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var refreshTimer: Timer?
    private var debounceTimer: Timer?
    
    public var rootDir: String {
        if let env = ProcessInfo.processInfo.environment["AGY_PROFILES_DIR"], !env.isEmpty {
            return env
        }
        return ("~/.agy-profiles" as NSString).expandingTildeInPath
    }
    
    public var usageTsvPath: String {
        return (rootDir as NSString).appendingPathComponent(".usage.tsv")
    }
    
    public var defaultFilePath: String {
        return (rootDir as NSString).appendingPathComponent(".default")
    }
    
    public var agyPPath: String {
        let homeLocalBin = ("~/.local/bin/agy-p" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: homeLocalBin) {
            return homeLocalBin
        }
        return "agy-p"
    }
    
    private init() {
        loadData()
        startWatching()
        setupTimer()
    }
    
    deinit {
        stopWatching()
        refreshTimer?.invalidate()
        debounceTimer?.invalidate()
    }
    
    // MARK: - Auto Refresh Timer
    
    public func updateRefreshInterval(_ seconds: Int) {
        refreshTimer?.invalidate()
        guard seconds > 0 else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            self?.refreshUsage(maxAge: seconds)
        }
    }
    
    private func setupTimer() {
        let interval = UserDefaults.standard.integer(forKey: "RefreshIntervalSeconds")
        updateRefreshInterval(interval > 0 ? interval : 120) // default 2 minutes
    }
    
    // MARK: - File System Monitoring
    
    private func startWatching() {
        stopWatching()
        
        let path = rootDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .link],
            queue: .main
        )
        
        source.setEventHandler { [weak self] in
            // Debounce so rapid file writes don't cause jitter
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                self?.loadData()
            }
        }
        
        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }
        
        source.resume()
        fileWatcherSource = source
    }
    
    private func stopWatching() {
        if let source = fileWatcherSource {
            source.cancel()
            fileWatcherSource = nil
        }
    }
    
    // MARK: - Loading & Parsing
    
    public func loadData() {
        let defaultName = readDefaultProfileName()
        let tsvPath = usageTsvPath
        
        guard FileManager.default.fileExists(atPath: tsvPath) else {
            // If file doesn't exist yet, trigger an initial fetch
            if !isRefreshing {
                refreshUsage(maxAge: 0)
            }
            return
        }
        
        do {
            let content = try String(contentsOfFile: tsvPath, encoding: .utf8)
            var list: [ProfileUsage] = []
            
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                
                let parts = trimmed.components(separatedBy: "\t")
                if parts.count >= 2 {
                    let name = parts[0]
                    let email = parts[1]
                    
                    func parseLimit(pctIndex: Int, resetIndex: Int) -> QuotaLimit {
                        let pctStr = parts.indices.contains(pctIndex) ? parts[pctIndex].trimmingCharacters(in: .whitespaces) : "-1"
                        let resetStr = parts.indices.contains(resetIndex) ? parts[resetIndex].trimmingCharacters(in: .whitespaces) : "-"
                        let pct = Int(pctStr) ?? -1
                        return QuotaLimit(pct: pct, resetISO: resetStr)
                    }
                    
                    let gw = parseLimit(pctIndex: 2, resetIndex: 6)
                    let g5 = parseLimit(pctIndex: 3, resetIndex: 7)
                    let cw = parseLimit(pctIndex: 4, resetIndex: 8)
                    let c5 = parseLimit(pctIndex: 5, resetIndex: 9)
                    
                    let usage = ProfileUsage(
                        name: name,
                        email: email,
                        geminiWeek: gw,
                        gemini5h: g5,
                        claudeWeek: cw,
                        claude5h: c5,
                        isDefault: (name == defaultName)
                    )
                    list.append(usage)
                }
            }
            
            // If defaultName wasn't marked in list, mark main if possible
            if !list.contains(where: { $0.isDefault }), let idx = list.firstIndex(where: { $0.name == "main" }) {
                list[idx].isDefault = true
            }
            
            self.profiles = list
            self.defaultProfile = list.first(where: { $0.isDefault }) ?? list.first
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tsvPath),
               let modDate = attrs[.modificationDate] as? Date {
                self.lastUpdated = modDate
            } else {
                self.lastUpdated = Date()
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.quotaManagerDidUpdate(
                    profiles: self.profiles,
                    defaultProfile: self.defaultProfile,
                    isRefreshing: self.isRefreshing
                )
            }
        } catch {
            print("Error reading usage TSV: \(error)")
        }
    }
    
    private func readDefaultProfileName() -> String {
        let path = defaultFilePath
        if FileManager.default.fileExists(atPath: path),
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "main"
    }
    
    // MARK: - Actions & CLI Execution
    
    public func refreshUsage(maxAge: Int = 0) {
        guard !isRefreshing else { return }
        isRefreshing = true
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.quotaManagerDidUpdate(
                profiles: self.profiles,
                defaultProfile: self.defaultProfile,
                isRefreshing: true
            )
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            
            let cmd: String
            if maxAge > 0 {
                cmd = "\(self.agyPPath) usage --tsv --max-age \(maxAge)"
            } else {
                cmd = "\(self.agyPPath) usage --tsv --max-age 0"
            }
            
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            proc.environment = env
            proc.arguments = ["-l", "-c", cmd]
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                print("Failed to run agy-p usage: \(error)")
            }
            
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.loadData()
            }
        }
    }
    
    public func switchProfile(name: String) {
        let path = defaultFilePath
        try? name.write(toFile: path, atomically: true, encoding: .utf8)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            proc.environment = env
            proc.arguments = ["-l", "-c", "\(self.agyPPath) switch \(name)"]
            try? proc.run()
            proc.waitUntilExit()
            
            DispatchQueue.main.async {
                self.loadData()
            }
        }
        self.loadData()
    }
    
    public func switchAuto() {
        isRefreshing = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.quotaManagerDidUpdate(
                profiles: self.profiles,
                defaultProfile: self.defaultProfile,
                isRefreshing: true
            )
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            proc.environment = env
            proc.arguments = ["-l", "-c", "\(self.agyPPath) switch --auto"]
            try? proc.run()
            proc.waitUntilExit()
            
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.loadData()
            }
        }
    }
    
    public func openDashboard() {
        let dashboardPath = (rootDir as NSString).appendingPathComponent("dashboard.html")
        let url = URL(fileURLWithPath: dashboardPath)
        
        if FileManager.default.fileExists(atPath: dashboardPath) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            proc.environment = env
            proc.arguments = ["-l", "-c", "\(self.agyPPath) dash --no-open"]
            try? proc.run()
            proc.waitUntilExit()
            
            if !FileManager.default.fileExists(atPath: dashboardPath) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    public func openTerminal(profile: String) {
        let script = "tell application \"Terminal\" to do script \"agy-p \(profile)\""
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }
}
