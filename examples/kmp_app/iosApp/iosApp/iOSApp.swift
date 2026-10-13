import SwiftUI
import Shared

@main
struct iOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text(GreetingKt.greeting(language: Locale.current.languageCode ?? "en"))
                .font(.title)
                .padding()
        }
    }
}
