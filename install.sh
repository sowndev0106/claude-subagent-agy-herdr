#!/usr/bin/env bash
# install.sh: Cài đặt claude-subagent-agy-herdr
# - Symlink các skills vào ~/.claude/skills/
# - Symlink các CLI binaries vào ~/.local/bin/
# - Cài đặt systemd user timer giám sát subagent mỗi phút

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

echo "==> Cài đặt claude-subagent-agy-herdr..."
echo "    Nguồn: $REPO_DIR"

mkdir -p "$CLAUDE_SKILLS_DIR" "$BIN_DIR" "$SYSTEMD_USER_DIR"

# 1. Symlink skills
echo "==> 1. Đang symlink skills vào $CLAUDE_SKILLS_DIR..."
for skill in agy-subagent agy-parallel agy-review claude-task-id; do
  if [ -d "$REPO_DIR/$skill" ]; then
    ln -sfn "$REPO_DIR/$skill" "$CLAUDE_SKILLS_DIR/$skill"
    echo "    ✓ $CLAUDE_SKILLS_DIR/$skill -> $REPO_DIR/$skill"
  fi
done

# 2. Symlink binaries
echo "==> 2. Đang symlink binaries vào $BIN_DIR..."
chmod +x "$REPO_DIR"/agy-subagent/scripts/*.sh "$REPO_DIR"/claude-task-id/scripts/*.sh

ln -sfn "$REPO_DIR/agy-subagent/scripts/agy-hd.sh" "$BIN_DIR/agy-hd"
echo "    ✓ $BIN_DIR/agy-hd"
ln -sfn "$REPO_DIR/agy-subagent/scripts/agy-sub.sh" "$BIN_DIR/agy-sub"
echo "    ✓ $BIN_DIR/agy-sub"
ln -sfn "$REPO_DIR/agy-subagent/scripts/agy-fan.sh" "$BIN_DIR/agy-fan"
echo "    ✓ $BIN_DIR/agy-fan"
ln -sfn "$REPO_DIR/agy-subagent/scripts/agy-ctl.sh" "$BIN_DIR/agy-ctl"
echo "    ✓ $BIN_DIR/agy-ctl"
ln -sfn "$REPO_DIR/claude-task-id/scripts/agy-id.sh" "$BIN_DIR/agy-id"
echo "    ✓ $BIN_DIR/agy-id"

# 3. Systemd timer
echo "==> 3. Cài đặt systemd timer (kiểm tra agy mỗi phút & auto-restart khi quota)..."
cp "$REPO_DIR/agy-subagent/systemd/agy-hd-tick.service" "$SYSTEMD_USER_DIR/"
cp "$REPO_DIR/agy-subagent/systemd/agy-hd-tick.timer" "$SYSTEMD_USER_DIR/"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable --now agy-hd-tick.timer || true
  echo "    ✓ agy-hd-tick.timer đã được kích hoạt"
else
  echo "    ! Không tìm thấy systemctl, bỏ qua bước kích hoạt timer"
fi

# 4. Kiểm tra PATH và dependencies
echo ""
echo "==> Kiểm tra môi trường:"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "    [CẢNH BÁO] $BIN_DIR chưa có trong PATH của bạn. Hãy thêm: export PATH=\"\$HOME/.local/bin:\$PATH\" vào ~/.bashrc hoặc ~/.zshrc"
else
  echo "    ✓ $BIN_DIR đã có trong PATH"
fi

for cmd in agy herdr git jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "    ✓ $cmd: $(command -v "$cmd")"
  else
    echo "    ! Chưa cài đặt: $cmd (cần thiết cho đầy đủ tính năng)"
  fi
done

echo ""
echo "==> Cài đặt thành công!"
echo "    Đừng quên thêm các quyền sau vào ~/.claude/settings.json (permissions.allow):"
echo '    "Bash(agy-hd:*)", "Bash(agy-sub:*)", "Bash(agy-fan:*)", "Bash(agy-ctl:*)", "Bash(agy-id:*)"'
