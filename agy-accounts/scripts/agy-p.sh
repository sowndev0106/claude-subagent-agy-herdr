#!/usr/bin/env bash
# agy-p: nhiều tài khoản agy song song, mỗi tài khoản là một profile (token riêng).
#
#   agy-p add [tên]            đăng nhập ẩn: in link + mã phiên, nhận mã xác thực (gõ vào, hoặc agy-p code);
#                              không đặt tên thì profile mang tên theo email (phần trước @)
#   agy-p add -i [tên]         như trên nhưng mở giao diện agy (dự phòng; xong gõ /exit)
#   agy-p code <phiên> <mã>    đưa mã xác thực vào phiên add đang chờ (khi add chạy nền)
#   agy-p ls                   các profile, email; dấu * là profile mặc định
#   agy-p usage [--tsv] [--max-age giây] [tên...]   quota còn lại (chạy /usage song song; --tsv cho script, có cache)
#   agy-p default [tên]        xem / đổi profile mặc định (dùng khi không chỉ định profile; agy-hd ưu tiên nó)
#   agy-p pick [--load tên=n]... [--exclude tên]... [--exclude-email email]... [--min %]
#                              in tên profile nên dùng: ưu tiên mặc định, không thì profile còn nhiều quota Gemini nhất
#                              chia cho số job đang chạy trên nó; mỗi account (email) chỉ tính một lần
#   agy-p email <tên>          in email của profile (rỗng nếu chưa đăng nhập)
#   agy-p env <tên>            in lệnh export để một shell (vd pane herdr) chạy `agy` bằng profile đó: eval "$(agy-p env x)"
#   agy-p rm [-y] <tên>        xoá profile (chỉ token, settings, log; hội thoại dùng chung nên vẫn giữ)
#   agy-p <tên> [agy args...]  chạy agy bằng profile <tên>
#   agy-p [agy args...]        chạy bằng $AGY_PROFILE, không có thì profile mặc định
#
# Profile "main" là ~/.gemini. Profile khác ở ~/.agy-profiles/<tên> (đổi bằng AGY_PROFILES_DIR).
# Token: <profile>/antigravity-cli/antigravity-oauth-token, agy tự refresh.
# Dùng chung với ~/.gemini: config/ (skills, plugins, MCP) và hội thoại (conversations, brain, implicit,
# annotations), nên một hội thoại resume được bằng bất kỳ profile nào (--conversation <id>).
# agy được gọi lồng bên trong (lệnh shell `agy ...`) cũng chạy bằng profile đó, nhờ shim trong scripts/shim.
set -euo pipefail
ROOT=${AGY_PROFILES_DIR:-$HOME/.agy-profiles}
MAIN=$HOME/.gemini
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
SHIM=$HERE/shim
SHARED=(conversations brain implicit annotations)
CACHE=$ROOT/.usage.tsv
MIN_QUOTA=${AGY_MIN_QUOTA:-5}            # % Gemini còn lại tối thiểu để được chọn
DEFAULT_MIN=${AGY_DEFAULT_MIN:-20}       # profile mặc định được ưu tiên khi còn >= ngần này %
DEFAULT_MAXJOBS=${AGY_DEFAULT_MAXJOBS:-2} # ... và đang chạy ít hơn ngần này job

die()   { echo "agy-p: $*" >&2; exit 2; }
valid() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "tên profile không hợp lệ: '${1:-}' (chữ, số, . _ -)"; }
dir()   { if [[ $1 == main ]]; then echo "$MAIN"; else echo "$ROOT/$1"; fi; }
token() { echo "$(dir "$1")/antigravity-cli/antigravity-oauth-token"; }
profiles() {  # main trước, rồi các profile khác theo tên
  echo main
  [[ -d $ROOT ]] && find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort
  return 0
}
email() {  # email trong id_token của profile, rỗng nếu chưa đăng nhập
  [[ -f $(token "$1") ]] || return 0
  python3 -c '
import json, base64, sys
p = json.load(open(sys.argv[1]))["id_token"].split(".")[1]
print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("email", ""))' "$(token "$1")" 2>/dev/null || true
}
default_profile() {  # $AGY_PROFILE, không có thì ~/.agy-profiles/.default, không có thì main
  local p=${AGY_PROFILE:-}
  [[ -n $p ]] || { [[ -f $ROOT/.default ]] && p=$(<"$ROOT/.default"); }
  [[ -n $p && -n $(email "$p" 2>/dev/null) ]] || p=main
  echo "$p"
}
need_login() { valid "$1"; [[ -n $(email "$1") ]] || die "profile '$1' chưa có hoặc chưa đăng nhập. Tạo: agy-p add"; }

# agy thật (bỏ qua shim nếu agy-p đang chạy lồng bên trong một profile)
REAL=${AGY_REAL:-}
if [[ -z $REAL ]]; then
  for c in $(type -ap agy); do [[ $(readlink -f "$c") != "$(readlink -f "$SHIM/agy")" ]] && { REAL=$c; break; }; done
fi
[[ -n $REAL ]] || die "không tìm thấy agy trong PATH"

env_for() {  # môi trường cho agy chạy bằng profile $1
  # agy chỉ lưu token ra file khi thấy biến SSH; thiếu dòng này thì ở terminal local mọi profile dùng chung một mục gnome-keyring
  export SSH_CONNECTION=${SSH_CONNECTION:-agy-profile}
  export AGY_REAL=$REAL AGY_GEMINI_DIR AGY_PROFILE_ACTIVE=$1
  AGY_GEMINI_DIR=$(dir "$1")
  [[ :$PATH: == *:$SHIM:* ]] || export PATH=$SHIM:$PATH
}
agy_in() { local p=$1; shift; ( env_for "$p"; "$REAL" --gemini_dir="$AGY_GEMINI_DIR" "$@" ); }
run_in() { local p=$1; shift; env_for "$p"; exec "$REAL" --gemini_dir="$AGY_GEMINI_DIR" "$@"; }

prepare() {  # tạo thư mục profile, nối config + hội thoại dùng chung, chép settings + cờ setup lần đầu
  [[ $1 == main ]] && return 0
  local d x; d=$(dir "$1")
  mkdir -p "$d/antigravity-cli"
  [[ -e $d/config ]] || ln -s "$MAIN/config" "$d/config"
  for x in "${SHARED[@]}"; do
    mkdir -p "$MAIN/antigravity-cli/$x"
    if [[ -d $d/antigravity-cli/$x && ! -L $d/antigravity-cli/$x ]]; then  # profile cũ: dồn hội thoại riêng về kho chung
      cp -an "$d/antigravity-cli/$x/." "$MAIN/antigravity-cli/$x/" && rm -rf -- "${d:?}/antigravity-cli/$x"
    fi
    [[ -e $d/antigravity-cli/$x ]] || ln -s "$MAIN/antigravity-cli/$x" "$d/antigravity-cli/$x"
  done
  [[ -e $d/antigravity-cli/settings.json || ! -f $MAIN/antigravity-cli/settings.json ]] \
    || cp "$MAIN/antigravity-cli/settings.json" "$d/antigravity-cli/settings.json"
  seed_onboarding "$d/antigravity-cli"
}

# Màn hình setup lần đầu (theme, điều khoản...) chỉ là cờ lưu trên máy: chép cờ "đã xong" từ main sang,
# giữ installation_uuid riêng của profile. Account đã dùng Antigravity thì phía máy chủ không cần setup lại.
seed_onboarding() {
  python3 - "$MAIN/antigravity-cli" "$1" <<'EOF'
import json, os, re, sys
src, dst = sys.argv[1], sys.argv[2]
for name in ("jetski_state.pbtxt", "antigravity_state.pbtxt"):
    s, d = os.path.join(src, name), os.path.join(dst, name)
    if not os.path.exists(s): continue
    mine = open(d).read() if os.path.exists(d) else ""
    if "AGENT_ONBOARDING_STATE_COMPLETED" in mine: continue
    body = re.sub(r"(?m)^installation_uuid:.*\n?", "", open(s).read())
    uuid = re.search(r"(?m)^installation_uuid:.*$", mine)
    open(d, "w").write(body + (uuid.group(0) + "\n" if uuid else ""))
s, d = os.path.join(src, "cache", "onboarding.json"), os.path.join(dst, "cache", "onboarding.json")
if os.path.exists(s):
    try: done = json.load(open(d)).get("onboardingComplete")
    except (OSError, ValueError): done = False
    if not done:
        os.makedirs(os.path.dirname(d), exist_ok=True); open(d, "w").write(open(s).read())
EOF
}

cmd_add() {  # đăng nhập ẩn: in link, nhận mã (gõ vào, hoặc `agy-p code`), không mở giao diện agy
  local ui=0; [[ ${1:-} == -i ]] && { ui=1; shift; }
  local want=${1:-} p id e
  if [[ -n $want ]]; then  # đặt tên sẵn
    valid "$want"; [[ $want != main ]] || die "'main' là ~/.gemini, đăng nhập bằng agy thường"
    e=$(email "$want"); [[ -z $e ]] || die "profile '$want' đã đăng nhập ($e)"
    p=$want id=$want
  else                     # tên lấy theo email sau khi đăng nhập
    id=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n'); p=.login-$id
  fi
  prepare "$p"
  local d fifo res rc=0; d=$(dir "$p"); fifo=$d/.login-code; res=$ROOT/.result-$id
  rm -f "$res"
  if (( ui )); then  # dự phòng: mở giao diện agy, tự đăng nhập rồi gõ /exit
    agy_in "$p" || true
  else
    echo "Phiên đăng nhập: $id   (gửi mã: agy-p code $id <mã>)"
    rm -f "$fifo"; mkfifo -m 600 "$fifo"
    ( env_for "$p"; python3 "$HERE/login.py" --agy "$REAL" --gemini-dir "$d" --fifo "$fifo" ) || rc=$?
    rm -f "$fifo"
  fi
  e=$(email "$p")
  if [[ -z $e ]]; then
    [[ $p == .login-* ]] && rm -rf -- "$d"
    echo "FAIL chưa đăng nhập được (mã $rc)" >"$res"; die "chưa đăng nhập được (mã $rc). Chạy lại: agy-p add"
  fi
  local q name
  if [[ $p == .login-* ]]; then
    for q in $(profiles); do
      if [[ $q != main && $(email "$q") == "$e" ]]; then
        rm -rf -- "$d"; echo "FAIL $e đã có ở profile '$q'" >"$res"; die "$e đã có ở profile '$q' (bỏ lần đăng nhập này)"
      fi
    done
    name=$(printf '%s' "${e%@*}" | tr -c 'A-Za-z0-9._-' '-')
    [[ ! -e $ROOT/$name ]] || name=$name-$id
    mv -- "$d" "$ROOT/$name"; p=$name
  fi
  rm -f "$CACHE"   # quota cache không còn đủ profile
  echo "OK $p $e" >"$res"
  echo "Profile '$p' đã đăng nhập: $e"
  [[ $(email main) != "$e" ]] || echo "Lưu ý: cùng account với 'main' (~/.gemini), không thêm quota"
  return 0
}

cmd_code() {  # agy-p code <phiên|tên> <mã>: đưa mã xác thực vào phiên `agy-p add` đang chờ
  local id=${1:-} code=${2:-}
  [[ -n $id && -n $code ]] || die "dùng: agy-p code <phiên> <mã>"
  local fifo=$ROOT/.login-$id/.login-code res=$ROOT/.result-$id i
  [[ -p $fifo ]] || fifo=$ROOT/$id/.login-code
  [[ -p $fifo ]] || die "không có phiên đăng nhập '$id' nào đang chờ mã"
  printf '%s\n' "$code" >"$fifo"
  for i in $(seq 120); do
    if [[ -f $res ]]; then
      local r; r=$(<"$res"); rm -f "$res"
      [[ $r == OK* ]] || die "${r#FAIL }"
      set -- $r; echo "Profile '$2' đã đăng nhập: $3"; return 0
    fi
    sleep 1
  done
  die "đã gửi mã nhưng sau 120s chưa có kết quả; xem output của agy-p add"
}

cmd_ls() {
  local p e d; d=$(default_profile)
  printf '%-18s %s\n' PROFILE EMAIL
  for p in $(profiles); do
    e=$(email "$p")
    printf '%-18s %s\n' "$p$([[ $p == "$d" ]] && echo ' *')" "${e:-(chưa đăng nhập)}"
  done
}

cmd_default() {
  if [[ -z ${1:-} ]]; then local d; d=$(default_profile); echo "$d ($(email "$d"))"; return 0; fi
  need_login "$1"; mkdir -p "$ROOT"; printf '%s\n' "$1" >"$ROOT/.default"
  echo "Profile mặc định: $1 ($(email "$1")). Áp cho lần chạy agy-p / agy-hd job MỚI; phiên đang chạy giữ account cũ."
}

cmd_env() {
  local p=${1:-}; need_login "$p"; prepare "$p"
  printf "export SSH_CONNECTION=\"\${SSH_CONNECTION:-agy-profile}\" AGY_REAL='%s' AGY_GEMINI_DIR='%s' AGY_PROFILE_ACTIVE='%s'\n" "$REAL" "$(dir "$p")" "$p"
  printf "case \":\$PATH:\" in *':%s:'*) ;; *) export PATH='%s':\"\$PATH\" ;; esac\n" "$SHIM" "$SHIM"
}

# usage: chạy `/usage` của từng profile song song. Kết quả máy đọc (cũng là cache $CACHE), mỗi dòng:
# profile email gemini_tuần gemini_5h claude_tuần claude_5h reset_gemini_tuần reset_gemini_5h  (% số nguyên, -1 = không rõ)
fetch_usage() {  # $1=thư mục tạm, còn lại: profile
  local tmp=$1 p; shift
  for p in "$@"; do
    email "$p" >"$tmp/$p.email"
    if [[ -s $tmp/$p.email ]]; then ( agy_in "$p" -p /usage --print-timeout 60s </dev/null >"$tmp/$p.out" 2>&1 || true ) & fi
  done
  wait
  python3 - "$tmp" "$@" >"$tmp/usage.tsv" <<'EOF'
import sys, os
tmp, names = sys.argv[1], sys.argv[2:]
keys = [("Gemini Models", "Weekly Limit Remaining"), ("Gemini Models", "Five Hour Limit Remaining"),
        ("Claude and GPT models", "Weekly Limit Remaining"), ("Claude and GPT models", "Five Hour Limit Remaining")]
for n in names:
    email = open(f"{tmp}/{n}.email").read().strip()
    rows = {}
    if os.path.exists(f"{tmp}/{n}.out"):
        for line in open(f"{tmp}/{n}.out").read().splitlines():
            f = line.split("\t")
            if len(f) >= 3: rows[(f[0], f[1])] = (f[2], f[3] if len(f) > 3 else "")
    def pct(k):
        v = rows.get(k, ("", ""))[0].rstrip("%")
        return v if v.isdigit() else "-1"
    print("\t".join([n, email or "-"] + [pct(k) for k in keys] + [rows.get(keys[0], ("", "-"))[1] or "-", rows.get(keys[1], ("", "-"))[1] or "-"]))
EOF
}
usage_tsv() {  # $1=max-age giây (0 = luôn lấy mới); in TSV của mọi profile
  local age=$1 tmp
  if (( age > 0 )) && [[ -f $CACHE ]] && (( $(date +%s) - $(stat -c %Y "$CACHE") < age )); then cat "$CACHE"; return 0; fi
  tmp=$(mktemp -d); mapfile -t _ps < <(profiles)
  fetch_usage "$tmp" "${_ps[@]}"
  mkdir -p "$ROOT"; cp "$tmp/usage.tsv" "$CACHE.$$" && mv "$CACHE.$$" "$CACHE"
  cat "$tmp/usage.tsv"; rm -rf "$tmp"
}
cmd_usage() {
  local tsv=0 age=0 ps=() p
  while [[ $# -gt 0 ]]; do case $1 in --tsv) tsv=1;; --max-age) age=$2; shift;; *) ps+=("$1");; esac; shift; done
  if (( tsv )); then
    if [[ ${#ps[@]} -eq 0 ]]; then usage_tsv "$age"; else usage_tsv "$age" | awk -F'\t' -v l=" ${ps[*]} " 'index(l, " "$1" ")'; fi
    return 0
  fi
  [[ ${#ps[@]} -gt 0 ]] || mapfile -t ps < <(profiles)
  for p in "${ps[@]}"; do valid "$p"; [[ -d $(dir "$p") ]] || die "không có profile '$p'"; done
  local tmp; tmp=$(mktemp -d)
  fetch_usage "$tmp" "${ps[@]}"
  [[ ${#ps[@]} -eq $(profiles | wc -l) ]] && { mkdir -p "$ROOT"; cp "$tmp/usage.tsv" "$CACHE"; }
  python3 - "$tmp/usage.tsv" <<'EOF'
import sys, datetime
def local(ts):
    try: return " (" + datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%d/%m %H:%M") + ")"
    except ValueError: return ""
def cell(v, r=""): return f"{('?' if v == '-1' else v + '%') + (local(r) if r and r != '-' else ''):20}"
print(f"{'PROFILE':16} {'EMAIL':32} {'GEMINI TUẦN':20} {'GEMINI 5H':20} {'CLAUDE TUẦN':12} {'CLAUDE 5H':12}")
for line in open(sys.argv[1]):
    n, e, gw, g5, cw, c5, rw, r5 = line.rstrip("\n").split("\t")
    if e == "-": print(f"{n:16} (chưa đăng nhập)"); continue
    print(f"{n:16} {e:32} {cell(gw, rw)} {cell(g5, r5)} {cell(cw)[:12]} {cell(c5)[:12]}")
print("(giờ trong ngoặc = lúc quota hồi lại, giờ máy; ? = không đọc được)")
EOF
  rm -rf "$tmp"
}

cmd_pick() {
  local loads=() exp=() exe=() min=$MIN_QUOTA age=300
  while [[ $# -gt 0 ]]; do case $1 in
    --load) loads+=("$2"); shift;; --exclude) exp+=("$2"); shift;; --exclude-email) exe+=("$2"); shift;;
    --min) min=$2; shift;; --max-age) age=$2; shift;; *) die "pick: không hiểu '$1'";; esac; shift; done
  usage_tsv "$age" | python3 -c '
import sys
default, mn, dmin, dmax = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
loads, exp, exe = {}, set(), set()
for a in sys.argv[5:]:
    k, v = a.split(":", 1)
    if k == "L": n, c = v.split("=", 1); loads[n] = loads.get(n, 0) + int(c)
    elif k == "P": exp.add(v)
    elif k == "E": exe.add(v)
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
by_email = {}   # mỗi account một ứng viên: ưu tiên profile mặc định, rồi main, rồi theo tên
for n, e, gw, g5, *_ in rows:
    if e == "-" or n in exp or e in exe: continue
    q = min(int(gw), int(g5))
    if q < mn: continue
    rank = (n != default, n != "main", n)
    cur = by_email.get(e)
    if cur is None or rank < cur["rank"]: by_email[e] = {"name": n, "q": q, "rank": rank, "load": 0}
for n, e, *_ in rows:
    if e in by_email: by_email[e]["load"] += loads.get(n, 0)
cands = list(by_email.values())
if not cands: sys.exit(1)
d = next((c for c in cands if c["name"] == default), None)
if d and d["q"] >= dmin and d["load"] < dmax: print(d["name"]); sys.exit(0)
print(max(cands, key=lambda c: (c["q"] / (1 + c["load"]), c["q"]))["name"])
' "$(default_profile)" "$min" "$DEFAULT_MIN" "$DEFAULT_MAXJOBS" \
    $(for x in "${loads[@]}"; do echo "L:$x"; done) $(for x in "${exp[@]}"; do echo "P:$x"; done) $(for x in "${exe[@]}"; do echo "E:$x"; done) \
    || die "không còn profile nào có quota Gemini >= ${min}% (agy-p usage để xem)"
}

cmd_rm() {
  local yes=0; [[ ${1:-} == -y ]] && { yes=1; shift; }
  local p=${1:-}; valid "$p"
  [[ $p != main ]] || die "không xoá 'main' (~/.gemini)"
  [[ -d $(dir "$p") ]] || die "không có profile '$p'"
  if (( ! yes )); then
    local e ans; e=$(email "$p")
    read -r -p "Xoá profile '$p' (${e:-chưa đăng nhập})? Gõ lại tên để xác nhận: " ans
    [[ $ans == "$p" ]] || die "đã huỷ"
  fi
  rm -rf -- "$(dir "$p")"   # config/ và hội thoại là symlink: chỉ xoá link, dữ liệu trong ~/.gemini vẫn nguyên
  [[ -f $ROOT/.default && $(<"$ROOT/.default") == "$p" ]] && rm -f "$ROOT/.default"
  rm -f "$CACHE"
  echo "Đã xoá profile '$p'"
}

case ${1:-} in
  add)     shift; cmd_add "$@" ;;
  code)    shift; cmd_code "$@" ;;
  ls)      shift; cmd_ls ;;
  usage)   shift; cmd_usage "$@" ;;
  default) shift; cmd_default "$@" ;;
  pick)    shift; cmd_pick "$@" ;;
  env)     shift; cmd_env "$@" ;;
  email)   shift; valid "${1:-}"; email "$1" ;;
  rm)      shift; cmd_rm "$@" ;;
  ""|-*)   p=$(default_profile); need_login "$p"; prepare "$p"; run_in "$p" "$@" ;;
  *)       p=$1; shift; need_login "$p"; prepare "$p"; run_in "$p" "$@" ;;
esac
