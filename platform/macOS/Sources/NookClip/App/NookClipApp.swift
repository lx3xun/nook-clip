import SwiftUI

@main
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
