import SwiftUI

@main
struct GrinFlintApp: App {
    var body: some Scene {
        WindowGroup {
            if SimSmoke.isRequested {
                SimSmokeView()
            } else {
                ContentView()
            }
        }
    }
}
