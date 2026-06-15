import SwiftUI

@main
struct PDFSquishApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 420, height: 480)
        .windowResizability(.contentSize)
    }
}
