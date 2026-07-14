// moremark — more for markdown: native macOS previewer for the CLI.
// Usage: moremark <file.md | folder>   or   ... | moremark -
// Live reload, in-window .md navigation (Cmd+[ / Cmd+]), history tabs, Cmd+W to close.

import Cocoa
import WebKit

func die(_ msg: String, code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd"]

func isDir(_ url: URL) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
}

// Opening a folder shows its README if it has one, else a generated index.
func resolveTarget(_ url: URL) -> URL {
    guard isDir(url) else { return url }
    if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path),
       let readme = items.first(where: { $0.lowercased() == "readme.md" }) {
        return url.appendingPathComponent(readme).standardizedFileURL
    }
    return url
}

func indexMarkdown(for dir: URL) -> String {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    var dirs: [String] = [], files: [String] = []
    for item in items {
        if isDir(item) { dirs.append(item.lastPathComponent) }
        else if markdownExts.contains(item.pathExtension.lowercased()) { files.append(item.lastPathComponent) }
    }
    dirs.sort { $0.lowercased() < $1.lowercased() }
    files.sort { $0.lowercased() < $1.lowercased() }
    var md = "# \(dir.lastPathComponent)/\n\n"
    if dirs.isEmpty && files.isEmpty { return md + "_No markdown files here._\n" }
    for d in dirs {
        let enc = d.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? d
        md += "- 🗂 [\(d)/](\(enc)/)\n"
    }
    for f in files {
        let enc = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
        md += "- [\(f)](\(enc))\n"
    }
    return md
}

var initialFile: URL? = nil
var stdinMD: String? = nil

let cliArgs = CommandLine.arguments
guard cliArgs.count == 2, !["-h", "--help"].contains(cliArgs[1]) else {
    die("usage: moremark <file.md | folder>   or   ... | moremark -", code: 64)
}
if cliArgs[1] == "-" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    stdinMD = String(data: data, encoding: .utf8) ?? ""
} else {
    let url = URL(fileURLWithPath: (cliArgs[1] as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        die("moremark: no such file: \(url.path)", code: 66)
    }
    initialFile = resolveTarget(url)
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
#tabbar { display: none; position: fixed; top: 0; left: 0; right: 0; z-index: 9;
  gap: 2px; padding: 6px 8px 0; overflow-x: auto;
  background: #f6f8fa; border-bottom: 1px solid #d1d9e0;
  font: 12px -apple-system, BlinkMacSystemFont, sans-serif; }
.tab { display: flex; align-items: center; gap: 6px; padding: 5px 10px; white-space: nowrap;
  color: #59636e; border: 1px solid transparent; border-radius: 6px 6px 0 0; cursor: default; }
.tab.active { background: #ffffff; color: #1f2328; border-color: #d1d9e0; border-bottom-color: #ffffff; }
.tab .x { opacity: 0.45; cursor: pointer; padding: 0 2px; }
.tab .x:hover { opacity: 1; }
@media (prefers-color-scheme: dark) {
  #tabbar { background: #161b22; border-color: #3d444d; }
  .tab { color: #9198a1; }
  .tab.active { background: #0d1117; color: #f0f6fc; border-color: #3d444d; border-bottom-color: #0d1117; }
}
body.tabs-on { padding-top: 32px; }
</style>
<script>\#(resource(markedJSBase64))</script>
<script>\#(resource(hljsJSBase64))</script>
<script>\#(resource(mermaidJSBase64))</script>
</head><body><nav id="tabbar"></nav><article id="content" class="markdown-body"></article>
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
function __tabs(list, active) {
  var bar = document.getElementById('tabbar');
  if (list.length < 2) {
    bar.style.display = 'none';
    document.body.classList.remove('tabs-on');
    return;
  }
  bar.style.display = 'flex';
  document.body.classList.add('tabs-on');
  bar.innerHTML = '';
  list.forEach(function (t, i) {
    var el = document.createElement('div');
    el.className = 'tab' + (i === active ? ' active' : '');
    var label = document.createElement('span');
    label.textContent = t.name;
    el.appendChild(label);
    var x = document.createElement('span');
    x.className = 'x';
    x.textContent = '×';
    x.addEventListener('click', function (e) {
      e.stopPropagation();
      window.webkit.messageHandlers.tabs.postMessage({ action: 'close', path: t.path });
    });
    el.appendChild(x);
    el.addEventListener('click', function () {
      window.webkit.messageHandlers.tabs.postMessage({ action: 'go', path: t.path });
    });
    bar.appendChild(el);
  });
}
darkMQ.addEventListener('change', function () {
  if (window.__lastMd !== undefined) __update(window.__lastMd);
});
</script>
</body></html>
"""#

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var source: DispatchSourceFileSystemObject?
    var pageLoaded = false

    var currentFile: URL? = initialFile
    var backStack: [URL] = []
    var forwardStack: [URL] = []
    var visited: [URL] = []
    var pendingFragment: String?

    var currentBaseDir: URL {
        guard let cur = currentFile else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return isDir(cur) ? cur : cur.deletingLastPathComponent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController.add(self, name: "tabs")
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
        if let cur = currentFile {
            if !visited.contains(cur) { visited.append(cur) }
            window.title = cur.lastPathComponent + (isDir(cur) ? "/" : "")
            window.subtitle = (currentBaseDir.path as NSString).abbreviatingWithTildeInPath
        } else {
            window.title = "stdin"
            window.subtitle = ""
        }
        webView.loadHTMLString(template, baseURL: currentBaseDir)
        watch()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        render()
        pushTabs()
        if let frag = pendingFragment {
            pendingFragment = nil
            let js = "var t = document.getElementById(\(jsString(frag))); if (t) t.scrollIntoView();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // In-page anchors stay; relative .md/folder links navigate in-window;
    // the rest goes to the default handler (browser, editor, Finder).
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
            let target = URL(fileURLWithPath: url.path).standardizedFileURL
            if isDir(target) || (markdownExts.contains(target.pathExtension.lowercased())
                && FileManager.default.fileExists(atPath: target.path)) {
                pendingFragment = url.fragment
                navigate(to: resolveTarget(target))
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
        currentFile = url.standardizedFileURL
        loadPage()
    }

    // Tab jump / tab-close switch: plain switch, optionally remembering where we were.
    func jump(to url: URL, push: Bool) {
        if push, let cur = currentFile, cur != url { backStack.append(cur) }
        pendingFragment = nil
        currentFile = url
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

    // MARK: history tabs

    func pushTabs() {
        guard pageLoaded else { return }
        let list = visited.map { ["name": $0.lastPathComponent + (isDir($0) ? "/" : ""), "path": $0.path] }
        let active = currentFile.flatMap { visited.firstIndex(of: $0) } ?? -1
        guard let data = try? JSONSerialization.data(withJSONObject: [list]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("__tabs(\(json)[0], \(active))", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "tabs",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let path = body["path"] as? String else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        switch action {
        case "go":
            if url != currentFile { jump(to: url, push: true) }
        case "close":
            visited.removeAll { $0 == url }
            backStack.removeAll { $0 == url }
            forwardStack.removeAll { $0 == url }
            if url == currentFile {
                if let last = visited.last { jump(to: last, push: false) }
            } else {
                pushTabs()
            }
        default: break
        }
    }

    func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(data: data, encoding: .utf8)! + "[0]"
    }

    @objc func render() {
        guard pageLoaded else { return }
        let md: String
        if let cur = currentFile {
            if isDir(cur) {
                md = indexMarkdown(for: cur)
            } else if let contents = try? String(contentsOf: cur, encoding: .utf8) {
                md = contents
            } else { return }
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
    // Watching a directory fd fires on entry add/remove, refreshing the index.
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
