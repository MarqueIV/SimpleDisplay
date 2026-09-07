import SwiftUI

@main
struct SimpleDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var locale = LocaleManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(appDelegate.viewModel)
                .environment(locale)
                .onAppear { appDelegate.viewModel.locale = locale }
        } label: {
            Label {
                Text(verbatim: "SimpleDisplay")
            } icon: {
                Image(nsImage: BrandAssets.menuBarIcon)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
