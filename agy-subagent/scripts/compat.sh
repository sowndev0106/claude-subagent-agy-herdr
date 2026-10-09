# compat.sh: lớp tương thích cho các script agy (agy-hd, agy-sub, agy-fan, agy-ctl, agy-p, agy-id).
# Được `source` ở đầu script. Mục tiêu: chạy được trên Linux (GNU), macOS (BSD) và Linux tối giản (busybox).
#   1. bash < 4.4 (macOS mặc định 3.2): tự chạy lại script bằng bash mới hơn nếu có (Homebrew), không thì báo cách sửa.
#   2. Hàm thay cho công cụ chỉ có trên GNU/Linux: có công cụ gốc thì dùng (nhanh), không thì dùng perl/python
#      (có sẵn trên macOS và hầu hết Linux). flock/timeout/setsid/tac/md5sum/sha256sum/column/readlink -f
#      được giả lập bằng hàm cùng tên khi máy thiếu.
#   3. agy_require <lệnh...>: thiếu thì TỰ SỬA bằng `setup.sh fix -y` (tối đa 1 lần/giờ, log ~/.cache/agy-setup/repair.log),
#      vẫn thiếu thì in đúng cách sửa. Tắt tự sửa: AGY_AUTO_REPAIR=0.
# AGY_COMPAT_FORCE=1 ép dùng các bản giả lập (để test nhánh macOS/busybox ngay trên Linux).
# Chỉ dùng cú pháp bash 3.2 cho tới đoạn tự chạy lại.
[ -n "${_AGY_COMPAT_LOADED:-}" ] && return 0
_AGY_COMPAT_LOADED=1
_AGY_COMPAT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGY_SETUP="$_AGY_COMPAT_DIR/../../agy-setup/scripts/setup.sh"

# ── 1. bash >= 4.4
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash "$(command -v bash 2>/dev/null)"; do
    if [ -x "$_b" ] && "$_b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null; then
      exec "$_b" "$0" "$@"
    fi
  done
  echo "agy: cần bash >= 4.4 (đang chạy $BASH_VERSION). macOS: brew install bash. Hoặc chạy: $AGY_SETUP fix" >&2
  exit 2
fi

_agy_native() { [[ -z ${AGY_COMPAT_FORCE:-} ]]; }
_agy_has() { command -v "$1" >/dev/null 2>&1; }
AGY_OS=$(uname -s 2>/dev/null || echo unknown)   # Linux | Darwin | ...

agy_require() {  # agy_require <lệnh>...: thiếu thì tự sửa một lần (setup.sh fix -y), vẫn thiếu thì báo cách sửa và thoát
  local c miss=() log=$HOME/.cache/agy-setup/repair.log mark=$HOME/.cache/agy-setup/last-auto-repair
  for c in "$@"; do _agy_has "$c" || miss+=("$c"); done
  (( ${#miss[@]} == 0 )) && return 0
  # tự sửa: không lồng nhau, tối đa 1 lần mỗi giờ (tick chạy mỗi phút không được cài đi cài lại)
  if [[ ${AGY_AUTO_REPAIR:-1} != 0 && -z ${AGY_REPAIRING:-} && -f $AGY_SETUP ]] \
     && ! [[ -f $mark && $(( $(date +%s) - $(file_mtime "$mark" 2>/dev/null || echo 0) )) -lt 3600 ]]; then
    mkdir -p "${log%/*}"; : >"$mark"
    echo "agy: thiếu ${miss[*]}: đang tự sửa bằng setup.sh fix -y (tắt: AGY_AUTO_REPAIR=0; log: $log)" >&2
    { echo "=== $(date '+%F %T') tự sửa vì thiếu: ${miss[*]} (từ $0)"; AGY_REPAIRING=1 bash "$AGY_SETUP" fix -y; } >>"$log" 2>&1
    hash -r; [[ :$PATH: == *":$HOME/.local/bin:"* ]] || PATH=$HOME/.local/bin:$PATH
    miss=(); for c in "$@"; do _agy_has "$c" || miss+=("$c"); done
    (( ${#miss[@]} == 0 )) && { echo "agy: đã tự sửa xong" >&2; return 0; }
  fi
  echo "agy: thiếu ${miss[*]}. Sửa: $AGY_SETUP fix   (xem: $AGY_SETUP check; log tự sửa: $log)" >&2
  exit 2
}

# ── 2. hàm thay thế
_agy_perl() { _agy_has perl || { echo "agy: cần perl cho chế độ tương thích (hoặc cài công cụ GNU): $AGY_SETUP fix" >&2; return 2; }; perl "$@"; }

file_mtime() {  # giây epoch lần sửa cuối
  if _agy_native && [[ $AGY_OS == Linux ]]; then stat -c %Y "$1"
  elif _agy_native && [[ $AGY_OS == Darwin ]]; then stat -f %m "$1"
  else _agy_perl -e 'my @s = stat $ARGV[0] or exit 1; print "$s[9]\n"' "$1"; fi
}
file_mode() {  # quyền dạng bát phân, vd 600
  if _agy_native && [[ $AGY_OS == Linux ]]; then stat -c %a "$1"
  elif _agy_native && [[ $AGY_OS == Darwin ]]; then stat -f %Lp "$1"
  else _agy_perl -e 'my @s = stat $ARGV[0] or exit 1; printf "%o\n", $s[2] & 07777' "$1"; fi
}
sedi() {  # sedi '<biểu thức sed>' <file>: sửa tại chỗ, giống nhau trên GNU/BSD (sed -i khác cú pháp), ghi nguyên tử
  local t; t=$(mktemp "$2.XXXXXX") || return 1
  if sed -e "$1" "$2" >"$t"; then mv -f "$t" "$2"; else rm -f "$t"; return 1; fi
}
fmt_hms() {  # giờ:phút:giây của một mốc epoch
  if _agy_native && [[ $AGY_OS == Linux ]]; then date -d "@$1" +%H:%M:%S
  elif _agy_native && [[ $AGY_OS == Darwin ]]; then date -r "$1" +%H:%M:%S
  else _agy_perl -MPOSIX=strftime -e 'print strftime("%H:%M:%S", localtime $ARGV[0]), "\n"' "$1"; fi
}
proc_cwd() {  # thư mục làm việc của tiến trình
  if _agy_native && [[ -e /proc/$1/cwd ]]; then readlink "/proc/$1/cwd"; return; fi
  local c=""   # pwdx (procps) trước; lsof sau (macOS) và chỉ nhận khi có kết quả (lsof của busybox không hiểu -a/-d/-F)
  _agy_has pwdx && c=$(pwdx "$1" 2>/dev/null | sed -n 's/^[0-9]*: //p')
  [[ -z $c ]] && _agy_has lsof && c=$(lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  echo "$c"
}
proc_args() {  # dòng lệnh của tiến trình trên một dòng
  if _agy_native && [[ -r /proc/$1/cmdline ]]; then tr '\0\n\t' '   ' <"/proc/$1/cmdline"
  else ps -o args= -p "$1" 2>/dev/null; fi
}
proc_has_arg() {  # proc_has_arg <pid> <tham số>: tiến trình có đúng tham số này không (so khớp nguyên tham số)
  if _agy_native && [[ -r /proc/$1/cmdline ]]; then grep -qxF -- "$2" < <(tr '\0' '\n' <"/proc/$1/cmdline")
  else [[ " $(ps -o args= -p "$1" 2>/dev/null) " == *" $2 "* ]]; fi
}
proc_age_s() {  # tiến trình đã chạy bao nhiêu giây (Linux: đọc /proc, đúng cả với ps của busybox)
  if _agy_native && [[ -r /proc/$1/stat && -r /proc/uptime ]]; then
    awk -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" 'NR == FNR { up = $1; next }
      { sub(/.*\) /, ""); print int(up - $20 / hz) }' /proc/uptime "/proc/$1/stat"
  elif _agy_native && ps -o etimes= -p "$1" >/dev/null 2>&1; then ps -o etimes= -p "$1" | tr -d ' '
  else ps -o etime= -p "$1" 2>/dev/null | awk '{ n = split($1, a, /[-:]/); s = 0
      if (n == 4) s = a[1]*86400 + a[2]*3600 + a[3]*60 + a[4]; else if (n == 3) s = a[1]*3600 + a[2]*60 + a[3]; else if (n == 2) s = a[1]*60 + a[2]
      print s }'; fi
}
mem_avail_mb() {  # RAM còn dùng được (MB); không biết thì in số rất lớn (bỏ qua kiểm tra RAM)
  if _agy_native && [[ -r /proc/meminfo ]]; then awk '/MemAvailable/ { printf "%d\n", $2/1024; f=1 } END { if (!f) print 999999 }' /proc/meminfo
  elif [[ $AGY_OS == Darwin ]] && _agy_has vm_stat; then
    vm_stat | awk '/page size of/ { ps = $8 } /Pages (free|inactive|speculative)/ { gsub(/\./, "", $NF); n += $NF } END { printf "%d\n", n * (ps ? ps : 4096) / 1048576 }'
  else echo 999999; fi
}
swap_used_pct() {  # % swap đã dùng; không biết thì 0
  if _agy_native && [[ -r /proc/meminfo ]]; then awk '/SwapTotal/ { t = $2 } /SwapFree/ { f = $2 } END { print (t > 0 ? int((t - f) * 100 / t) : 0) }' /proc/meminfo
  elif [[ $AGY_OS == Darwin ]]; then sysctl -n vm.swapusage 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) { if ($i == "total") t = $(i+2) + 0; if ($i == "used") u = $(i+2) + 0 } } END { print (t > 0 ? int(u * 100 / t) : 0) }'
  else echo 0; fi
}

# Công cụ thiếu → hàm cùng tên (call site giữ nguyên). AGY_COMPAT_FORCE=1 thì luôn dùng bản giả lập.
if ! _agy_native || ! _agy_has flock; then
  flock() {  # flock [-n] [-w giây] [-u] [-s] <fd>: khoá gắn với file description của fd (giữ sau khi perl thoát)
    local mode=ex wait=-1
    while [[ $# -gt 1 ]]; do case $1 in -n) wait=0;; -u) mode=un;; -s) mode=sh;; -w) wait=$2; shift;; *) break;; esac; shift; done
    _agy_perl -e '
      use Fcntl qw(:flock); my ($fd, $mode, $wait) = @ARGV; my $fh;
      open($fh, "+<&=", $fd) or open($fh, ">&=", $fd) or open($fh, "<&=", $fd) or exit 2;
      if ($mode eq "un") { flock($fh, LOCK_UN); exit 0 }
      my $op = $mode eq "sh" ? LOCK_SH : LOCK_EX;
      exit(flock($fh, $op) ? 0 : 1) if $wait < 0;
      my $end = time + $wait;
      while (1) { exit 0 if flock($fh, $op | LOCK_NB); exit 1 if time >= $end; select(undef, undef, undef, 0.1) }' "$1" "$mode" "$wait"
  }
fi
# timeout của busybox trả 143 thay vì 124 khi hết giờ: chỉ dùng bản GNU, không thì giả lập
if ! _agy_native || ! { _agy_has timeout && timeout --version 2>&1 | grep -q 'GNU coreutils'; }; then
  if _agy_native && _agy_has gtimeout; then timeout() { gtimeout "$@"; }
  else
    timeout() {  # timeout [-s SIG] <giây> <lệnh...>: hết giờ thì TERM (KILL sau 2 s), mã thoát 124 như GNU
      local sig=TERM; [[ ${1:-} == -s ]] && { sig=$2; shift 2; }
      _agy_perl -e '
        my ($t, $sig) = (shift, shift); my $pid = fork; die "fork: $!" unless defined $pid;
        if (!$pid) { exec @ARGV or exit 127 }
        local $SIG{ALRM} = sub { kill $sig, $pid; sleep 2; kill "KILL", $pid; waitpid($pid, 0); exit 124 };
        alarm $t; waitpid($pid, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "${1%s}" "$sig" "${@:2}"
    }
  fi
fi
if ! _agy_native || ! _agy_has setsid; then
  setsid() { _agy_perl -MPOSIX=setsid -e 'my $p = fork; exit 0 if $p; setsid(); exec @ARGV or exit 127' "$@"; }
fi
if ! _agy_native || ! _agy_has tac; then
  tac() { if _agy_native && [[ $AGY_OS == Darwin ]]; then tail -r "$@"; else _agy_perl -e 'print reverse <>' "$@"; fi; }
fi
if ! _agy_native || ! _agy_has md5sum; then
  md5sum() { _agy_perl -MDigest::MD5 -e 'my $c = Digest::MD5->new; $c->addfile(*STDIN); print $c->hexdigest, "  -\n"'; }
fi
if ! _agy_native || ! _agy_has sha256sum; then
  sha256sum() { _agy_perl -MDigest::SHA -e 'my $c = Digest::SHA->new(256); $c->addfile(*STDIN); print $c->hexdigest, "  -\n"'; }
fi
if ! _agy_native || ! _agy_has column; then
  column() {  # chỉ hỗ trợ dạng column -t -s $'\t' mà các script dùng
    awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > m) m = NF; n = NR }
      END { for (r = 1; r <= n; r++) { s = ""; for (i = 1; i <= m; i++) s = s sprintf(i < m ? "%-" w[i] + 2 "s" : "%s", c[r, i]); print s } }'
  }
fi
if ! _agy_native || ! readlink -f / >/dev/null 2>&1; then
  readlink() {  # readlink -f <path> qua perl; dạng khác chuyển cho readlink gốc
    if [[ ${1:-} == -f ]]; then _agy_perl -MCwd=abs_path -e 'my $p = abs_path($ARGV[0]); defined $p or exit 1; print "$p\n"' "$2"
    else command readlink "$@"; fi
  }
fi
