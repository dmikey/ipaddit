//
//  ContentView.swift
//  GitCodeStudio
//
//  Created by Derek Anderson on 8/1/26.
//

import SwiftUI

struct ContentView: View {
    @State private var url: URL = URL(string: "https://vscode.dev")!

    var body: some View {
        WebView(url: url)
            .ignoresSafeArea()
            .onContinueUserActivity("com.gitcodestudio.open-window") { activity in
                if let webpage = activity.webpageURL {
                    self.url = webpage
                }
            }
    }
}

extension Notification.Name {
    static let reloadWebView = Notification.Name("reloadWebView")
}

#Preview {
    ContentView()
}
