#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

echo "==> Đang biên dịch AgyBar cho macOS (arm64)..."
swiftc -O \
  -framework AppKit \
  -framework Foundation \
  Models.swift \
  QuotaManager.swift \
  MenuViewBuilder.swift \
  AppDelegate.swift \
  main.swift \
  -o AgyBar

echo "==> Đóng gói AgyBar.app..."
rm -rf AgyBar.app
mkdir -p AgyBar.app/Contents/MacOS
mkdir -p AgyBar.app/Contents/Resources
cp Info.plist AgyBar.app/Contents/
mv AgyBar AgyBar.app/Contents/MacOS/

TARGET_DIR="$HOME/Applications"
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR/AgyBar.app"
cp -R AgyBar.app "$TARGET_DIR/"
rm -rf AgyBar.app

mkdir -p "$HOME/.local/bin"
cat << 'EOF' > "$HOME/.local/bin/agy-bar"
#!/usr/bin/env bash
APP="$HOME/Applications/AgyBar.app"
case ${1:-} in
  stop|kill)
    pkill -f "AgyBar.app/Contents/MacOS/AgyBar" 2>/dev/null && echo "Đã dừng AgyBar" || echo "AgyBar chưa chạy"
    ;;
  restart)
    pkill -f "AgyBar.app/Contents/MacOS/AgyBar" 2>/dev/null || true
    sleep 0.5
    open -a "$APP"
    echo "Đã khởi động lại AgyBar"
    ;;
  status)
    if pgrep -f "AgyBar.app/Contents/MacOS/AgyBar" >/dev/null; then
      echo "AgyBar đang chạy (PID: $(pgrep -f "AgyBar.app/Contents/MacOS/AgyBar" | tr '\n' ' '))"
    else
      echo "AgyBar chưa chạy"
    fi
    ;;
  start|"")
    if pgrep -f "AgyBar.app/Contents/MacOS/AgyBar" >/dev/null; then
      echo "AgyBar đã đang chạy"
    else
      open -a "$APP"
      echo "Đã mở AgyBar trên thanh Menu Bar"
    fi
    ;;
  *)
    echo "Dùng: agy-bar [start|stop|restart|status]"
    exit 1
    ;;
esac
EOF
chmod +x "$HOME/.local/bin/agy-bar"

echo "==> Hoàn tất! AgyBar đã được cài đặt vào $TARGET_DIR/AgyBar.app và lệnh ~/.local/bin/agy-bar"
