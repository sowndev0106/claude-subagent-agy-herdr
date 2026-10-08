#!/usr/bin/env bash
# agy-p: nhiều tài khoản agy song song, mỗi tài khoản là một profile (token riêng).
#
#   agy-p add [tên]            đăng nhập ẩn: in link + mã phiên, nhận mã xác thực (gõ vào, hoặc agy-p code);
#                              không đặt tên thì profile mang tên theo email (phần trước @)
#   agy-p add -i [tên]         như trên nhưng mở giao diện agy (dự phòng; xong gõ /exit)
#   agy-p code <phiên> <mã>    đưa mã xác thực vào phiên add đang chờ (khi add chạy nền)
#   agy-p ls                   các profile, email; dấu * là profile mặc định
#   agy-p usage [--tsv] [--max-age giây] [tên...]   quota còn lại (chạy /usage song song; --tsv cho script, có cache)
#   agy-p dash [--max-age giây] [--no-open]   trang HTML trực quan: quota từng account, account mặc định, account job mới sẽ dùng
#   agy-p default [tên]        xem / đổi profile mặc định (dùng khi không chỉ định profile; agy-hd ưu tiên nó)
#   agy-p pick [--load tên=n]... [--exclude tên]... [--exclude-email email]... [--min %]
#                              in tên profile nên dùng: ưu tiên mặc định, không thì profile còn nhiều quota Gemini nhất
#                              chia cho số job đang chạy trên nó; mỗi account (email) chỉ tính một lần
#   agy-p email <tên>          in email của profile (rỗng nếu chưa đăng nhập)
#   agy-p env <tên>            in lệnh export để một shell (vd pane herdr) chạy `agy` bằng profile đó: eval "$(agy-p env x)"
#   agy-p rm [-y] <tên>        xoá profile (chỉ token, settings, log; hội thoại dùng chung nên vẫn giữ)
#   agy-p whoami               terminal này chạy agy-p bằng account nào, `agy` trần ở đây dùng account nào, quota
#   agy-p use <tên>|--unset    đổi account cho RIÊNG terminal này: eval "$(agy-p use work)"
#   agy-p switch <tên>|--auto  đổi account mặc định (= default); --auto chọn account còn nhiều quota Gemini nhất
#   agy-p best [agy args...]   chạy agy bằng account còn nhiều quota nhất lúc này
#   agy-p rename <cũ> <mới>    đổi tên profile (cập nhật cả mặc định và job agy-hd đang trỏ tới nó)
#   agy-p relogin <tên>        đăng nhập lại vào profile đó (token hỏng/bị thu hồi); thất bại thì trả token cũ
#   agy-p doctor               kiểm tra: agy, cờ ẩn --gemini_dir, shim, từng profile, quota đọc được, agy-hd, timer
#   agy-p top [-i giây]        xem quota trực tiếp trong terminal, tự làm mới (Ctrl+C để thoát)
#   agy-p export <tên> [file]  đóng gói đăng nhập của profile (CHỨA TOKEN) ra file hoặc stdout
#   agy-p import <file|-> [tên]  nhận gói đăng nhập (vd từ máy khác); trùng account thì từ chối
#   agy-p remote <ssh-host> <lệnh agy-p...>   chạy agy-p trên máy khác qua ssh (vd: remote srv add, remote srv usage)
#   agy-p remote <ssh-host> push|pull <tên>   chuyển một account sang / về từ máy đó (cần agy-p ở cả hai máy)
#                              thêm tuỳ chọn ssh bằng AGY_SSH_OPTS, vd AGY_SSH_OPTS="-p 2222"
#   agy-p completion zsh|bash  in script gợi ý lệnh: source <(agy-p completion zsh)
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
# profile email gemini_tuần gemini_5h claude_tuần claude_5h reset_gemini_tuần reset_gemini_5h reset_claude_tuần reset_claude_5h
# (% số nguyên; -1 = không đọc được, -2 = không có gói/disabled; reset "-" = không rõ)
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
        return v if v.isdigit() else ("-2" if v == "disabled" else "-1")
    print("\t".join([n, email or "-"] + [pct(k) for k in keys] + [rows.get(k, ("", "-"))[1] or "-" for k in keys]))
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
def cell(v, r=""): return f"{('?' if v == '-1' else 'không có' if v == '-2' else v + '%') + (local(r) if r and r != '-' else ''):20}"
print(f"{'PROFILE':16} {'EMAIL':32} {'GEMINI TUẦN':20} {'GEMINI 5H':20} {'CLAUDE TUẦN':12} {'CLAUDE 5H':12}")
for line in open(sys.argv[1]):
    n, e, gw, g5, cw, c5, rw, r5, *_ = line.rstrip("\n").split("\t")
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

# dash: trang HTML trực quan (mẫu scripts/dashboard.html), mở bằng trình duyệt. --fragment ghi bản không có
# <!doctype> (để đăng làm Artifact). Số job = job agy-hd đang mở (chưa DONE/STOPPED/đóng) trên từng profile.
cmd_dash() {
  local age=0 out=$ROOT/dashboard.html frag="" open=1
  while [[ $# -gt 0 ]]; do case $1 in --max-age) age=$2; shift;; --out) out=$2; shift;; --fragment) frag=$2; shift;;
    --no-open) open=0;; *) die "dash: không hiểu '$1'";; esac; shift; done
  local tsv pick jobs jd p; tsv=$(usage_tsv "$age")
  pick=$(cmd_pick --max-age 600 2>/dev/null) || pick=""
  jobs=$(for jd in "${AGY_HD_JOBS:-$HOME/.cache/agy-hd}"/a-*/meta.env; do [[ -f $jd ]] || continue
    grep -q '^CLOSED=1' "$jd" && continue; grep -qE '^TICK_STATE=(DONE|STOPPED)$' "$jd" && continue
    p=$(sed -n 's/^PROFILE=//p' "$jd" | tail -1); [[ -n $p ]] && echo "$p"; done | sort | uniq -c)
  mkdir -p "$(dirname "$out")"
  python3 - "$HERE/dashboard.html" "$out" "$frag" "$(default_profile)" "$pick" "$tsv" "$jobs" <<'EOF'
import sys, json, datetime
tpl, out, frag, default, pick, tsv, jobs = sys.argv[1:8]
load = {}
for line in jobs.splitlines():
    c, n = line.split(); load[n] = int(c)
keys = ["gemini_week", "gemini_5h", "claude_week", "claude_5h"]
by_email, unlogged = {}, []
for line in tsv.splitlines():
    f = line.split("\t") + ["-"] * 10
    n, e = f[0], f[1]
    if e == "-": unlogged.append(n); continue
    a = by_email.setdefault(e, {"email": e, "profiles": [], "jobs": 0, "limits": {}})
    a["profiles"].append(n); a["jobs"] += load.get(n, 0)
    if not a["limits"]:
        for i, k in enumerate(keys):
            r = f[6 + i]
            a["limits"][k] = {"pct": int(f[2 + i]) if f[2 + i].lstrip("-").isdigit() else -1, "reset": None if r in ("-", "") else r}
rank = lambda a: (default not in a["profiles"], "main" not in a["profiles"], a["email"])
data = {"generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "default": default, "pick": pick or None, "accounts": sorted(by_email.values(), key=rank), "unlogged": unlogged}
blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
t = open(tpl, encoding="utf-8").read()
a, b = t.index("/*DATA*/"), t.index("/*END*/")
page = t[:a] + "/*DATA*/" + blob + t[b:]
if frag: open(frag, "w", encoding="utf-8").write(page)
open(out, "w", encoding="utf-8").write('<!doctype html>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n' + page)
EOF
  echo "Dashboard: $out"
  (( open )) && { xdg-open "$out" >/dev/null 2>&1 & disown 2>/dev/null; } || true
}

keyring_email() {  # account mà `agy` trần dùng ở terminal không có biến SSH (gnome-keyring)
  python3 -c '
import json, base64, secretstorage
it = next(secretstorage.get_default_collection(secretstorage.dbus_init()).search_items({"service": "gemini", "username": "antigravity"}))
p = json.loads(it.get_secret().decode())["id_token"].split(".")[1]
print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["email"])' 2>/dev/null || echo "? (không đọc được keyring)"
}
in_use() {  # có tiến trình agy nào đang chạy bằng profile $1 không
  local p d; d=$(dir "$1")
  # không dùng `tr | grep -q`: với pipefail, grep thoát sớm làm tr dính SIGPIPE và cả pipeline báo sai
  for p in $(pgrep -x agy); do grep -qxF -- "--gemini_dir=$d" < <(tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null) && return 0; done; return 1
}

hd_loads() {  # "--load <profile>=<n>" cho từng profile có job agy-hd đang mở (chưa DONE/STOPPED/đóng)
  local m p
  for m in "${AGY_HD_JOBS:-$HOME/.cache/agy-hd}"/a-*/meta.env; do [[ -f $m ]] || continue
    grep -q '^CLOSED=1' "$m" && continue; grep -qE '^TICK_STATE=(DONE|STOPPED)$' "$m" && continue
    p=$(sed -n 's/^PROFILE=//p' "$m" | tail -1); [[ -n $p ]] && echo "$p"
  done | sort | uniq -c | while read -r n p; do printf -- '--load\n%s=%s\n' "$p" "$n"; done
}

cmd_whoami() {
  local p src; p=$(default_profile)
  if [[ -n ${AGY_PROFILE:-} ]]; then src="biến AGY_PROFILE của terminal này"
  elif [[ -f $ROOT/.default ]]; then src="account mặc định (agy-p default)"; else src="main, vì chưa đặt mặc định"; fi
  echo "agy-p ở terminal này   : $p ($(email "$p"))   ← $src"
  [[ -n ${AGY_PROFILE_ACTIVE:-} ]] && echo "đang ở trong agy của   : $AGY_PROFILE_ACTIVE ($(email "$AGY_PROFILE_ACTIVE"))"
  usage_tsv 300 | awk -F'\t' -v p="$p" '$1==p { printf "quota (cache ≤ 5 phút) : Gemini tuần %s%%, 5 giờ %s%% · Claude tuần %s%%\n", $3, $4, $5 }'
  if [[ -n ${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-} ]]; then echo "agy trần ở terminal này: ~/.gemini (file token) → $(email main)"
  else echo "agy trần ở terminal này: gnome-keyring → $(keyring_email)   (khác main nếu bạn từng đăng nhập ở terminal local)"; fi
}

cmd_use() {  # in lệnh để shell gọi eval; chạy trần thì nhắc cách dùng
  if [[ ${1:-} == --unset ]]; then echo "unset AGY_PROFILE"; else need_login "${1:-}"; echo "export AGY_PROFILE=$1"; fi
  [[ -t 1 ]] && echo "# lệnh trên chưa áp: chạy  eval \"\$(agy-p use ${1:-<tên>})\"  để đổi account cho terminal này" >&2
  return 0
}

cmd_switch() {
  if [[ ${1:-} == --auto ]]; then
    local p a; mapfile -t a < <(hd_loads)
    p=$(DEFAULT_MIN=101 cmd_pick --max-age 0 "${a[@]}") || die "không còn account nào có quota Gemini >= ${MIN_QUOTA}%"
    cmd_default "$p"
  else cmd_default "$@"; fi
}

cmd_best() {  # bỏ qua ưu tiên mặc định: account có quota Gemini / (1 + job agy-hd đang mở) cao nhất
  local p a; mapfile -t a < <(hd_loads); p=$(DEFAULT_MIN=101 cmd_pick "${a[@]}") || exit 2
  echo "agy-p best → $p ($(email "$p"))" >&2
  need_login "$p"; prepare "$p"; run_in "$p" "$@"
}

cmd_rename() {
  local a=${1:-} b=${2:-} m; valid "$a"; valid "$b"
  [[ $a != main && $b != main ]] || die "không đổi tên 'main' (~/.gemini)"
  [[ -d $(dir "$a") ]] || die "không có profile '$a'"; [[ ! -e $(dir "$b") ]] || die "đã có profile '$b'"
  in_use "$a" && die "đang có agy chạy bằng '$a': tắt/park các phiên đó rồi đổi tên"
  mv -- "$(dir "$a")" "$(dir "$b")"
  [[ -f $ROOT/.default && $(<"$ROOT/.default") == "$a" ]] && printf '%s\n' "$b" >"$ROOT/.default"
  for m in "${AGY_HD_JOBS:-$HOME/.cache/agy-hd}"/*/meta.env "${AGY_JOBS:-$HOME/.cache/agy-jobs}"/*/meta.env; do
    [[ -f $m ]] && grep -qx "PROFILE=$a" "$m" && sed -i "s/^PROFILE=$a\$/PROFILE=$b/" "$m"
  done
  rm -f "$CACHE"; echo "Đã đổi tên profile '$a' → '$b'"
}

cmd_relogin() {
  local p=${1:-} t bak old; valid "$p"; [[ $p != main ]] || die "'main' là ~/.gemini: đăng nhập lại bằng agy thường"
  [[ -d $(dir "$p") ]] || die "không có profile '$p' (tạo mới: agy-p add)"
  in_use "$p" && die "đang có agy chạy bằng '$p': tắt các phiên đó trước"
  t=$(token "$p"); bak=$t.bak-$$; old=$(email "$p")
  [[ -f $t ]] && mv -- "$t" "$bak"
  if ( cmd_add "$p" ); then
    rm -f -- "$bak"; local e; e=$(email "$p")
    [[ -z $old || $e == "$old" ]] || echo "Lưu ý: profile '$p' trước là $old, giờ là $e"
  else
    [[ -f $bak ]] && mv -- "$bak" "$t"; die "đăng nhập lại không xong: đã trả token cũ cho '$p'"
  fi
}

cmd_doctor() {
  local bad=0 warn=0 p e t T v
  ok()   { echo "  ✓ $*"; }
  no()   { echo "  ✗ $*"; bad=$((bad+1)); }
  hmm()  { echo "  ! $*"; warn=$((warn+1)); }
  echo "agy"
  v=$("$REAL" --version 2>/dev/null | head -1); [[ -n $v ]] && ok "agy $v ($REAL)" || no "không chạy được $REAL --version"
  T=$(mktemp -d)
  v=$(SSH_CONNECTION=agy-doctor timeout 40 "$REAL" --gemini_dir="$T" models </dev/null 2>&1 || true)   # lấy hết output trước (pipefail + grep -q)
  if grep -qi 'sign in' <<<"$v"; then ok "cờ ẩn --gemini_dir còn tác dụng (thư mục mới → chưa đăng nhập)"
  else no "cờ ẩn --gemini_dir không còn tác dụng (agy đổi sau khi update?): các profile có thể dùng chung một account"; fi
  rm -rf "$T"
  [[ -x $SHIM/agy ]] && ok "shim: $SHIM/agy" || no "thiếu shim $SHIM/agy"
  echo "profile (mặc định: $(default_profile))"
  local -A seen=()
  for p in $(profiles); do
    e=$(email "$p"); t=$(token "$p")
    if [[ -z $e ]]; then hmm "$p: chưa đăng nhập (agy-p relogin $p, hoặc agy-p rm $p)"; continue; fi
    [[ $(stat -c %a "$t") == 600 ]] || hmm "$p: quyền file token là $(stat -c %a "$t"), nên là 600"
    if [[ $p != main ]]; then
      [[ -L $(dir "$p")/config ]] || hmm "$p: config/ không phải symlink tới ~/.gemini/config"
      grep -qs AGENT_ONBOARDING_STATE_COMPLETED "$(dir "$p")/antigravity-cli/jetski_state.pbtxt" || hmm "$p: thiếu cờ đã setup (chạy agy-p $p một lần để chép)"
    fi
    if [[ -n ${seen[$e]:-} ]]; then hmm "$p: cùng account $e với '${seen[$e]}' (không thêm quota)"; else seen[$e]=$p; fi
    ok "$p: $e"
  done
  echo "quota (lấy mới)"
  while IFS=$'\t' read -r p e gw g5 _; do
    [[ $e == - ]] && continue
    if [[ $gw == -1 || $g5 == -1 ]]; then no "$p: không đọc được quota (token hỏng/bị thu hồi? agy-p relogin $p)"
    elif (( gw < MIN_QUOTA || g5 < MIN_QUOTA )); then hmm "$p: Gemini tuần $gw%, 5 giờ $g5% (dưới ${MIN_QUOTA}%, không được tự chọn)"
    else ok "$p: Gemini tuần $gw%, 5 giờ $g5%"; fi
  done < <(usage_tsv 0)
  echo "agy-hd"
  local hd; hd=$(command -v agy-hd 2>/dev/null)
  if [[ -z $hd ]]; then hmm "không có agy-hd trong PATH (skill agy-subagent)"
  else grep -q 'agy-p' "$(readlink -f "$hd")" && ok "agy-hd biết dùng agy-p (-u, tự chọn, đổi account khi hết quota)" || no "agy-hd chưa tích hợp agy-p"
    systemctl --user is-active agy-hd-tick.timer >/dev/null 2>&1 && ok "timer agy-hd-tick đang chạy (kiểm job mỗi phút)" || hmm "timer agy-hd-tick không chạy: systemctl --user enable --now agy-hd-tick.timer"
    herdr session list 2>/dev/null | awk '$1=="cas" && $2=="running"{f=1} END{exit !f}' && ok "herdr session cas đang chạy" || hmm "herdr session cas chưa chạy (agy-hd init)"
  fi
  echo "---"; echo "$bad lỗi, $warn cảnh báo"; (( bad == 0 ))
}

cmd_top() {
  local every=60; [[ ${1:-} == -i ]] && every=${2:-60}
  trap 'tput cnorm 2>/dev/null; echo; exit 0' INT TERM; tput civis 2>/dev/null || true
  while :; do
    local tsv; tsv=$(usage_tsv "$every")
    clear
    python3 - "$(default_profile)" "$every" "$tsv" <<'EOF'
import sys, datetime
default, every, tsv = sys.argv[1], sys.argv[2], sys.argv[3]
C = {"g": "\033[32m", "y": "\033[33m", "o": "\033[38;5;209m", "r": "\033[31m", "d": "\033[2m", "b": "\033[1m", "0": "\033[0m"}
def col(p): return C["g"] if p >= 50 else C["y"] if p >= 20 else C["o"] if p >= 5 else C["r"]
def bar(p, w=24):
    if p < 0: return C["d"] + "·" * w + C["0"] + ("  không có" if p == -2 else "  ?")
    n = round(p * w / 100); return col(p) + "█" * n + C["d"] + "░" * (w - n) + C["0"] + f" {p:3d}%"
def left(ts):
    try: s = (datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")) - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
    except ValueError: return ""
    if s <= 0: return "đã hồi"
    d, h, m = int(s // 86400), int(s % 86400 // 3600), int(s % 3600 // 60)
    return f"hồi sau {d}n{h}g" if d else f"hồi sau {h}g{m:02d}p"
now = datetime.datetime.now().strftime("%H:%M:%S")
print(f"{C['b']}Quota agy{C['0']}  {C['d']}{now} · làm mới mỗi {every}s · Ctrl+C để thoát{C['0']}\n")
seen = {}
for line in tsv.splitlines():
    f = (line.split("\t") + ["-"] * 10)[:10]
    n, e = f[0], f[1]
    if e == "-": continue
    if e in seen: seen[e].append(n); continue
    seen[e] = [n]
    g = [int(x) if x.lstrip("-").isdigit() else -1 for x in f[2:6]]
    star = f" {C['b']}★ mặc định{C['0']}" if n == default else ""
    print(f"{C['b']}{e}{C['0']}  {C['d']}{n}{C['0']}{star}")
    print(f"  Gemini tuần {bar(g[0])}  {C['d']}{left(f[6])}{C['0']}")
    print(f"  Gemini 5 giờ {bar(g[1])}  {C['d']}{left(f[7])}{C['0']}")
    print(f"  Claude tuần {bar(g[2])}  {C['d']}{left(f[8])}{C['0']}\n")
EOF
    sleep "$every"
  done
}

cmd_export() {
  local p=${1:-} out=${2:--} tmp; need_login "$p"
  tmp=$(mktemp -d); chmod 700 "$tmp"; mkdir -p "$tmp/agy-p-profile"
  printf 'name=%s\nemail=%s\n' "$p" "$(email "$p")" >"$tmp/agy-p-profile/manifest"
  cp -p "$(token "$p")" "$tmp/agy-p-profile/antigravity-oauth-token"
  [[ -f $(dir "$p")/antigravity-cli/settings.json ]] && cp "$(dir "$p")/antigravity-cli/settings.json" "$tmp/agy-p-profile/"
  if [[ $out == - ]]; then tar -C "$tmp" -czf - agy-p-profile
  else (umask 077; tar -C "$tmp" -czf "$out" agy-p-profile); echo "Đã xuất '$p' ra $out (CHỨA TOKEN đăng nhập: giữ kín, xoá sau khi import)" >&2; fi
  rm -rf "$tmp"
}

cmd_import() {
  local src=${1:--} want=${2:-} tmp e name q
  tmp=$(mktemp -d); chmod 700 "$tmp"
  if [[ $src == - ]]; then tar -C "$tmp" -xzf -; else tar -C "$tmp" -xzf "$src"; fi
  [[ -f $tmp/agy-p-profile/antigravity-oauth-token ]] || { rm -rf "$tmp"; die "không phải gói của agy-p export"; }
  e=$(python3 -c '
import json, base64, sys
p = json.load(open(sys.argv[1]))["id_token"].split(".")[1]
print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["email"])' "$tmp/agy-p-profile/antigravity-oauth-token" 2>/dev/null) \
    || { rm -rf "$tmp"; die "token trong gói không đọc được"; }
  for q in $(profiles); do [[ $(email "$q") == "$e" ]] && { rm -rf "$tmp"; die "$e đã có ở profile '$q' trên máy này"; }; done
  name=${want:-$(printf '%s' "${e%@*}" | tr -c 'A-Za-z0-9._-' '-')}; valid "$name"
  [[ ! -e $(dir "$name") ]] || { rm -rf "$tmp"; die "đã có profile '$name' (đặt tên khác: agy-p import <file> <tên>)"; }
  mkdir -p "$(dir "$name")/antigravity-cli"
  install -m 600 "$tmp/agy-p-profile/antigravity-oauth-token" "$(token "$name")"
  [[ -f $tmp/agy-p-profile/settings.json ]] && cp "$tmp/agy-p-profile/settings.json" "$(dir "$name")/antigravity-cli/"
  rm -rf "$tmp"; prepare "$name"; rm -f "$CACHE"
  echo "Đã nhập profile '$name': $e"
}

cmd_remote() {
  local host=${1:-} sub=${2:-}; [[ -n $host && -n $sub ]] || die "dùng: agy-p remote <ssh-host> <lệnh agy-p...> | push|pull <tên>"
  shift 2
  local rp='PATH="$HOME/.local/bin:$PATH" agy-p' tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)
  case $sub in
    push) cmd_export "${1:?tên profile}" | ssh ${AGY_SSH_OPTS:-} "$host" "$rp import - ${2:-}" ;;
    pull) ssh ${AGY_SSH_OPTS:-} "$host" "$rp export ${1:?tên profile}" | cmd_import - "${2:-}" ;;
    *)    ssh "${tty[@]}" ${AGY_SSH_OPTS:-} "$host" "$rp $sub $(printf '%q ' "$@")" ;;
  esac
}

cmd_completion() {
  local subs="add code ls usage dash default switch use whoami best pick env email rename relogin rm doctor top export import remote completion"
  [[ ${1:-} == zsh ]] && echo 'autoload -U +X bashcompinit 2>/dev/null && bashcompinit'
  cat <<EOF
_agy_p() {
  local cur=\${COMP_WORDS[COMP_CWORD]} profs
  profs=\$(agy-p ls 2>/dev/null | awk 'NR>1 {print \$1}')
  if (( COMP_CWORD == 1 )); then COMPREPLY=(\$(compgen -W "$subs \$profs" -- "\$cur")); return; fi
  case \${COMP_WORDS[1]} in
    default|switch|use|rename|relogin|rm|env|email|export|usage|best) COMPREPLY=(\$(compgen -W "\$profs --auto --unset" -- "\$cur")) ;;
    completion) COMPREPLY=(\$(compgen -W "zsh bash" -- "\$cur")) ;;
  esac
}
complete -F _agy_p agy-p
EOF
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
  dash)    shift; cmd_dash "$@" ;;
  whoami)  shift; cmd_whoami ;;
  use)     shift; cmd_use "$@" ;;
  switch)  shift; cmd_switch "$@" ;;
  best)    shift; cmd_best "$@" ;;
  rename)  shift; cmd_rename "$@" ;;
  relogin) shift; cmd_relogin "$@" ;;
  doctor)  shift; cmd_doctor ;;
  top)     shift; cmd_top "$@" ;;
  export)  shift; cmd_export "$@" ;;
  import)  shift; cmd_import "$@" ;;
  remote)  shift; cmd_remote "$@" ;;
  completion) shift; cmd_completion "$@" ;;
  email)   shift; valid "${1:-}"; email "$1" ;;
  rm)      shift; cmd_rm "$@" ;;
  ""|-*)   p=$(default_profile); need_login "$p"; prepare "$p"; run_in "$p" "$@" ;;
  *)       p=$1; shift; need_login "$p"; prepare "$p"; run_in "$p" "$@" ;;
esac
