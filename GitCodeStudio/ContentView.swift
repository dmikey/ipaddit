//
//  ContentView.swift
//  GitCodeStudio
//
//  Created by Derek Anderson on 8/1/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var url: URL = URL(string: "https://vscode.dev")!

    var body: some View {
        NavigationView {
            WebView(url: url)
                .ignoresSafeArea()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            openNewWindow()
                        } label: {
                            Image(systemName: "square.split.2x1")
                        }
                        .accessibilityLabel("Open in New Window")
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Reload")
                    }
                }
        }
        .navigationViewStyle(.stack)
        .onContinueUserActivity("com.gitcodestudio.open-window") { activity in
            if let webpage = activity.webpageURL {
                self.url = webpage
            }
        }
    }

    private func openNewWindow() {
        let activity = NSUserActivity(activityType: "com.gitcodestudio.open-window")
        activity.title = "GitCodeStudio"
        activity.webpageURL = self.url
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { error in
            print("Failed to activate new scene: \(error.localizedDescription)")
        }
    }

    private func reload() {
        NotificationCenter.default.post(name: .reloadWebView, object: nil)
    }
}

extension Notification.Name {
    static let reloadWebView = Notification.Name("reloadWebView")
}

#Preview {
    ContentView()
}
