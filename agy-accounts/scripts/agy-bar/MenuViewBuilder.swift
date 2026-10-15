import Foundation
import AppKit

public class MenuViewBuilder {
    
    public static func buildMenu(
        profiles: [ProfileUsage],
        defaultProfile: ProfileUsage?,
        isRefreshing: Bool,
        lastUpdated: Date?,
        target: AnyObject?,
        displayMode: DisplayMode,
        refreshInterval: Int,
        launchAtLogin: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        let smallGrayFont = NSFont.systemFont(ofSize: 11)
        
        // MARK: 1. Default Profile Header
        if let current = defaultProfile {
            let titleAttr = NSMutableAttributedString()
            titleAttr.append(NSAttributedString(
                string: "★  \(current.name)  ",
                attributes: [.font: boldFont, .foregroundColor: NSColor.labelColor]
            ))
            titleAttr.append(NSAttributedString(
                string: "(\(current.email))",
                attributes: [.font: smallGrayFont, .foregroundColor: NSColor.secondaryLabelColor]
            ))
            
            let headerItem = NSMenuItem()
            headerItem.attributedTitle = titleAttr
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            // Detailed Quota rows for current profile
            menu.addItem(makeQuotaRow(
                label: "Gemini 5H    ",
                limit: current.gemini5h,
                monoFont: monoFont
            ))
            menu.addItem(makeQuotaRow(
                label: "Gemini Tuần  ",
                limit: current.geminiWeek,
                monoFont: monoFont
            ))
            menu.addItem(makeQuotaRow(
                label: "Claude 5H    ",
                limit: current.claude5h,
                monoFont: monoFont
            ))
            menu.addItem(makeQuotaRow(
                label: "Claude Tuần  ",
                limit: current.claudeWeek,
                monoFont: monoFont
            ))
        } else {
            let item = NSMenuItem(title: "Chưa có dữ liệu quota", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // MARK: 2. Profile List (Click to switch)
        let sectionItem = NSMenuItem(title: "DANH SÁCH PROFILES (Click để chuyển)", action: nil, keyEquivalent: "")
        sectionItem.isEnabled = false
        menu.addItem(sectionItem)
        
        for p in profiles {
            let item = NSMenuItem()
            let isCurrent = p.isDefault
            item.state = isCurrent ? .on : .off
            
            let pAttr = NSMutableAttributedString()
            let checkIcon = isCurrent ? "● " : "○ "
            let iconColor = isCurrent ? NSColor.systemBlue : NSColor.tertiaryLabelColor
            pAttr.append(NSAttributedString(
                string: checkIcon,
                attributes: [.font: boldFont, .foregroundColor: iconColor]
            ))
            pAttr.append(NSAttributedString(
                string: "\(p.name) ",
                attributes: [.font: isCurrent ? boldFont : monoFont, .foregroundColor: NSColor.labelColor]
            ))
            
            let gText = "G:\(p.gemini5h.formattedPct)"
            let cText = "C:\(p.claude5h.formattedPct)"
            pAttr.append(NSAttributedString(
                string: " [\(gText) · \(cText)]",
                attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
            ))
            
            item.attributedTitle = pAttr
            item.target = target
            item.action = #selector(AppDelegate.selectProfile(_:))
            item.representedObject = p.name
            
            // Hover Submenu with detailed breakdown
            let sub = NSMenu()
            let subHeader = NSMenuItem(title: "\(p.name) — \(p.email)", action: nil, keyEquivalent: "")
            subHeader.isEnabled = false
            sub.addItem(subHeader)
            sub.addItem(NSMenuItem.separator())
            sub.addItem(makeQuotaRow(label: "Gemini 5H    ", limit: p.gemini5h, monoFont: monoFont))
            sub.addItem(makeQuotaRow(label: "Gemini Tuần  ", limit: p.geminiWeek, monoFont: monoFont))
            sub.addItem(makeQuotaRow(label: "Claude 5H    ", limit: p.claude5h, monoFont: monoFont))
            sub.addItem(makeQuotaRow(label: "Claude Tuần  ", limit: p.claudeWeek, monoFont: monoFont))
            sub.addItem(NSMenuItem.separator())
            
            let switchItem = NSMenuItem(title: "Chọn làm Profile mặc định", action: #selector(AppDelegate.selectProfile(_:)), keyEquivalent: "")
            switchItem.target = target
            switchItem.representedObject = p.name
            switchItem.isEnabled = !isCurrent
            sub.addItem(switchItem)
            
            let termItem = NSMenuItem(title: "Mở Terminal với profile này", action: #selector(AppDelegate.openTerminalForProfile(_:)), keyEquivalent: "")
            termItem.target = target
            termItem.representedObject = p.name
            sub.addItem(termItem)
            
            item.submenu = sub
            menu.addItem(item)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // MARK: 3. Smart Actions
        let autoPickItem = NSMenuItem(
            title: "⚡  Tự động chọn profile tốt nhất (agy-p switch --auto)",
            action: #selector(AppDelegate.switchAutoAction(_:)),
            keyEquivalent: "a"
        )
        autoPickItem.target = target
        menu.addItem(autoPickItem)
        
        let refreshTitle = isRefreshing ? "⟳  Đang làm mới quota..." : "🔄  Làm mới ngay (agy-p usage)"
        let refreshItem = NSMenuItem(
            title: refreshTitle,
            action: #selector(AppDelegate.refreshAction(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = target
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)
        
        let dashItem = NSMenuItem(
            title: "📊  Mở Dashboard trực quan (agy-p dash)",
            action: #selector(AppDelegate.openDashboardAction(_:)),
            keyEquivalent: "d"
        )
        dashItem.target = target
        menu.addItem(dashItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // MARK: 4. Settings Submenu
        let settingsItem = NSMenuItem(title: "⚙️  Cài đặt...", action: nil, keyEquivalent: "")
        let settingsSub = NSMenu()
        
        // Display Style
        let displayHeader = NSMenuItem(title: "Hiển thị trên Menu Bar:", action: nil, keyEquivalent: "")
        displayHeader.isEnabled = false
        settingsSub.addItem(displayHeader)
        
        for mode in DisplayMode.allCases {
            let mItem = NSMenuItem(title: mode.label, action: #selector(AppDelegate.changeDisplayMode(_:)), keyEquivalent: "")
            mItem.target = target
            mItem.representedObject = mode.rawValue
            mItem.state = (mode == displayMode) ? .on : .off
            settingsSub.addItem(mItem)
        }
        
        settingsSub.addItem(NSMenuItem.separator())
        
        // Refresh interval
        let intervalHeader = NSMenuItem(title: "Chu kỳ tự động làm mới:", action: nil, keyEquivalent: "")
        intervalHeader.isEnabled = false
        settingsSub.addItem(intervalHeader)
        
        let intervals: [(label: String, sec: Int)] = [
            ("30 giây", 30),
            ("1 phút", 60),
            ("2 phút (Mặc định)", 120),
            ("5 phút", 300),
            ("15 phút", 900),
            ("Thủ công (Khi bấm làm mới)", 0)
        ]
        
        for (label, sec) in intervals {
            let iItem = NSMenuItem(title: label, action: #selector(AppDelegate.changeRefreshInterval(_:)), keyEquivalent: "")
            iItem.target = target
            iItem.representedObject = sec
            iItem.state = (refreshInterval == sec) ? .on : .off
            settingsSub.addItem(iItem)
        }
        
        settingsSub.addItem(NSMenuItem.separator())
        
        let launchItem = NSMenuItem(
            title: "🚀  Khởi động cùng macOS",
            action: #selector(AppDelegate.toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = target
        launchItem.state = launchAtLogin ? .on : .off
        settingsSub.addItem(launchItem)
        
        settingsItem.submenu = settingsSub
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // MARK: 5. Footer & Last Updated
        let updateText: String
        if isRefreshing {
            updateText = "🕒  Đang cập nhật số liệu mới..."
        } else if let date = lastUpdated {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            updateText = "🕒  Cập nhật lúc: \(fmt.string(from: date))"
        } else {
            updateText = "🕒  Chưa cập nhật"
        }
        
        let updatedItem = NSMenuItem(title: updateText, action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)
        
        let quitItem = NSMenuItem(
            title: "❌  Thoát AgyBar",
            action: #selector(AppDelegate.quitAction(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = target
        menu.addItem(quitItem)
        
        return menu
    }
    
    private static func makeQuotaRow(
        label: String,
        limit: QuotaLimit,
        monoFont: NSFont
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let attr = NSMutableAttributedString()
        
        // Label
        attr.append(NSAttributedString(
            string: "  \(label) ",
            attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        
        // Bar
        let barStr = limit.progressBar(width: 8)
        attr.append(NSAttributedString(
            string: "\(barStr)  ",
            attributes: [.font: monoFont, .foregroundColor: limit.statusColor]
        ))
        
        // Reset countdown
        let resetStr = limit.resetDescription
        if !resetStr.isEmpty {
            attr.append(NSAttributedString(
                string: "(\(resetStr))",
                attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        
        item.attributedTitle = attr
        item.isEnabled = false
        return item
    }
}
