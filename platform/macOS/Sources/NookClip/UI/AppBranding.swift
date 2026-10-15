import AppKit
import SwiftUI

// MARK: - 产品品牌与最新官方图标 (App Branding)

enum AppBranding {
    static let appName = "NookClip"

    /// 当前软件版本（Info.plist CFBundleShortVersionString，供设置页与菜单栏展示）
    static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"

    /// 最新官方高精度产品图标（用于面板 Header、关于/设置页等）
    static var appIcon: NSImage {
        if let image = loadNamedImage("AppIcon-128") ?? loadNamedImage("AppIcon-64") ?? loadNamedImage("AppIcon-256") ?? loadNamedImage("AppIcon-1024") {
            return image
        }
        if let fallback = loadFromWorkspace("AppIcon-128.png") ?? loadFromWorkspace("AppIcon-64.png") ?? loadFromWorkspace("AppIcon-1024.png") {
            return fallback
        }
        if let icns = NSImage(named: "AppIcon") {
            return icns
        }
        return drawFallbackIcon(size: 64)
    }

    /// 最新官方菜单栏图标（用于 macOS Status Bar 菜单栏）
    static var menuBarIcon: NSImage {
        if let icon = loadMenuBarImage() {
            return icon
        }
        return drawFallbackMenuBarIcon()
    }

    /// 统一的高品质产品图标 SwiftUI 组件
    @ViewBuilder
    static func iconView(size: CGFloat = 30) -> some View {
        Image(nsImage: appIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
    }

    // MARK: - 内部资源加载器

    private static func loadNamedImage(_ name: String) -> NSImage? {
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: name)
    }

    private static func loadMenuBarImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))

        var rep1x: NSBitmapImageRep?
        var rep2x: NSBitmapImageRep?

        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let rep = NSBitmapImageRep(data: data) {
            rep1x = rep
        }
        if let url2x = Bundle.module.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let data2x = try? Data(contentsOf: url2x),
           let rep = NSBitmapImageRep(data: data2x) {
            rep2x = rep
        }

        if rep1x == nil, let url = workspaceResourceURL("MenuBarIcon.png"),
           let data = try? Data(contentsOf: url),
           let rep = NSBitmapImageRep(data: data) {
            rep1x = rep
        }
        if rep2x == nil, let url = workspaceResourceURL("MenuBarIcon@2x.png"),
           let data = try? Data(contentsOf: url),
           let rep = NSBitmapImageRep(data: data) {
            rep2x = rep
        }

        if let rep2x {
            rep2x.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep2x)
        }
        if let rep1x {
            rep1x.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep1x)
        }

        if !image.representations.isEmpty {
            image.isTemplate = true
            return image
        }
        return nil
    }

    private static func loadFromWorkspace(_ fileName: String) -> NSImage? {
        guard let url = workspaceResourceURL(fileName) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func workspaceResourceURL(_ fileName: String) -> URL? {
        let possibleBases = [
            FileManager.default.currentDirectoryPath,
            Bundle.main.bundlePath
        ]
        for base in possibleBases {
            let path1 = URL(fileURLWithPath: base).appendingPathComponent("Resources/Branding/\(fileName)")
            if FileManager.default.fileExists(atPath: path1.path) { return path1 }
            let path2 = URL(fileURLWithPath: base).appendingPathComponent("Sources/NookClip/Resources/\(fileName)")
            if FileManager.default.fileExists(atPath: path2.path) { return path2 }
        }
        return nil
    }

    private static func drawFallbackIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        NSColor(red: 0.24, green: 0.58, blue: 1.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
        image.unlockFocus()
        return image
    }

    private static func drawFallbackMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.lockFocus()
        NSColor.black.setStroke()
        let cardPath = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 15), xRadius: 3, yRadius: 3)
        cardPath.lineWidth = 1.4
        cardPath.stroke()
        let nPath = NSBezierPath()
        nPath.move(to: NSPoint(x: 6, y: 4.5))
        nPath.line(to: NSPoint(x: 6, y: 13.5))
        nPath.line(to: NSPoint(x: 12, y: 4.5))
        nPath.line(to: NSPoint(x: 12, y: 13.5))
        nPath.lineWidth = 1.4
        nPath.lineCapStyle = .round
        nPath.lineJoinStyle = .round
        nPath.stroke()
        image.unlockFocus()
        return image
    }
}
