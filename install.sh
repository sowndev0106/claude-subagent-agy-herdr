#!/usr/bin/env bash
# install.sh: Install claude-subagent-agy-herdr
# - Symlink skills into ~/.claude/skills/
# - Symlink CLI binaries into ~/.local/bin/
# - Install & enable systemd user timer for 1-minute watchdog & auto-restart

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

echo "==> Installing claude-subagent-agy-herdr..."
echo "    Source: $REPO_DIR"

mkdir -p "$CLAUDE_SKILLS_DIR" "$BIN_DIR" "$SYSTEMD_USER_DIR"

# 1. Symlink skills
echo "==> 1. Symlinking skills to $CLAUDE_SKILLS_DIR..."
for skill in agy-subagent agy-parallel agy-review claude-task-id; do
  if [ -d "$REPO_DIR/$skill" ]; then
    ln -sfn "$REPO_DIR/$skill" "$CLAUDE_SKILLS_DIR/$skill"
    echo "    ✓ $CLAUDE_SKILLS_DIR/$skill -> $REPO_DIR/$skill"
  fi
done

# 2. Symlink binaries
echo "==> 2. Symlinking binaries to $BIN_DIR..."
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
echo "==> 3. Setting up systemd watchdog timer..."
cp "$REPO_DIR/agy-subagent/systemd/agy-hd-tick.service" "$SYSTEMD_USER_DIR/"
cp "$REPO_DIR/agy-subagent/systemd/agy-hd-tick.timer" "$SYSTEMD_USER_DIR/"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable --now agy-hd-tick.timer || true
  echo "    ✓ agy-hd-tick.timer enabled and running"
else
  echo "    ! systemctl not available, skipping timer activation"
fi

# 4. Check PATH and dependencies
echo ""
echo "==> Verifying environment:"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "    [WARNING] $BIN_DIR is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\" to ~/.bashrc or ~/.zshrc"
else
  echo "    ✓ $BIN_DIR is in PATH"
fi

for cmd in agy herdr git jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "    ✓ $cmd: $(command -v "$cmd")"
  else
    echo "    ! Missing dependency: $cmd (recommended for full functionality)"
  fi
done

echo ""
echo "==> Installation complete!"
echo "    Add the following to ~/.claude/settings.json (permissions.allow):"
echo '    "Bash(agy-hd:*)", "Bash(agy-sub:*)", "Bash(agy-fan:*)", "Bash(agy-ctl:*)", "Bash(agy-id:*)"'
