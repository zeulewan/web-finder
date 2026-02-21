import SwiftUI

@main
struct WebFinderApp: App {
    @StateObject private var model = ScannerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
