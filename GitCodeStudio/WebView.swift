//
//  WebView.swift
//  GitCodeStudio
//
//  Lightweight WKWebView wrapper to host vscode.dev (or a code-server)
//  Supports desktop user agent, reload via NotificationCenter, and
//  works well in multi-window scenes on iPad.
//

import SwiftUI
import WebKit
import SafariServices
import AuthenticationServices

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        // Present desktop user agent so vscode.dev serves the full desktop editor
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.webView = webView

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate, ASWebAuthenticationPresentationContextProviding {
        var parent: WebView
        weak var webView: WKWebView?
        private var popupViewController: UIViewController?
        private weak var popupWebView: WKWebView?
        private var authSession: ASWebAuthenticationSession?

        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(handleReload(_:)), name: .reloadWebView, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func handleReload(_ note: Notification) {
            webView?.reload()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Could inject CSS/JS here to improve iPad layout if needed
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, shouldUseNativeAuthentication(for: url) {
                closePopup(reloadEditor: false)
                startNativeAuthentication(at: url)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil {
                if let req = navigationAction.request as URLRequest? {
                    let destinationWebView = webView === popupWebView ? webView : self.webView
                    destinationWebView?.load(req)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func shouldUseNativeAuthentication(for url: URL) -> Bool {
            guard let host = url.host?.lowercased() else {
                return false
            }

            let path = url.path.lowercased()
            let authHosts = [
                "github.com",
                "login.microsoftonline.com",
                "login.live.com",
                "microsoft.com"
            ]

            return authHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
                && (path.contains("login")
                    || path.contains("oauth")
                    || path.contains("authorize")
                    || path.contains("session")
                    || path.contains("signin")
                    || path.contains("webauthn"))
        }

        private func startNativeAuthentication(at authURL: URL) {
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: nil) { callbackURL, error in
                DispatchQueue.main.async {
                    self.authSession = nil

                    if let callbackURL {
                        self.webView?.load(URLRequest(url: callbackURL))
                    } else {
                        self.webView?.reload()
                    }
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session

            if !session.start() {
                authSession = nil
                presentSafari(url: authURL)
            }
        }

        // Called when JavaScript requests a new window. VS Code uses this for sign-in
        // popups, so return a real, visible web view instead of letting WebKit block it.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = webView.customUserAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.allowsBackForwardNavigationGestures = true

            let popupViewController = UIViewController()
            popupViewController.view.backgroundColor = .systemBackground
            popupViewController.view.addSubview(popup)
            popup.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: popupViewController.view.leadingAnchor),
                popup.trailingAnchor.constraint(equalTo: popupViewController.view.trailingAnchor),
                popup.topAnchor.constraint(equalTo: popupViewController.view.topAnchor),
                popup.bottomAnchor.constraint(equalTo: popupViewController.view.bottomAnchor)
            ])

            popupViewController.modalPresentationStyle = .formSheet
            popupViewController.isModalInPresentation = false
            popupViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(closePopupButtonTapped)
            )

            let navigationController = UINavigationController(rootViewController: popupViewController)
            navigationController.modalPresentationStyle = .formSheet
            navigationController.presentationController?.delegate = self
            self.popupViewController = navigationController
            self.popupWebView = popup

            DispatchQueue.main.async {
                self.topViewController()?.present(navigationController, animated: true)
            }

            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView === popupWebView {
                closePopup(reloadEditor: true)
            }
        }

        @objc private func closePopupButtonTapped() {
            closePopup(reloadEditor: true)
        }

        private func closePopup(reloadEditor: Bool) {
            popupViewController?.dismiss(animated: true)
            popupWebView = nil
            popupViewController = nil

            if reloadEditor {
                webView?.reload()
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            popupWebView = nil
            popupViewController = nil
            webView?.reload()
        }

        // JavaScript alert/confirm/prompt handlers so sites like GitHub can show dialogs
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            presentAlert(title: nil, message: message) {
                completionHandler()
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            presentConfirm(title: nil, message: message, completion: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            presentPrompt(title: nil, message: prompt, defaultText: defaultText, completion: completionHandler)
        }

        // Helpers to present native UIAlertController from the app's root view controller
        private func topViewController() -> UIViewController? {
            // Best-effort to find a presenter
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                var top = root
                while let presented = top.presentedViewController {
                    top = presented
                }
                return top
            }
            return nil
        }

        private func presentAlert(title: String?, message: String?, completion: @escaping () -> Void) {
            guard let vc = topViewController() else { completion(); return }
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
            vc.present(ac, animated: true, completion: nil)
        }

        private func presentConfirm(title: String?, message: String?, completion: @escaping (Bool) -> Void) {
            guard let vc = topViewController() else { completion(false); return }
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
            ac.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
            vc.present(ac, animated: true, completion: nil)
        }

        private func presentPrompt(title: String?, message: String?, defaultText: String?, completion: @escaping (String?) -> Void) {
            guard let vc = topViewController() else { completion(nil); return }
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addTextField { tf in tf.text = defaultText }
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
            ac.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(ac.textFields?.first?.text) })
            vc.present(ac, animated: true, completion: nil)
        }

        private func presentSafari(url: URL) {
            DispatchQueue.main.async {
                if let vc = self.topViewController() {
                    let sf = SFSafariViewController(url: url)
                    vc.present(sf, animated: true, completion: nil)
                } else {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }

        // ASWebAuthenticationPresentationContextProviding
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                if let window = scene.windows.first {
                    return window
                }

                if #available(iOS 26.0, *) {
                    return ASPresentationAnchor(windowScene: scene)
                }
            }

            preconditionFailure("ASWebAuthenticationSession requires an active window scene.")
        }
    }
}
