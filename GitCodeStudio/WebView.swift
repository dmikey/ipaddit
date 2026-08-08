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
import AuthenticationServices
import OSLog

struct WebView: UIViewRepresentable {
    private static let logger = Logger(subsystem: "GitCodeStudio", category: "WebAuth")

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(Self.desktopInputProfileScript())

        let webView = WKWebView(frame: .zero, configuration: config)
        // Present desktop user agent so vscode.dev serves the full desktop editor
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.webView = webView
        context.coordinator.requestWebBrowserPasskeyAccessIfNeeded()

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

    private static func popupAuthLoggerScript() -> WKUserScript {
        let source = """
        (() => {
            const send = (event, detail = {}) => {
                try {
                    window.webkit.messageHandlers.authLogger.postMessage({
                        event,
                        href: window.location.href,
                        hasOpener: !!window.opener,
                        detail
                    });
                } catch (_) {}
            };

            const nativeOpener = window.opener;
            const openerShim = {
                closed: false,
                postMessage: (data, targetOrigin = '*') => {
                    let serializedData = null;
                    try {
                        serializedData = JSON.stringify(data);
                    } catch (_) {
                        serializedData = JSON.stringify(String(data));
                    }

                    send('opener-post-message-called', {
                        targetOrigin: String(targetOrigin),
                        data: serializedData
                    });
                }
            };

            if (!nativeOpener) {
                try {
                    Object.defineProperty(window, 'opener', {
                        configurable: true,
                        get: () => openerShim
                    });
                } catch (_) {}
            }

            send('script-installed', {
                userAgent: navigator.userAgent,
                platform: navigator.platform,
                maxTouchPoints: navigator.maxTouchPoints
            });

            window.addEventListener('load', () => send('load'));
            window.addEventListener('beforeunload', () => send('beforeunload'));
            window.addEventListener('pagehide', () => send('pagehide'));
            window.addEventListener('error', (event) => send('error', {
                message: event.message,
                filename: event.filename,
                lineno: event.lineno,
                colno: event.colno
            }));
            window.addEventListener('unhandledrejection', (event) => send('unhandledrejection', {
                reason: String(event.reason)
            }));
            window.addEventListener('message', (event) => send('message-received', {
                origin: event.origin,
                hasData: event.data !== undefined && event.data !== null
            }));

            const nativeClose = window.close.bind(window);
            window.close = () => {
                send('window-close-called');
                return nativeClose();
            };

            if (nativeOpener && nativeOpener.postMessage) {
                const nativePostMessage = nativeOpener.postMessage.bind(nativeOpener);
                nativeOpener.postMessage = (...args) => {
                    let serializedData = null;
                    try {
                        serializedData = JSON.stringify(args[0]);
                    } catch (_) {
                        serializedData = JSON.stringify(String(args[0]));
                    }

                    send('opener-post-message-called', {
                        targetOrigin: args.length > 1 ? String(args[1]) : '',
                        data: serializedData
                    });
                    return nativePostMessage(...args);
                };
            }
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func desktopInputProfileScript() -> WKUserScript {
        let source = """
        (() => {
            const defineGetter = (target, property, value) => {
                try {
                    Object.defineProperty(target, property, {
                        configurable: true,
                        get: () => value
                    });
                } catch (_) {}
            };

            defineGetter(Navigator.prototype, 'platform', 'MacIntel');
            defineGetter(Navigator.prototype, 'maxTouchPoints', 0);

            const nativeMatchMedia = window.matchMedia.bind(window);
            window.matchMedia = (query) => {
                const normalizedQuery = String(query).toLowerCase();
                const forcedMatches = new Map([
                    ['(hover: hover)', true],
                    ['(any-hover: hover)', true],
                    ['(pointer: fine)', true],
                    ['(any-pointer: fine)', true],
                    ['(hover: none)', false],
                    ['(any-hover: none)', false],
                    ['(pointer: coarse)', false],
                    ['(any-pointer: coarse)', false]
                ]);

                if (forcedMatches.has(normalizedQuery)) {
                    const matches = forcedMatches.get(normalizedQuery);
                    return {
                        matches,
                        media: query,
                        onchange: null,
                        addListener: () => {},
                        removeListener: () => {},
                        addEventListener: () => {},
                        removeEventListener: () => {},
                        dispatchEvent: () => false
                    };
                }

                return nativeMatchMedia(query);
            };
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIAdaptivePresentationControllerDelegate {
        var parent: WebView
        weak var webView: WKWebView?
        private var popupViewController: UIViewController?
        private weak var popupWebView: WKWebView?

        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(handleReload(_:)), name: .reloadWebView, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func handleReload(_ note: Notification) {
            WebView.logger.info("reload requested")
            webView?.reload()
        }

        private func webViewRole(_ webView: WKWebView) -> String {
            webView === popupWebView ? "popup" : "main"
        }

        private func sanitizedURLDescription(_ url: URL?) -> String {
            guard let url else {
                return "nil"
            }

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            let base = components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")\(url.path)"
            return url.fragment == nil ? base : "\(base)#<fragment>"
        }

        private func isVSCodeAuthReturnURL(_ url: URL?) -> Bool {
            guard let url, let host = url.host?.lowercased() else {
                return false
            }

            let path = url.path.lowercased()
            let isVSCodeHost = host == "vscode.dev" || host.hasSuffix(".vscode.dev")
            return isVSCodeHost && (path == "/callback" || path == "/redirect")
        }

        func requestWebBrowserPasskeyAccessIfNeeded() {
            guard #available(iOS 17.4, *) else {
                WebView.logger.info("passkey browser access unavailable: OS below iOS 17.4")
                return
            }

            let credentialManager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
            let state = credentialManager.authorizationStateForPlatformCredentials
            WebView.logger.info("passkey browser access state: \(String(describing: state), privacy: .public)")

            guard state == .notDetermined else {
                return
            }

            credentialManager.requestAuthorizationForPublicKeyCredentials { newState in
                WebView.logger.info("passkey browser access request completed: \(String(describing: newState), privacy: .public)")
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            WebView.logger.info("navigation start role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            WebView.logger.info("navigation commit role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebView.logger.info("navigation finish role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            WebView.logger.error("navigation fail role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(webView.url), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            WebView.logger.error("navigation provisional fail role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(webView.url), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            WebView.logger.info("policy action role=\(self.webViewRole(webView), privacy: .public) targetFrame=\(navigationAction.targetFrame == nil ? "nil" : "present", privacy: .public) navType=\(String(describing: navigationAction.navigationType), privacy: .public) url=\(self.sanitizedURLDescription(navigationAction.request.url), privacy: .public)")

            if navigationAction.targetFrame == nil {
                if let req = navigationAction.request as URLRequest? {
                    let destinationWebView = webView === popupWebView ? webView : self.webView
                    WebView.logger.info("loading nil-target request in \(destinationWebView === self.popupWebView ? "popup" : "main", privacy: .public) url=\(self.sanitizedURLDescription(req.url), privacy: .public)")
                    destinationWebView?.load(req)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        // Called when JavaScript requests a new window. VS Code uses this for sign-in
        // popups, so return a real, visible web view instead of letting WebKit block it.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            WebView.logger.info("create popup requested from role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(navigationAction.request.url), privacy: .public)")
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            configuration.userContentController.removeAllUserScripts()
            configuration.userContentController.addUserScript(WebView.popupAuthLoggerScript())
            configuration.userContentController.add(self, name: "authLogger")
            let popup = WKWebView(frame: .zero, configuration: configuration)
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
            WebView.logger.info("webViewDidClose role=\(self.webViewRole(webView), privacy: .public) url=\(self.sanitizedURLDescription(webView.url), privacy: .public)")
            if webView === popupWebView {
                closePopup(reloadEditor: true)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "authLogger" else {
                return
            }

            if let body = message.body as? [String: Any] {
                let event = body["event"] as? String ?? "unknown"
                let href = sanitizedURLDescription(URL(string: body["href"] as? String ?? ""))
                let hasOpener = body["hasOpener"] as? Bool ?? false
                WebView.logger.info("popup js event=\(event, privacy: .public) hasOpener=\(hasOpener, privacy: .public) href=\(href, privacy: .public)")

                if event == "opener-post-message-called",
                   let detail = body["detail"] as? [String: Any],
                   let data = detail["data"] as? String {
                    let targetOrigin = detail["targetOrigin"] as? String ?? "*"
                    forwardPopupMessageToMainEditor(serializedData: data, targetOrigin: targetOrigin)
                }
            } else {
                WebView.logger.info("popup js message body=\(String(describing: message.body), privacy: .public)")
            }
        }

        private func forwardPopupMessageToMainEditor(serializedData: String, targetOrigin: String) {
            guard let webView else {
                WebView.logger.error("cannot forward popup message: main webView missing")
                return
            }

            let quotedData = javascriptStringLiteral(serializedData)
            let quotedOrigin = javascriptStringLiteral(targetOrigin)
            let script = """
            (() => {
                const data = JSON.parse(\(quotedData));
                const origin = \(quotedOrigin);
                window.dispatchEvent(new MessageEvent('message', {
                    data,
                    origin,
                    source: window
                }));
            })();
            """

            WebView.logger.info("forwarding popup postMessage into main editor targetOrigin=\(targetOrigin, privacy: .public)")
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    WebView.logger.error("failed to forward popup postMessage: \(error.localizedDescription, privacy: .public)")
                } else {
                    WebView.logger.info("forwarded popup postMessage into main editor")
                }
            }
        }

        private func javascriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else {
                return "\"\""
            }

            return String(json.dropFirst().dropLast())
        }

        @objc private func closePopupButtonTapped() {
            WebView.logger.info("popup close button tapped")
            closePopup(reloadEditor: true)
        }

        private func closePopup(reloadEditor: Bool) {
            let popupReturnURL = popupWebView?.url
            let popupURL = sanitizedURLDescription(popupReturnURL)
            let shouldReloadEditor = reloadEditor && !isVSCodeAuthReturnURL(popupReturnURL)
            WebView.logger.info("closePopup reloadEditor=\(reloadEditor, privacy: .public) shouldReloadEditor=\(shouldReloadEditor, privacy: .public) popupURL=\(popupURL, privacy: .public)")
            popupWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "authLogger")
            popupViewController?.dismiss(animated: true)
            popupWebView = nil
            popupViewController = nil

            if shouldReloadEditor {
                WebView.logger.info("reloading main editor after popup close")
                webView?.reload()
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            let popupURL = sanitizedURLDescription(popupWebView?.url)
            WebView.logger.info("popup presentation dismissed by user popupURL=\(popupURL, privacy: .public)")
            popupWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "authLogger")
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

    }
}
