import SwiftUI
import Shared

@main
struct iOSApp: App {
    var body: some Scene {
        WindowGroup {
            // The screenshot tests pass the language as -KinhinLanguage. Locale.current can keep the process language.
            Text(GreetingKt.greeting(language: UserDefaults.standard.string(forKey: "KinhinLanguage") ?? Locale.current.languageCode ?? "en"))
                .font(.title)
                .padding()
        }
    }
}
