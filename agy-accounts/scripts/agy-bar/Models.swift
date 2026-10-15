import Foundation
import AppKit

public enum DisplayMode: Int, CaseIterable {
    case gemini5h = 0
    case geminiBoth = 1
    case nameAndQuota = 2
    case geminiAndClaude = 3
    
    public var label: String {
        switch self {
        case .gemini5h: return "Chỉ Gemini 5H (⚡ 68%)"
        case .geminiBoth: return "Gemini 5H & Tuần (⚡ 68% · 69%)"
        case .nameAndQuota: return "Tên Profile + Quota (⚡ mcong8666: 68%)"
        case .geminiAndClaude: return "Cả Gemini & Claude (⚡ G:68% C:100%)"
        }
    }
}

public struct QuotaLimit {
    public let pct: Int // -1 = unknown, -2 = disabled, 0..100
    public let resetISO: String
    
    public var isUnknown: Bool { pct < 0 && pct != -2 }
    public var isDisabled: Bool { pct == -2 }
    
    public var formattedPct: String {
        if isDisabled { return "không có" }
        if isUnknown { return "?" }
        return "\(pct)%"
    }
    
    public var statusColor: NSColor {
        if isDisabled || isUnknown { return .secondaryLabelColor }
        if pct >= 50 { return NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1.0) } // Green
        if pct >= 20 { return NSColor(calibratedRed: 0.98, green: 0.73, blue: 0.01, alpha: 1.0) } // Yellow
        if pct >= 5  { return NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1.0) }  // Orange
        return NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0) // Red
    }
    
    public func progressBar(width: Int = 10) -> String {
        if isDisabled { return String(repeating: "·", count: width) + " không có" }
        if isUnknown { return String(repeating: "·", count: width) + "  ?" }
        let clamped = max(0, min(100, pct))
        let filled = Int(round(Double(clamped) * Double(width) / 100.0))
        let empty = max(0, width - filled)
        return String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + String(format: " %3d%%", pct)
    }
    
    public var resetDescription: String {
        guard !resetISO.isEmpty, resetISO != "-" else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: resetISO) else { return "" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "đã hồi" }
        let s = Int(diff)
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 {
            return "hồi sau \(d)n\(h)g"
        } else if h > 0 {
            return String(format: "hồi sau %dg%02dp", h, m)
        } else {
            return String(format: "hồi sau %dp", max(1, m))
        }
    }
    
    public var localResetTime: String {
        guard !resetISO.isEmpty, resetISO != "-" else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: resetISO) else { return "" }
        let localFmt = DateFormatter()
        localFmt.dateFormat = "dd/MM HH:mm"
        return localFmt.string(from: date)
    }
}

public struct ProfileUsage {
    public let name: String
    public let email: String
    public let geminiWeek: QuotaLimit
    public let gemini5h: QuotaLimit
    public let claudeWeek: QuotaLimit
    public let claude5h: QuotaLimit
    public var isDefault: Bool = false
    
    public var minGemini: Int {
        if geminiWeek.pct < 0 && gemini5h.pct < 0 { return -1 }
        if geminiWeek.pct < 0 { return gemini5h.pct }
        if gemini5h.pct < 0 { return geminiWeek.pct }
        return min(geminiWeek.pct, gemini5h.pct)
    }
}
