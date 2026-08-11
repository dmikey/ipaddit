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

final class AccessoryFreeWKWebView: WKWebView {
    override var inputAccessoryView: UIView? {
        nil
    }

    override var inputAssistantItem: UITextInputAssistantItem {
        let item = super.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        return item
    }
}

struct WebView: UIViewRepresentable {
    private static let logger = Logger(subsystem: "GitCodeStudio", category: "WebAuth")
    private static let vscodeBackground = UIColor(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1.0)

    fileprivate static func authLog(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[GitCodeStudio WebAuth] \(message)")
    }

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(Self.webExtensionCompatibilityScript())
        config.userContentController.addUserScript(Self.desktopInputProfileScript())
        config.userContentController.addUserScript(Self.titleOverrideScript(title: "ipaddit"))
        config.userContentController.addUserScript(Self.authLoggerScript(installsOpenerShim: false, reportsAllInteractions: true))
        config.userContentController.add(context.coordinator, name: "authLogger")

        let webView = AccessoryFreeWKWebView(frame: .zero, configuration: config)
        // Present desktop user agent so vscode.dev serves the full desktop editor
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = Self.vscodeBackground
        webView.scrollView.backgroundColor = Self.vscodeBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.webView = webView
        context.coordinator.requestWebBrowserPasskeyAccessIfNeeded()

        let request = URLRequest(url: url)
        Self.authLog("main webView loading initial url=\(context.coordinator.authDebugURLDescription(url))")
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            Self.authLog("main webView updating url from=\(context.coordinator.authDebugURLDescription(uiView.url)) to=\(context.coordinator.authDebugURLDescription(url))")
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private static func webExtensionCompatibilityScript() -> WKUserScript {
        let source = """
        (() => {
            const report = (event, detail = {}) => {
                try {
                    window.webkit.messageHandlers.authLogger.postMessage({
                        event,
                        href: window.location.href,
                        hasOpener: !!window.opener,
                        detail
                    });
                } catch (_) {}
            };

            const processShimSource = [
                "globalThis.process = globalThis.process || { browser: true, env: {}, platform: 'browser', versions: {} };",
                "globalThis.process.env = globalThis.process.env || {};",
                "globalThis.process.browser = true;"
            ].join("\\n");

            const installProcessShim = (target) => {
                try {
                    if (!target.process) {
                        Object.defineProperty(target, 'process', {
                            configurable: true,
                            writable: true,
                            value: {
                                browser: true,
                                env: {},
                                platform: 'browser',
                                versions: {}
                            }
                        });
                    } else {
                        target.process.env = target.process.env || {};
                        target.process.browser = true;
                    }
                    report('process-shim-installed', { isTop: window.top === window });
                } catch (error) {
                    report('process-shim-failed', { error: String(error) });
                }
            };

            installProcessShim(globalThis);

            const NativeWorker = window.Worker;
            if (NativeWorker && !NativeWorker.__gitCodeStudioWrapped) {
                const shouldWrapWorker = (urlString) => {
                    const normalized = urlString.toLowerCase();
                    return ((normalized.startsWith('blob:') || normalized.startsWith('data:')) && window.top !== window)
                        || normalized.includes('extensionhost')
                        || normalized.includes('extension-host')
                        || normalized.includes('webworkerextensionhost')
                        || normalized.includes('/out/vs/workbench/api/worker/')
                        || normalized.includes('/out/vs/workbench/services/extensions/worker/')
                        || normalized.includes('vscode-cdn.net/stable/');
                };

                const makeBootstrapURL = (urlString, options) => {
                    const workerType = options && options.type === 'module' ? 'module' : 'classic';
                    const bootstrap = workerType === 'module'
                        ? [processShimSource, "import(" + JSON.stringify(urlString) + ");"].join("\\n")
                        : [processShimSource, "importScripts(" + JSON.stringify(urlString) + ");"].join("\\n");
                    return URL.createObjectURL(new Blob([bootstrap], { type: 'application/javascript' }));
                };

                const WrappedWorker = function(url, options) {
                    const urlString = String(url);
                    const workerType = options && options.type ? String(options.type) : 'classic';
                    const shouldWrap = shouldWrapWorker(urlString);
                    report('worker-created', { url: urlString, type: workerType, wrapped: shouldWrap });

                    if (!shouldWrap) {
                        return new NativeWorker(url, options);
                    }

                    try {
                        const bootstrapURL = makeBootstrapURL(urlString, options || {});
                        report('worker-wrapped', { url: urlString, type: workerType, bootstrapURL });
                        return new NativeWorker(bootstrapURL, options);
                    } catch (error) {
                        report('worker-wrap-failed', { url: urlString, type: workerType, error: String(error) });
                        return new NativeWorker(url, options);
                    }
                };

                WrappedWorker.prototype = NativeWorker.prototype;
                Object.defineProperty(WrappedWorker, '__gitCodeStudioWrapped', { value: true });
                Object.defineProperty(window, 'Worker', {
                    configurable: true,
                    writable: true,
                    value: WrappedWorker
                });
            }
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func titleOverrideScript(title: String) -> WKUserScript {
        let encodedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        (() => {
            const appTitle = "\(encodedTitle)";
            const setTitle = () => {
                if (document.title !== appTitle) {
                    document.title = appTitle;
                }
            };

            setTitle();
            new MutationObserver(setTitle).observe(document.querySelector('title') || document.documentElement, {
                childList: true,
                subtree: true,
                characterData: true
            });
            window.addEventListener('load', setTitle);
            window.addEventListener('focus', setTitle);
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    private static func authLoggerScript(installsOpenerShim: Bool, reportsAllInteractions: Bool) -> WKUserScript {
        let installsOpenerShimLiteral = installsOpenerShim ? "true" : "false"
        let reportsAllInteractionsLiteral = reportsAllInteractions ? "true" : "false"
        let source = """
        (() => {
            const installsOpenerShim = \(installsOpenerShimLiteral);
            const reportsAllInteractions = \(reportsAllInteractionsLiteral);

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

            const serializeSnippet = (value) => {
                try {
                    return JSON.stringify(value).slice(0, 1600);
                } catch (_) {
                    return String(value).slice(0, 1600);
                }
            };

            const shouldReportDiagnosticText = (value) => {
                const text = String(value || '').toLowerCase();
                return text.includes('github')
                    || text.includes('actions')
                    || text.includes('auth')
                    || text.includes('signin')
                    || text.includes('sign in')
                    || text.includes('command')
                    || text.includes('error');
            };

            const wrapConsole = (level) => {
                const native = console[level] && console[level].bind(console);
                if (!native) {
                    return;
                }

                console[level] = (...args) => {
                    const snippet = args.map(serializeSnippet).join(' ');
                    if (shouldReportDiagnosticText(snippet)) {
                        send('console-' + level, { snippet });
                    }
                    return native(...args);
                };
            };

            wrapConsole('error');
            wrapConsole('warn');

            const nativeOpen = window.open.bind(window);
            window.open = (...args) => {
                const openedWindow = nativeOpen(...args);
                send('window-open-called', {
                    url: args.length > 0 ? String(args[0]) : '',
                    target: args.length > 1 ? String(args[1]) : '',
                    features: args.length > 2 ? String(args[2]) : ''
                });
                send('window-open-returned', { hasWindow: !!openedWindow });
                return openedWindow;
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

            if (!nativeOpener && installsOpenerShim) {
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
                maxTouchPoints: navigator.maxTouchPoints,
                isTop: window.top === window
            });

            const describeElement = (element) => {
                if (!element) {
                    return {};
                }

                const text = String(element.innerText || element.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 120);
                return {
                    tag: String(element.tagName || ''),
                    id: String(element.id || ''),
                    className: String(element.className || '').slice(0, 160),
                    role: String(element.getAttribute && element.getAttribute('role') || ''),
                    ariaLabel: String(element.getAttribute && element.getAttribute('aria-label') || ''),
                    href: String(element.href || ''),
                    text
                };
            };

            const shouldReportInteraction = (detail) => {
                const combined = [
                    detail.text,
                    detail.ariaLabel,
                    detail.href,
                    detail.id,
                    detail.className
                ].join(' ').toLowerCase();

                return combined.includes('sign')
                    || combined.includes('github')
                    || combined.includes('account')
                    || combined.includes('sync');
            };

            const reportInteraction = (event) => {
                const detail = describeElement(event.target && event.target.closest ? event.target.closest('button,a,[role="button"],input,[tabindex]') : event.target);
                detail.eventType = event.type;
                detail.defaultPrevented = !!event.defaultPrevented;
                detail.isTrusted = !!event.isTrusted;
                if (reportsAllInteractions || shouldReportInteraction(detail)) {
                    send('interaction', detail);
                }
            };

            window.addEventListener('pointerdown', reportInteraction, true);
            window.addEventListener('click', reportInteraction, true);

            window.addEventListener('load', () => send('load'));
            window.addEventListener('beforeunload', () => send('beforeunload'));
            window.addEventListener('pagehide', () => send('pagehide'));
            window.addEventListener('error', (event) => send('error', {
                message: event.message,
                filename: event.filename,
                lineno: event.lineno,
                colno: event.colno
            }));
            window.addEventListener('unhandledrejection', (event) => {
                const reason = event.reason;
                send('unhandledrejection', {
                    reason: String(reason),
                    name: String(reason && reason.name || ''),
                    message: String(reason && reason.message || ''),
                    stack: String(reason && reason.stack || '').slice(0, 1000)
                });
            });
            window.addEventListener('message', (event) => {
                const snippet = serializeSnippet(event.data);
                if (shouldReportDiagnosticText(snippet)) {
                    send('message-diagnostic', {
                        origin: event.origin,
                        snippet
                    });
                }

                send('message-received', {
                    origin: event.origin,
                    hasData: event.data !== undefined && event.data !== null
                });
            });

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

            const defineUndefinedGetter = (target, property) => {
                try {
                    Object.defineProperty(target, property, {
                        configurable: true,
                        get: () => undefined
                    });
                } catch (_) {}
            };

            defineGetter(Navigator.prototype, 'platform', 'MacIntel');
            defineGetter(Navigator.prototype, 'maxTouchPoints', 0);
            defineGetter(Navigator.prototype, 'msMaxTouchPoints', 0);

            for (const target of [window, Document.prototype, HTMLElement.prototype]) {
                for (const property of ['ontouchstart', 'ontouchmove', 'ontouchend', 'ontouchcancel']) {
                    defineUndefinedGetter(target, property);
                }
            }

            const nativeMatchMedia = window.matchMedia.bind(window);
            window.matchMedia = (query) => {
                const normalizedQuery = String(query).toLowerCase().replace(/\\s+/g, '');
                const forcedMatches = new Map([
                    ['(hover:hover)', true],
                    ['(any-hover:hover)', true],
                    ['(pointer:fine)', true],
                    ['(any-pointer:fine)', true],
                    ['(hover:none)', false],
                    ['(any-hover:none)', false],
                    ['(pointer:coarse)', false],
                    ['(any-pointer:coarse)', false]
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

        func authDebugURLDescription(_ url: URL?) -> String {
            guard let url else {
                return "nil"
            }

            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryKeys = components?.queryItems?
                .map(\.name)
                .sorted()
                .joined(separator: ",") ?? ""
            let fragmentState = url.fragment == nil ? "none" : "present"
            return "scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil") path=\(url.path) queryKeys=[\(queryKeys)] fragment=\(fragmentState)"
        }

        private func authClassificationDescription(_ url: URL?) -> String {
            let keepInPopup = shouldKeepNavigationInPopup(url)
            let auth = isAuthenticationURL(url)
            let vscodeReturn = isVSCodeAuthReturnURL(url)
            return "keepInPopup=\(keepInPopup) auth=\(auth) vscodeReturn=\(vscodeReturn)"
        }

        private func isVSCodeAuthReturnURL(_ url: URL?) -> Bool {
            guard let url, let host = url.host?.lowercased() else {
                return false
            }

            let path = url.path.lowercased()
            let isVSCodeHost = host == "vscode.dev" || host.hasSuffix(".vscode.dev")
            guard isVSCodeHost else {
                return false
            }

            if path == "/callback" || path == "/redirect" {
                return true
            }

            let query = url.query?.lowercased() ?? ""
            let fragment = url.fragment?.lowercased() ?? ""
            return query.contains("github-authentication") || fragment.contains("github-authentication")
        }

        private func isAuthenticationURL(_ url: URL?) -> Bool {
            guard let url, let host = url.host?.lowercased() else {
                return false
            }

            let path = url.path.lowercased()
            if host == "github.com" || host.hasSuffix(".github.com") {
                return true
            }

            if host == "api.github.com" || host.hasSuffix(".githubusercontent.com") {
                return path.contains("/login")
                    || path.contains("/oauth")
                    || path.contains("/session")
                    || path.contains("/webauthn")
            }

            if host == "login.microsoftonline.com"
                || host == "login.live.com"
                || host.hasSuffix(".login.microsoftonline.com")
                || host.hasSuffix(".login.live.com") {
                return true
            }

            return false
        }

        private func shouldKeepNavigationInPopup(_ url: URL?) -> Bool {
            guard let url else {
                return true
            }

            if url.scheme == "about" {
                return true
            }

            return isAuthenticationURL(url) || isVSCodeAuthReturnURL(url)
        }

        private func openInNewAppWindow(url: URL) {
            WebView.authLog("requesting new app window url=\(authDebugURLDescription(url)) classification=\(authClassificationDescription(url))")
            let activity = NSUserActivity(activityType: "com.gitcodestudio.open-window")
            activity.title = "GitCodeStudio"
            activity.webpageURL = url

            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { [weak self] error in
                WebView.logger.error("failed to open new app window, falling back to main editor url=\(self?.sanitizedURLDescription(url) ?? "unknown", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self?.webView?.load(URLRequest(url: url))
            }
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
            WebView.logger.info("navigation start role=\(self.webViewRole(webView), privacy: .public) url=\(self.authDebugURLDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            WebView.logger.info("navigation commit role=\(self.webViewRole(webView), privacy: .public) url=\(self.authDebugURLDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebView.logger.info("navigation finish role=\(self.webViewRole(webView), privacy: .public) url=\(self.authDebugURLDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            WebView.logger.error("navigation fail role=\(self.webViewRole(webView), privacy: .public) url=\(self.authDebugURLDescription(webView.url), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            WebView.logger.error("navigation provisional fail role=\(self.webViewRole(webView), privacy: .public) url=\(self.authDebugURLDescription(webView.url), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            WebView.authLog("policy action role=\(webViewRole(webView)) targetFrame=\(navigationAction.targetFrame == nil ? "nil" : "present") navType=\(String(describing: navigationAction.navigationType)) url=\(authDebugURLDescription(navigationAction.request.url)) classification=\(authClassificationDescription(navigationAction.request.url))")

            if webView === popupWebView, !shouldKeepNavigationInPopup(navigationAction.request.url) {
                WebView.authLog("policy decision cancel: promoting non-auth popup navigation to new app window url=\(authDebugURLDescription(navigationAction.request.url))")
                if let url = navigationAction.request.url {
                    openInNewAppWindow(url: url)
                }
                closePopup(reloadEditor: false)
                decisionHandler(.cancel)
                return
            }

            if webView === popupWebView,
               (isAuthenticationURL(navigationAction.request.url) || isVSCodeAuthReturnURL(navigationAction.request.url)) {
                WebView.authLog("policy decision continue: popup auth navigation url=\(authDebugURLDescription(navigationAction.request.url))")
                presentPopupIfNeeded()
            }

            if navigationAction.targetFrame == nil {
                if let req = navigationAction.request as URLRequest? {
                    if webView !== popupWebView, !shouldKeepNavigationInPopup(req.url), let url = req.url {
                        WebView.authLog("policy decision cancel: opening nil-target non-auth request in new app window url=\(authDebugURLDescription(url))")
                        openInNewAppWindow(url: url)
                    } else {
                        let destinationWebView = webView === popupWebView ? webView : self.webView
                        WebView.authLog("policy decision cancel: loading nil-target request in \(destinationWebView === popupWebView ? "popup" : "main") url=\(authDebugURLDescription(req.url))")
                        destinationWebView?.load(req)
                    }
                }
                decisionHandler(.cancel)
                return
            }

            WebView.authLog("policy decision allow url=\(authDebugURLDescription(navigationAction.request.url))")
            decisionHandler(.allow)
        }

        // Called when JavaScript requests a new window. VS Code uses this for sign-in
        // popups, so return a real, visible web view instead of letting WebKit block it.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            WebView.authLog("create popup requested from role=\(webViewRole(webView)) url=\(authDebugURLDescription(navigationAction.request.url)) classification=\(authClassificationDescription(navigationAction.request.url))")
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            configuration.userContentController.removeAllUserScripts()
            configuration.userContentController.addUserScript(WebView.desktopInputProfileScript())
            configuration.userContentController.addUserScript(WebView.authLoggerScript(installsOpenerShim: true, reportsAllInteractions: false))
            configuration.userContentController.removeScriptMessageHandler(forName: "authLogger")
            configuration.userContentController.add(self, name: "authLogger")
            let popup = AccessoryFreeWKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = webView.customUserAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.allowsBackForwardNavigationGestures = true
            popup.isOpaque = false
            popup.backgroundColor = WebView.vscodeBackground
            popup.scrollView.backgroundColor = WebView.vscodeBackground
            popup.scrollView.contentInsetAdjustmentBehavior = .never

            let popupViewController = UIViewController()
            popupViewController.view.backgroundColor = WebView.vscodeBackground
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
            navigationController.view.backgroundColor = WebView.vscodeBackground
            navigationController.navigationBar.isHidden = true
            navigationController.modalPresentationStyle = .formSheet
            navigationController.presentationController?.delegate = self
            self.popupViewController = navigationController
            self.popupWebView = popup
            WebView.authLog("created popup webView and controller")
            presentPopupIfNeeded()

            return popup
        }

        private func presentPopupIfNeeded() {
            guard let popupViewController, popupViewController.presentingViewController == nil else {
                WebView.authLog("popup presentation skipped: missing popup or already presenting")
                return
            }

            WebView.authLog("presenting popup for auth navigation")
            DispatchQueue.main.async {
                guard popupViewController.presentingViewController == nil else {
                    WebView.authLog("popup presentation skipped on main queue: already presenting")
                    return
                }

                guard let presenter = self.topViewController() else {
                    WebView.authLog("popup presentation failed: no top view controller")
                    return
                }

                WebView.authLog("popup presentation using presenter=\(String(describing: type(of: presenter)))")
                presenter.present(popupViewController, animated: true)
            }
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
                let detail = body["detail"] as? [String: Any] ?? [:]
                let detailKeys = detail.keys.sorted().joined(separator: ",")
                WebView.authLog("js event=\(event) hasOpener=\(hasOpener) href=\(href) detailKeys=[\(detailKeys)]")

                if event == "interaction"
                    || event == "window-open-called"
                    || event == "window-open-returned"
                    || event == "unhandledrejection"
                    || event == "error"
                    || event == "message-diagnostic"
                    || event == "console-error"
                    || event == "console-warn"
                    || event == "process-shim-installed"
                    || event == "process-shim-failed"
                    || event == "worker-created"
                    || event == "worker-wrapped"
                    || event == "worker-wrap-failed" {
                    WebView.authLog("js detail event=\(event) \(authDetailDescription(detail))")
                }

                if event == "opener-post-message-called",
                   let data = detail["data"] as? String {
                    let targetOrigin = detail["targetOrigin"] as? String ?? "*"
                    WebView.authLog("js opener postMessage captured targetOrigin=\(targetOrigin) bytes=\(data.count)")
                    forwardPopupMessageToMainEditor(serializedData: data, targetOrigin: targetOrigin)
                }
            } else {
                WebView.authLog("js message body=\(String(describing: message.body))")
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

        private func authDetailDescription(_ detail: [String: Any]) -> String {
            let interestingKeys = [
                "eventType",
                "tag",
                "role",
                "ariaLabel",
                "text",
                "href",
                "target",
                "features",
                "hasWindow",
                "defaultPrevented",
                "isTrusted",
                "name",
                "message",
                "reason",
                "stack",
                "origin",
                "snippet",
                "url",
                "type",
                "wrapped",
                "bootstrapURL",
                "error",
                "isTop"
            ]

            return interestingKeys.compactMap { key in
                guard let value = detail[key] else {
                    return nil
                }

                return "\(key)=\(String(describing: value))"
            }.joined(separator: " ")
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
            WebView.authLog("javascript alert role=\(webViewRole(webView)) frameURL=\(authDebugURLDescription(frame.request.url)) message=\(message)")
            presentAlert(title: nil, message: message) {
                completionHandler()
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            WebView.authLog("javascript confirm role=\(webViewRole(webView)) frameURL=\(authDebugURLDescription(frame.request.url)) autoAllowCandidate=\(shouldAutoAllowExtensionSignInPrompt(message)) message=\(message)")
            if shouldAutoAllowExtensionSignInPrompt(message) {
                WebView.authLog("auto-allowing VS Code extension sign-in prompt")
                completionHandler(true)
                return
            }

            presentConfirm(title: nil, message: message, completion: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            WebView.authLog("javascript prompt role=\(webViewRole(webView)) frameURL=\(authDebugURLDescription(frame.request.url)) prompt=\(prompt)")
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

        private func shouldAutoAllowExtensionSignInPrompt(_ message: String) -> Bool {
            let normalizedMessage = message.lowercased()
            return normalizedMessage.hasPrefix("the extension ")
                && normalizedMessage.contains(" wants to sign in using ")
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
