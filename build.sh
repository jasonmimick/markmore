#!/bin/bash
# ./build.sh              build + install to ~/Applications and ~/.local/bin
# ./build.sh --build-only assemble ./moremark.app in cwd only (used by Homebrew)
set -euo pipefail
cd "$(dirname "$0")"

vendor() { [ -f "$2" ] || curl -fsSL "$1" -o "$2"; }
vendor https://cdn.jsdelivr.net/npm/marked/marked.min.js marked.min.js
vendor https://cdn.jsdelivr.net/npm/github-markdown-css/github-markdown.css github-markdown.css
vendor https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js highlight.min.js
vendor https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github.min.css hljs-github.css
vendor https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css hljs-github-dark.css
vendor https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js mermaid.min.js

b64() { base64 -i "$1" | tr -d '\n'; }
cat > Resources.swift <<EOF
let markedJSBase64 = "$(b64 marked.min.js)"
let ghCSSBase64 = "$(b64 github-markdown.css)"
let hljsJSBase64 = "$(b64 highlight.min.js)"
let hljsLightCSSBase64 = "$(b64 hljs-github.css)"
let hljsDarkCSSBase64 = "$(b64 hljs-github-dark.css)"
let mermaidJSBase64 = "$(b64 mermaid.min.js)"
EOF

swiftc -O -o moremark-bin main.swift Resources.swift

if [ ! -f moremark.icns ]; then
  swift genicon.swift
  iconutil -c icns moremark.iconset -o moremark.icns
fi

APP="moremark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp moremark-bin "$APP/Contents/MacOS/moremark"
cp Info.plist "$APP/Contents/Info.plist"
cp moremark.icns "$APP/Contents/Resources/moremark.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [ "${1:-}" = "--build-only" ]; then
  echo "built: ./$APP"
  exit 0
fi

rm -rf "$HOME/Applications/moremark.app"
mkdir -p "$HOME/Applications"
cp -R "$APP" "$HOME/Applications/moremark.app"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/moremark" <<'EOF'
#!/bin/bash
exec "$HOME/Applications/moremark.app/Contents/MacOS/moremark" "$@"
EOF
chmod +x "$HOME/.local/bin/moremark"
echo "installed: ~/Applications/moremark.app + ~/.local/bin/moremark"
