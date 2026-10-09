#!/bin/sh
# (đoạn này là sh thuần) chưa chạy bằng bash, hoặc máy chưa có bash (Alpine/busybox): cài bash rồi chạy lại bằng bash
if [ -z "${_AGY_SETUP_BASH:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    _r=""; [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null 2>&1 && _r=sudo; }
    if command -v apk >/dev/null 2>&1; then $_r apk add --no-cache bash
    elif command -v apt-get >/dev/null 2>&1; then $_r apt-get update -qq && $_r apt-get install -y -qq bash
    elif command -v dnf >/dev/null 2>&1; then $_r dnf install -y -q bash
    elif command -v pacman >/dev/null 2>&1; then $_r pacman -Sy --noconfirm bash
    elif command -v brew >/dev/null 2>&1; then brew install bash
    else echo "setup.sh: cần bash; hãy cài bash rồi chạy lại" >&2; exit 2; fi
  fi
  _AGY_SETUP_BASH=1 exec bash "$0" "$@"
fi
# setup.sh: kiểm tra, cài đặt và tự sửa môi trường cho bộ agy (agy-hd, agy-sub, agy-fan, agy-ctl, agy-id, agy-p).
#
#   (chạy được cả bằng sh trên máy chưa có bash: tự cài bash trước)
#   setup.sh check          chỉ kiểm: in ✓/✗ từng thứ kèm cách sửa; thoát 1 nếu thiếu thứ bắt buộc
#   setup.sh fix [-y]       cài thứ còn thiếu rồi kiểm lại:
#                             - gói hệ thống (bash>=4.4, git, jq, python3, perl, curl, procps...) qua apt/dnf/yum/pacman/zypper/apk/brew
#                             - herdr: script chính thức (https://herdr.dev/install.sh), hoặc brew trên macOS
#                             - agy:   script chính thức (https://antigravity.google/cli/install.sh)
#                             - symlink skill vào ~/.claude/skills và lệnh vào ~/.local/bin
#                             - lịch chạy `agy-hd tick` mỗi phút: systemd (Linux), launchd (macOS), không có thì cron
#                             - ~/.local/bin vào PATH (hỏi trước, -y thì tự thêm)
#   -y                      không hỏi. Gói hệ thống chỉ tự cài khi đang là root hoặc sudo không cần mật khẩu;
#                           không thì in lệnh để người dùng tự chạy.
# Biến: CLAUDE_SKILLS_DIR (~/.claude/skills), BIN_DIR (~/.local/bin), AGY_SETUP_SKIP="agy herdr links sched path"
# Chạy được bằng bash 3.2 (macOS mặc định): chính script này cài bash mới hơn.
set -u

MODE=${1:-check}; YES=0
for a in "$@"; do [ "$a" = "-y" ] && YES=1; done
case $MODE in check|fix) ;; -h|--help|help) sed -n '/^# setup.sh:/,/^# Chạy được bằng bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; *) echo "dùng: setup.sh check | fix [-y]" >&2; exit 2 ;; esac

# thư mục repo (chứa các thư mục skill), lấy qua symlink mà không cần readlink -f
_s=$0; while [ -L "$_s" ]; do _d=$(cd -P "$(dirname "$_s")" && pwd); _s=$(readlink "$_s"); case $_s in /*) ;; *) _s=$_d/$_s ;; esac; done
REPO=$(cd -P "$(dirname "$_s")/../.." && pwd)
SKILLS_DIR=${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
SKIP=" ${AGY_SETUP_SKIP:-} "
SKILLS="agy-subagent agy-parallel agy-review claude-task-id agy-accounts agy-login agy-quota agy-switch agy-setup"
BAD=0 WARN=0

ok()   { echo "  ✓ $*"; }
no()   { echo "  ✗ $*"; BAD=$((BAD+1)); }
hmm()  { echo "  ! $*"; WARN=$((WARN+1)); }
has()  { command -v "$1" >/dev/null 2>&1; }
skip() { case $SKIP in *" $1 "*) return 0 ;; esac; return 1; }
ask()  { [ $YES = 1 ] && return 0; [ -t 0 ] || return 1; printf '%s [y/N] ' "$1"; read -r r; [ "$r" = y ] || [ "$r" = Y ]; }

# ── hệ điều hành + trình quản lý gói
OS=$(uname -s 2>/dev/null || echo unknown); ARCH=$(uname -m 2>/dev/null || echo ?); DISTRO=""; WSL=0; PM=""
case $OS in
  Linux)
    [ -r /etc/os-release ] && DISTRO=$(. /etc/os-release; echo "${ID:-linux}${VERSION_ID:+ $VERSION_ID}")
    grep -qi microsoft /proc/version 2>/dev/null && WSL=1
    for p in apt-get dnf yum pacman zypper apk; do has $p && { PM=$p; break; }; done ;;
  Darwin) DISTRO="macOS $(sw_vers -productVersion 2>/dev/null)"; has brew && PM=brew ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows (Git Bash/MSYS): agy-hd cần herdr + bash đầy đủ. Dùng WSL (wsl --install) rồi chạy lại setup.sh trong WSL;"
    echo "hoặc dùng bản PowerShell chạy không giao diện: agy-subagent/scripts/agy-sub.ps1 (cài agy: irm https://antigravity.google/cli/install.ps1 | iex)."
    exit 1 ;;
esac
echo "== $OS $ARCH${DISTRO:+ ($DISTRO)}$( [ $WSL = 1 ] && echo ', WSL'), quản lý gói: ${PM:-không có}, repo: $REPO"

SUDO=""
pm_run() {  # pm_run <lệnh cài...>: chạy bằng root/sudo nếu được phép, không thì in lệnh
  local need_root=1; [ "$PM" = brew ] && need_root=0
  if [ $need_root = 1 ] && [ "$(id -u)" != 0 ]; then
    if sudo -n true 2>/dev/null; then SUDO="sudo"
    elif [ $YES = 0 ] && [ -t 0 ] && has sudo && ask "Cần sudo để cài: $*. Chạy không?"; then SUDO="sudo"
    else echo "  → tự chạy lệnh này rồi chạy lại setup.sh fix:  sudo $*"; return 1; fi
  fi
  $SUDO "$@"
}

# tên gói theo trình quản lý gói: pkgname <lệnh cần có>
pkgname() {
  case "$PM:$1" in
    *:bash) echo bash ;; *:git) echo git ;; *:jq) echo jq ;; *:curl) echo curl ;; *:perl) echo perl ;;
    pacman:python3) echo python ;; brew:python3) echo python ;; *:python3) echo python3 ;;
    apt-get:pgrep|apt-get:ps) echo procps ;; dnf:pgrep|dnf:ps|yum:pgrep|yum:ps) echo procps-ng ;; pacman:pgrep|pacman:ps) echo procps-ng ;;
    apk:pgrep|apk:ps) echo procps ;; zypper:pgrep|zypper:ps) echo procps ;; brew:*) echo "" ;;
    apt-get:flock|apk:flock|dnf:flock|yum:flock|pacman:flock|zypper:flock) echo util-linux ;;
    apt-get:column) echo bsdextrautils ;; apk:column|dnf:column|yum:column|pacman:column|zypper:column) echo util-linux ;;
    apk:timeout|apk:stat|apt-get:timeout|dnf:timeout|yum:timeout|pacman:timeout|zypper:timeout) echo coreutils ;; apk:find) echo findutils ;; apk:tar) echo tar ;; apk:gzip) echo gzip ;;
    *:tar) echo tar ;; *:gzip) echo gzip ;;
    *) echo "" ;;
  esac
}
bash_ok() {  # có bash >= 4.4 không (ở PATH hoặc Homebrew)
  local b; for b in "$(command -v bash)" /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash; do
    [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null && { echo "$b"; return 0; }
  done; return 1
}

check_tools() {  # in trạng thái, đặt MISSING (lệnh bắt buộc còn thiếu) và OPTMISS (lệnh nên có)
  MISSING=""; OPTMISS=""
  echo "công cụ hệ thống"
  if b=$(bash_ok); then ok "bash >= 4.4 ($b)"; else no "bash >= 4.4 (đang có ${BASH_VERSION})"; MISSING="$MISSING bash"; fi
  for c in git jq python3 perl curl tar gzip pgrep ps; do
    if has $c; then ok "$c"; else no "$c"; MISSING="$MISSING $c"; fi
  done
  for c in flock timeout column; do   # có compat.sh giả lập, nhưng bản gốc nhanh và chắc hơn
    if has $c; then ok "$c"; else hmm "$c chưa có (compat.sh sẽ giả lập bằng perl)"; OPTMISS="$OPTMISS $c"; fi
  done
  # busybox (Alpine...) có ps/timeout nhưng thiếu tính năng: ps không có -p/-o, timeout trả 143 thay vì 124
  if has ps && [ "$OS" = Linux ] && ! ps -o pid= -p $$ >/dev/null 2>&1; then hmm "ps là bản busybox (thiếu -p/-o): nên cài procps"; OPTMISS="$OPTMISS ps"; fi
  if has timeout && [ "$OS" = Linux ] && ! timeout --version 2>&1 | grep -q 'GNU coreutils'; then hmm "timeout không phải bản GNU: nên cài coreutils"; OPTMISS="$OPTMISS timeout"; fi
}
check_apps() {
  echo "ứng dụng"
  if has herdr; then ok "herdr $(herdr --version 2>/dev/null | awk '{print $2}')"; else no "herdr (bắt buộc cho agy-hd)"; fi
  if has agy || [ -x "$HOME/.local/bin/agy" ]; then ok "agy $("$(command -v agy || echo "$HOME/.local/bin/agy")" --version 2>/dev/null | head -1)"
  else no "agy (Antigravity CLI)"; fi
}
check_links() {
  echo "skill + lệnh"
  local s n miss=0
  for s in $SKILLS; do
    [ -d "$REPO/$s" ] || continue
    [ "$(cd -P "$SKILLS_DIR/$s" 2>/dev/null && pwd)" = "$(cd -P "$REPO/$s" && pwd)" ] || { miss=$((miss+1)); }
  done
  [ $miss = 0 ] && ok "skill đã liên kết vào $SKILLS_DIR" || no "$miss skill chưa liên kết vào $SKILLS_DIR"
  miss=0
  for n in agy-hd agy-sub agy-fan agy-ctl agy-id agy-p agy-setup; do [ -x "$BIN_DIR/$n" ] || miss=$((miss+1)); done
  [ $miss = 0 ] && ok "lệnh có trong $BIN_DIR" || no "$miss lệnh chưa có trong $BIN_DIR"
  case ":$PATH:" in *":$BIN_DIR:"*) ok "$BIN_DIR nằm trong PATH" ;; *) no "$BIN_DIR chưa nằm trong PATH" ;; esac
}
sched_kind() {  # systemd | launchd | cron | none
  case $OS in
    Darwin) echo launchd ;;
    Linux) if systemctl --user show-environment >/dev/null 2>&1; then echo systemd; elif has crontab; then echo cron; else echo none; fi ;;
    *) has crontab && echo cron || echo none ;;
  esac
}
check_sched() {
  echo "lịch chạy agy-hd tick (mỗi phút: theo dõi job, tự đổi account khi hết quota)"
  case $(sched_kind) in
    systemd) systemctl --user is-active agy-hd-tick.timer >/dev/null 2>&1 && ok "systemd timer agy-hd-tick đang chạy" || no "systemd timer agy-hd-tick chưa bật" ;;
    launchd) launchctl list 2>/dev/null | grep -q dev.agy.hd-tick && ok "launchd dev.agy.hd-tick đã nạp" || no "launchd dev.agy.hd-tick chưa nạp" ;;
    cron)    crontab -l 2>/dev/null | grep -q 'agy-hd tick' && ok "cron chạy agy-hd tick" || no "cron chưa có agy-hd tick" ;;
    none)    hmm "không có systemd/launchd/cron: tick chỉ chạy khi gọi agy-hd watch hoặc agy-hd tick" ;;
  esac
}
run_checks() { BAD=0; WARN=0; check_tools; check_apps; check_links; check_sched; }

# ── sửa
fix_tools() {
  local miss="$MISSING $OPTMISS" pk pkgs="" c
  [ -z "${miss// /}" ] && return 0
  if [ -z "$PM" ]; then
    [ $OS = Darwin ] && echo "  → cần Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" \
      || echo "  → không nhận ra trình quản lý gói; tự cài:$miss"
    return 1
  fi
  for c in $miss; do pk=$(pkgname $c); [ -n "$pk" ] && case " $pkgs " in *" $pk "*) ;; *) pkgs="$pkgs $pk" ;; esac; done
  [ $OS = Darwin ] && case " $MISSING " in *" bash "*) pkgs="$pkgs bash" ;; esac
  [ $OS = Darwin ] && case " $OPTMISS " in *" flock "*) pkgs="$pkgs flock" ;; esac
  [ $OS = Darwin ] && case " $OPTMISS " in *" timeout "*) pkgs="$pkgs coreutils" ;; esac
  pkgs=${pkgs# }; [ -z "$pkgs" ] && return 0
  echo "  cài gói: $pkgs"
  case $PM in
    apt-get) pm_run apt-get update -qq && pm_run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs ;;
    dnf|yum) pm_run $PM install -y -q $pkgs ;;
    pacman)  pm_run pacman -Sy --noconfirm --needed $pkgs ;;
    zypper)  pm_run zypper --non-interactive install $pkgs ;;
    apk)     pm_run apk add --no-cache $pkgs ;;
    brew)    brew install $pkgs ;;
  esac
}
fix_apps() {
  if ! has herdr && ! skip herdr; then
    echo "  cài herdr"
    if [ $OS = Darwin ] && has brew; then brew install herdr
    else curl -fsSL https://herdr.dev/install.sh | sh; fi
    [ -x "$HOME/.local/bin/herdr" ] && export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! has agy && [ ! -x "$HOME/.local/bin/agy" ] && ! skip agy; then
    echo "  cài agy (Antigravity CLI)"
    curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --skip-path
  fi
}
fix_links() {
  skip links && return 0
  mkdir -p "$SKILLS_DIR" "$BIN_DIR"
  local s; for s in $SKILLS; do [ -d "$REPO/$s" ] && ln -sfn "$REPO/$s" "$SKILLS_DIR/$s"; done
  chmod +x "$REPO"/agy-subagent/scripts/*.sh "$REPO"/claude-task-id/scripts/*.sh "$REPO"/agy-accounts/scripts/agy-p.sh \
    "$REPO"/agy-accounts/scripts/login.py "$REPO"/agy-accounts/scripts/shim/agy "$REPO"/agy-setup/scripts/setup.sh 2>/dev/null
  ln -sfn "$REPO/agy-subagent/scripts/agy-hd.sh"  "$BIN_DIR/agy-hd"
  ln -sfn "$REPO/agy-subagent/scripts/agy-sub.sh" "$BIN_DIR/agy-sub"
  ln -sfn "$REPO/agy-subagent/scripts/agy-fan.sh" "$BIN_DIR/agy-fan"
  ln -sfn "$REPO/agy-subagent/scripts/agy-ctl.sh" "$BIN_DIR/agy-ctl"
  ln -sfn "$REPO/claude-task-id/scripts/agy-id.sh" "$BIN_DIR/agy-id"
  ln -sfn "$REPO/agy-accounts/scripts/agy-p.sh"   "$BIN_DIR/agy-p"
  ln -sfn "$REPO/agy-setup/scripts/setup.sh"      "$BIN_DIR/agy-setup"
  echo "  đã liên kết skill vào $SKILLS_DIR và lệnh vào $BIN_DIR"
}
fix_sched() {
  skip sched && return 0
  local path="$BIN_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  case $(sched_kind) in
    systemd)
      local d="$HOME/.config/systemd/user"; mkdir -p "$d"
      cp "$REPO/agy-subagent/systemd/agy-hd-tick.service" "$REPO/agy-subagent/systemd/agy-hd-tick.timer" "$d/"
      systemctl --user daemon-reload && systemctl --user enable --now agy-hd-tick.timer >/dev/null 2>&1 && echo "  đã bật systemd timer agy-hd-tick" ;;
    launchd)
      local pl="$HOME/Library/LaunchAgents/dev.agy.hd-tick.plist"; mkdir -p "$(dirname "$pl")" "$HOME/.cache/agy-hd"
      cat >"$pl" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.agy.hd-tick</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/agy-hd</string><string>tick</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$path</string></dict>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardErrorPath</key><string>$HOME/.cache/agy-hd/tick.err</string>
</dict></plist>
EOF
      launchctl unload "$pl" 2>/dev/null; launchctl load -w "$pl" && echo "  đã nạp launchd dev.agy.hd-tick (mỗi 60 s)" ;;
    cron)
      if ! crontab -l 2>/dev/null | grep -q 'agy-hd tick'; then
        { crontab -l 2>/dev/null; echo "* * * * * PATH=$path agy-hd tick >/dev/null 2>&1"; } | crontab - && echo "  đã thêm cron: agy-hd tick mỗi phút"
      fi ;;
    none) echo "  không có systemd/launchd/cron: bỏ qua lịch chạy" ;;
  esac
}
fix_path() {
  skip path && return 0
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac
  local rc="$HOME/.bashrc"; case ${SHELL:-} in */zsh) rc="$HOME/.zshrc" ;; esac
  if ask "Thêm $BIN_DIR vào PATH trong $rc?"; then
    printf '\n# bộ agy (agy-hd, agy-p...)\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >>"$rc"; echo "  đã thêm vào $rc (mở terminal mới để áp dụng)"
  else echo "  → thêm vào $rc:  export PATH=\"$BIN_DIR:\$PATH\""; fi
  export PATH="$BIN_DIR:$PATH"
}

run_checks
if [ "$MODE" = fix ]; then
  echo "== sửa"
  fix_tools; fix_apps; fix_links; fix_path; fix_sched
  echo "== kiểm lại"; run_checks
fi
echo "---"
echo "$BAD thiếu/lỗi, $WARN cảnh báo"
[ "$BAD" = 0 ] && has agy-p && echo "Tiếp theo: agy-p add (đăng nhập account), agy-p doctor (kiểm toàn bộ)."
[ "$BAD" = 0 ]
