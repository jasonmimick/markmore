// moremark — minimal native Markdown previewer for the CLI.
// Usage: moremark <file.md>   or   ... | moremark -
// Live-reloads on save, follows relative .md links (Cmd+[ / Cmd+] history), Cmd+W to close.

import Cocoa
import WebKit

func die(_ msg: String, code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

var initialFile: URL? = nil
var stdinMD: String? = nil

let cliArgs = CommandLine.arguments
guard cliArgs.count == 2, !["-h", "--help"].contains(cliArgs[1]) else {
    die("usage: moremark <file.md>   or   ... | moremark -", code: 64)
}
if cliArgs[1] == "-" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    stdinMD = String(data: data, encoding: .utf8) ?? ""
} else {
    let url = URL(fileURLWithPath: (cliArgs[1] as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        die("moremark: no such file: \(url.path)", code: 66)
    }
    initialFile = url
}

func resource(_ b64: String) -> String {
    String(data: Data(base64Encoded: b64)!, encoding: .utf8)!
}

let template = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>\#(resource(ghCSSBase64))</style>
<style>\#(resource(hljsLightCSSBase64))</style>
<style>@media (prefers-color-scheme: dark) { \#(resource(hljsDarkCSSBase64)) }</style>
<style>
body { margin: 0; background: #ffffff; }
@media (prefers-color-scheme: dark) { body { background: #0d1117; } }
.markdown-body { max-width: 980px; margin: 0 auto; padding: 45px; }
@media (max-width: 767px) { .markdown-body { padding: 24px; } }
.mermaid { display: flex; justify-content: center; margin-bottom: 16px; }
</style>
<script>\#(resource(markedJSBase64))</script>
<script>\#(resource(hljsJSBase64))</script>
<script>\#(resource(mermaidJSBase64))</script>
</head><body><article id="content" class="markdown-body"></article>
<script>
var darkMQ = window.matchMedia('(prefers-color-scheme: dark)');
function __update(md) {
  window.__lastMd = md;
  var y = window.scrollY;
  var el = document.getElementById('content');
  el.innerHTML = marked.parse(md, { gfm: true });
  el.querySelectorAll('code.language-mermaid').forEach(function (c) {
    var d = document.createElement('div');
    d.className = 'mermaid';
    d.textContent = c.textContent;
    c.parentElement.replaceWith(d);
  });
  el.querySelectorAll('pre code').forEach(function (c) { hljs.highlightElement(c); });
  el.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(function (h) {
    if (!h.id) h.id = h.textContent.trim().toLowerCase()
      .replace(/[^\w\- ]+/g, '').replace(/\s+/g, '-');
  });
  var nodes = el.querySelectorAll('.mermaid');
  if (nodes.length) {
    mermaid.initialize({ startOnLoad: false, theme: darkMQ.matches ? 'dark' : 'default' });
    mermaid.run({ nodes: nodes }).catch(function () {});
  }
  window.scrollTo(0, y);
}
darkMQ.addEventListener('change', function () {
  if (window.__lastMd !== undefined) __update(window.__lastMd);
});
</script>
</body></html>
"""#

let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd"]

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var source: DispatchSourceFileSystemObject?
    var pageLoaded = false

    var currentFile: URL? = initialFile
    var backStack: [URL] = []
    var forwardStack: [URL] = []
    var pendingFragment: String?

    var currentBaseDir: URL {
        currentFile?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("moremark")
        window.makeKeyAndOrderFront(nil)

        // CLI-spawned processes need to steal focus after the window exists;
        // macOS 14+ often ignores the first attempt, so retry once async.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            self.window.makeKeyAndOrderFront(nil)
        }

        loadPage()
    }

    func loadPage() {
        pageLoaded = false
        window.title = currentFile?.lastPathComponent ?? "stdin"
        window.subtitle = currentFile != nil
            ? (currentBaseDir.path as NSString).abbreviatingWithTildeInPath : ""
        webView.loadHTMLString(template, baseURL: currentBaseDir)
        watch()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        render()
        if let frag = pendingFragment {
            pendingFragment = nil
            let js = "var t = document.getElementById(\(jsString(frag))); if (t) t.scrollIntoView();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // In-page anchors stay; relative .md links navigate in-window; the rest
    // goes to the default handler (browser, editor, Finder).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "file" {
            if url.fragment != nil, url.path == currentBaseDir.path {
                decisionHandler(.allow)
                return
            }
            if markdownExts.contains(url.pathExtension.lowercased()),
               FileManager.default.fileExists(atPath: url.path) {
                navigate(to: url)
                decisionHandler(.cancel)
                return
            }
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func navigate(to url: URL) {
        if let cur = currentFile { backStack.append(cur) }
        forwardStack.removeAll()
        pendingFragment = url.fragment
        currentFile = url.standardizedFileURL
        loadPage()
    }

    @objc func goBack() {
        guard let cur = currentFile, let prev = backStack.popLast() else { return }
        forwardStack.append(cur)
        currentFile = prev
        loadPage()
    }

    @objc func goForward() {
        guard let cur = currentFile, let next = forwardStack.popLast() else { return }
        backStack.append(cur)
        currentFile = next
        loadPage()
    }

    func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(data: data, encoding: .utf8)! + "[0]"
    }

    @objc func render() {
        guard pageLoaded else { return }
        let md: String
        if let file = currentFile {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return }
            md = contents
        } else {
            md = stdinMD ?? ""
        }
        webView.evaluateJavaScript("__update(\(jsString(md)))", completionHandler: nil)
    }

    func scheduleRender() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(render), object: nil)
        perform(#selector(render), with: nil, afterDelay: 0.1)
    }

    // Editors save atomically (write temp + rename), which kills the watched fd —
    // re-arm on delete/rename, retrying briefly while the new file lands.
    func watch() {
        source?.cancel()
        source = nil
        guard let file = currentFile else { return }
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.scheduleRender()
            if flags.contains(.delete) || flags.contains(.rename) { self.watch() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    // MARK: appearance

    func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        UserDefaults.standard.set(mode, forKey: "appearance")
    }

    @objc func appearanceSystem() { applyAppearance("system") }
    @objc func appearanceLight() { applyAppearance("light") }
    @objc func appearanceDark() { applyAppearance("dark") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let mode = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        switch item.action {
        case #selector(appearanceSystem): item.state = mode == "system" ? .on : .off
        case #selector(appearanceLight): item.state = mode == "light" ? .on : .off
        case #selector(appearanceDark): item.state = mode == "dark" ? .on : .off
        case #selector(goBack): return !backStack.isEmpty
        case #selector(goForward): return !forwardStack.isEmpty
        default: break
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem(); mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Hide moremark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit moremark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let fileMenuItem = NSMenuItem(); mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenuItem.submenu = fileMenu

let editMenuItem = NSMenuItem(); mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu

let viewMenuItem = NSMenuItem(); mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(withTitle: "Reload", action: #selector(AppDelegate.render), keyEquivalent: "r")
viewMenu.addItem(NSMenuItem.separator())
viewMenu.addItem(NSMenuItem(title: "System Appearance", action: #selector(AppDelegate.appearanceSystem), keyEquivalent: ""))
viewMenu.addItem(NSMenuItem(title: "Light", action: #selector(AppDelegate.appearanceLight), keyEquivalent: ""))
viewMenu.addItem(NSMenuItem(title: "Dark", action: #selector(AppDelegate.appearanceDark), keyEquivalent: ""))
viewMenuItem.submenu = viewMenu

let goMenuItem = NSMenuItem(); mainMenu.addItem(goMenuItem)
let goMenu = NSMenu(title: "Go")
goMenu.addItem(NSMenuItem(title: "Back", action: #selector(AppDelegate.goBack), keyEquivalent: "["))
goMenu.addItem(NSMenuItem(title: "Forward", action: #selector(AppDelegate.goForward), keyEquivalent: "]"))
goMenuItem.submenu = goMenu

app.mainMenu = mainMenu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
