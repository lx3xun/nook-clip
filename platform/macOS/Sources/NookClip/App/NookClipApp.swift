import SwiftUI

@main
enum NookClipMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--ocr-worker-image"), idx + 1 < args.count {
            exit(OCREngine.runSubprocessWorker(imagePath: args[idx + 1]))
        }
        NookClipApp.main()
    }
}

struct NookClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(nsImage: AppBranding.menuBarIcon)
                .accessibilityLabel(L10n.tr("menubar.icon.ax"))
                .accessibilityHint(L10n.tr("menubar.icon.ax.hint"))
        }
    }
}
