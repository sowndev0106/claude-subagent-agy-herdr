#!/usr/bin/env bash
# agy-hd: chạy agy (Gemini 3.8 Flash High, luôn bypass-permissions) làm subagent TRONG herdr.
# Mỗi task = 1 workspace herdr riêng (+ tuỳ chọn git worktree riêng) => không đụng nhau,
# bạn mở herdr là thấy agy làm việc, attach vào được, xem log trực tiếp.
#
#   agy-hd ps [-w] [-a]      BẢNG TỔNG HỢP workspace + agent + job (★ = của agy-hd); -w tự làm mới; -a mọi session
#   agy-hd init              tạo sẵn session dùng chung (mặc định "cas") để attach ngay
#   agy-hd rename-space "tên"  đổi tên nhiệm vụ + nhãn workspace của phiên Claude này ("#<số> <tên>", số do agy-id cấp)
#   agy-hd sessions          các session herdr + số workspace;  agy-hd session-stop <tên>  (chỉ session do agy-hd tạo)
#   agy-hd open <job|wX>     vào xem trực tiếp agent của job (attach) hoặc nhảy tới workspace
#   agy-hd start -n tên [-d dir] [-u profile] [-W [-C]] [-R] [-A] [-t giây] (-f prompt.md | -p "text")
#       -u profile agy-p chạy job (account riêng). Không có -u: agy-p pick tự chọn (ưu tiên profile mặc định,
#          không thì account còn nhiều quota nhất, chia đều theo số job đang mở). Hết quota giữa chừng: tick
#          tự chuyển job sang account khác và resume đúng conversation đó (hội thoại dùng chung mọi profile).
#       -W worktree riêng (branch agy/<id>)   -C mang theo thay đổi chưa commit (cần -W)
#       -R chỉ đọc (lời dặn trong prompt)     -A async: không chờ xong, in ACCESS rồi thoát
#       -P park sau khi DONE (nhả RAM agy). fan mặc định park; fan -K để giữ agent sống
#       -t timeout chờ (mặc định 900)
#       MÔ HÌNH: 1 session herdr dùng chung ("cas", đổi bằng AGY_HD_SESSION hoặc -S); trong đó mỗi phiên Claude Code
#       = 1 workspace (nhãn "#<số 3 chữ số> <tên nhiệm vụ>" từ agy-id), mỗi subagent = 1 TAB (nhãn tab = id job). Chưa có thì tự tạo. KHÔNG tự dùng "default".
#       Bạn vào xem: herdr --session cas
#   agy-hd prompt <job> (-f file | "text") [-A] [-t giây]   gửi prompt tiếp vào CÙNG agent (nhớ ngữ cảnh)
#   agy-hd status <job>      trạng thái herdr (idle/working/blocked/done/gone) + màn hình cuối
#   agy-hd wait <job> [giây] chờ agent xong lượt hiện tại
#   agy-hd watch [-i 60] [-t 3600] <job>...  KIỂM MỖI PHÚT, thoát ngay khi DONE / BLOCKED / GONE / STALL (treo).
#       Luôn chạy nền sau start -A / fan để phiên Claude được báo khi agy xong hoặc treo giữa chừng
#   agy-hd logs <job> [n=80] [--transcript]   màn hình live, hoặc transcript đầy đủ của agy
#   agy-hd result <job>      câu trả lời cuối của agy (từ transcript)
#   agy-hd summary <job>     result + diffstat worktree
#   agy-hd access <job>      in lại đường dẫn truy cập (attach, workspace, transcript)
#   agy-hd interrupt <job>   huỷ lượt đang chạy (Ctrl+C; lần 2 nếu còn working): lệnh con bị dọn, workspace giữ lại
#   agy-hd park <job>        thoát agy đang idle để NHẢ RAM (~280 MB), giữ workspace + log; resume để mở lại
#   agy-hd resume <job>      mở lại agy trong cùng pane, tiếp hội thoại cũ
#   agy-hd restart <job> ["prompt"]  HẾT HẠN MỨC (quota): tắt agy của job rồi mở lại cùng hội thoại + prompt "làm tiếp"
#   agy-hd tick [--show]     SCHEDULER: một lượt kiểm MỌI job đang mở (RUNNING/DONE/QUOTA/STOPPED/STALL/BLOCKED), ghi
#                            STATUS.tsv + events.log, tự restart job hết hạn mức. systemd timer agy-hd-tick chạy mỗi phút
#   agy-hd close <job>       đóng workspace (kill mọi thứ trong đó)
#   agy-hd list              các job + trạng thái
#   agy-hd wt-diff|wt-merge|wt-drop <job>   quản lý worktree của job -W
#   agy-hd gc [ngày=3] [-y]  đóng workspace + xóa job cũ đã xong, không có thay đổi chưa merge
#   agy-hd fan -i tasks_dir -o results_dir [-j 3] [-d dir] [-u profile] [-W [-C]] [-R] [-t giây]   nhiều task song song (<=4)
#
# Chọn session herdr bằng HERDR_SESSION (mặc định: session "default" đang chạy). Phiên Claude Code
# KHÔNG cần chạy trong herdr. Registry: $AGY_HD_JOBS (mặc định ~/.cache/agy-hd). <job> = id hoặc tiền tố.
set -uo pipefail
MODEL="gemini-3.8-flash-high"
JOBS="${AGY_HD_JOBS:-$HOME/.cache/agy-hd}"
BRAIN="$HOME/.gemini/antigravity-cli/brain"
STALL="${AGY_STALL_SEC:-180}"
CMD_STALL="${AGY_CMD_STALL_SEC:-900}"   # một lệnh agy chạy (test, build) lâu hơn ngần này coi như treo
AUTOCLOSE_MIN="${AGY_AUTOCLOSE_MIN:-15}"  # tick đóng tab của job đã DONE quá ngần này phút (0 = không tự đóng)
SELF=$(readlink -f "$0")
mkdir -p "$JOBS"

die()  { echo "agy-hd: $*" >&2; exit 2; }
need() {
  command -v herdr >/dev/null || die "không thấy herdr trong PATH"
  herdr workspace list >/dev/null 2>&1 \
    || die "herdr server không chạy (session ${HERDR_SESSION:-default}). Mở herdr, hoặc dùng -S <tên> để agy-hd tự dựng session riêng"
}
meta()    { sed -n "s/^$2=//p" "$1/meta.env" 2>/dev/null | head -1; }
setmeta() { sed -i "/^$2=/d" "$1/meta.env"; printf '%s=%s\n' "$2" "$3" >>"$1/meta.env"; }
resolve() {
  local m; m=$(ls -1dt "$JOBS/$1"* 2>/dev/null | head -1)
  [[ -n $m ]] || m=$(ls -1dt "$JOBS"/*"$1"* 2>/dev/null | head -1)
  [[ -n $m ]] || die "không thấy job '$1' (agy-hd list)"; echo "$m"
}
AGY_ID_BIN="$(command -v agy-id 2>/dev/null || echo "$(dirname "$SELF")/../../claude-task-id/scripts/agy-id.sh")"
SHARED_SESSION_DEFAULT="cas"
shared_session() {  # MỘT session herdr dùng chung cho mọi subagent của mọi phiên Claude Code. KHÔNG BAO GIỜ tự dùng "default".
  if [[ -n ${AGY_HD_SESSION:-} ]]; then echo "$AGY_HD_SESSION"; return; fi
  if [[ -n ${HERDR_SESSION:-} && $HERDR_SESSION != default ]]; then echo "$HERDR_SESSION"; return; fi
  echo "$SHARED_SESSION_DEFAULT"
}
cc_key() { local id=${CLAUDE_CODE_SESSION_ID:-}; if [[ -n $id ]]; then echo "${id:0:8}"; else echo manual; fi; }   # 1 phiên Claude Code = 1 workspace

# Đặt 1 TAB mới cho subagent trong workspace của phiên Claude này (tạo workspace nếu chưa có). Mỗi subagent = 1 tab, nhãn tab = id job.
# Chạy trong flock để nhiều job song song của cùng phiên không tạo trùng workspace. Kết quả: PL_WS PL_TAB PL_PANE.
place_pane() {  # $1=workdir  $2=tên tab (id job)
  local dir=$1 name=$2 key ccf ws="" lbl json topic num
  key=$(cc_key); mkdir -p "$JOBS/.cc"; ccf="$JOBS/.cc/$key@${HERDR_SESSION:-default}"
  exec 9>"$JOBS/.cc/.lock"; flock 9
  [[ -f $ccf ]] && ws=$(sed -n 's/^WS=//p' "$ccf" | head -1)
  if [[ -n $ws ]]; then   # workspace còn sống và vẫn mang số của phiên này?
    lbl=$(herdr workspace get "$ws" 2>/dev/null | jq -r '.result.workspace.label // empty')
    num=$("$AGY_ID_BIN" num); [[ -n $num && $lbl == "#$num"* ]] || ws=""
  fi
  if [[ -z $ws ]]; then
    topic=${AGY_HD_TOPIC:-$(basename "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")")}
    json=$(herdr workspace create --cwd "$dir" --label "$("$AGY_ID_BIN" label "$topic")" --no-focus 2>&1) || { flock -u 9; die "tạo workspace thất bại: $json"; }
    PL_WS=$(jq -r '.result.workspace.workspace_id' <<<"$json"); PL_TAB=$(jq -r '.result.tab.tab_id' <<<"$json"); PL_PANE=$(jq -r '.result.root_pane.pane_id' <<<"$json")
    printf 'WS=%s\n' "$PL_WS" >"$ccf"; herdr tab rename "$PL_TAB" "$name" >/dev/null 2>&1   # tab đầu của workspace mới = subagent đầu tiên
  else
    PL_WS=$ws
    json=$(herdr tab create --workspace "$ws" --cwd "$dir" --label "$name" --no-focus 2>&1) || { flock -u 9; die "tạo tab thất bại: $json"; }
    PL_TAB=$(jq -r '.result.tab.tab_id' <<<"$json"); PL_PANE=$(jq -r '.result.root_pane.pane_id' <<<"$json")
  fi
  herdr pane rename "$PL_PANE" "$name" >/dev/null 2>&1
  flock -u 9
}
close_ui() {  # đóng tab của job (đóng tab cuối thì herdr đóng luôn workspace; lần chạy sau tự tạo lại)
  local t p; t=$(meta "$1" TAB); p=$(meta "$1" PANE)
  if [[ -n $t ]]; then herdr tab close "$t" >/dev/null 2>&1; else herdr pane close "$p" >/dev/null 2>&1; fi
  setmeta "$1" CLOSED 1   # tick không theo dõi job đã đóng nữa
}
session_running() { herdr session list 2>/dev/null | awk -v n="$1" '$1==n && $2=="running"{f=1} END{exit !f}'; }
# Một shell nằm trong pane herdr mang sẵn HERDR_SOCKET_PATH của session chứa pane đó, và herdr ưu tiên biến này
# hơn HERDR_SESSION. Gọi agy-hd từ shell như vậy (vd một phiên Claude Code chạy trong herdr) thì mọi lệnh herdr
# rơi vào session của pane (thường là "default") dù -S hay session dùng chung nói gì (gặp 2026-10-05). Cứ khi đã
# chọn một session khác default thì bỏ biến đó đi để HERDR_SESSION quyết định.
herdr() {
  if [[ -n ${HERDR_SESSION:-} && $HERDR_SESSION != default ]]; then env -u HERDR_SOCKET_PATH herdr "$@"
  else command herdr "$@"; fi
}
# Lệnh in cho người dùng: dạng cờ chạy đúng cả trong shell có HERDR_SOCKET_PATH, dạng HERDR_SESSION=... thì không.
hcli() { if [[ -n ${HERDR_SESSION:-} && $HERDR_SESSION != default ]]; then echo "herdr --session $HERDR_SESSION"; else echo herdr; fi; }
# agy chạy lệnh nền (công cụ run-command của nó) rồi kết thúc lượt ("launched ... as a background task and am
# waiting"): herdr báo idle, await_done tưởng DONE và park bắn ctrl+c vào agent vừa chạy tiếp (gặp 2026-10-05,
# job a-code-5801). Job còn BẬN khi tiến trình agy của nó còn một tiến trình con không phải MCP server (các MCP
# server sống suốt phiên agy, không phải việc đang làm).
agy_pids() { local d p; d=$(meta "$1" WORKTREE); [[ -n $d ]] || d=$(meta "$1" WORKDIR); d=${d%/}; [[ -n $d ]] || return 0
  for p in $(pgrep -x agy); do [[ $(readlink "/proc/$p/cwd" 2>/dev/null) == "$d" ]] && echo "$p"; done; }
busy() { local p c; subagent_busy "$(basename "$1")" && return 0; for p in $(agy_pids "$1"); do for c in $(pgrep -P "$p"); do
  tr '\0' ' ' <"/proc/$c/cmdline" 2>/dev/null | grep -qi mcp || return 0; done; done; return 1; }
ensure_session() {  # tạo (nếu chưa có) session herdr riêng, headless, sống sau khi lệnh kết thúc
  local n=$1 i; [[ -z $n || $n == default ]] && return 0
  [[ $n =~ ^[A-Za-z0-9_-]{1,40}$ ]] || die "tên session chỉ gồm chữ/số/_/-: $n"
  session_running "$n" && return 0
  mkdir -p "$JOBS/.sessions"
  # Server local (không dùng mạng); tách phiên để sống sau lệnh gọi. Dừng bằng: agy-hd session-stop <tên>
  setsid env -u HERDR_SOCKET_PATH herdr --session "$n" server >"$JOBS/.sessions/$n.log" 2>&1 </dev/null &
  disown 2>/dev/null
  for i in $(seq 40); do HERDR_SESSION=$n herdr workspace list >/dev/null 2>&1 && return 0; sleep 0.5; done
  die "không dựng được session herdr '$n' (xem $JOBS/.sessions/$n.log)"
}
use_session() { local s; s=$(meta "$1" SESSION); if [[ -z $s || $s == default ]]; then unset HERDR_SESSION; else export HERDR_SESSION=$s; fi; }
astate()  { herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null || echo gone; }
ago() { local s=$(( $(date +%s) - $1 )); printf '%dm%02ds' $((s/60)) $((s%60)); }

# ── nhiều account (agy-p, skill agy-accounts): mỗi job chạy bằng một profile (PROFILE trong meta.env).
# Pane được nạp môi trường của profile (eval "$(agy-p env <p>)": token riêng + shim để agy lồng bên trong cùng account)
# trước khi `herdr agent start` gõ `agy ...` vào shell của pane. Không có agy-p thì chạy như cũ (~/.gemini).
AGYP=$(command -v agy-p 2>/dev/null || echo "$HOME/.local/bin/agy-p")
have_profiles() { [[ -x $AGYP ]]; }
job_loads() {  # in các cặp "--load <profile>=<số job đang mở>" cho agy-p pick
  local jd p; declare -A c=()
  for jd in "$JOBS"/a-*/; do jd=${jd%/}; [[ -f $jd/meta.env ]] || continue
    [[ $(meta "$jd" CLOSED) == 1 ]] && continue
    case $(meta "$jd" TICK_STATE) in DONE|STOPPED) continue;; esac
    p=$(meta "$jd" PROFILE); [[ -n $p ]] && c[$p]=$(( ${c[$p]:-0} + 1 ))
  done
  for p in "${!c[@]}"; do printf -- '--load\n%s=%s\n' "$p" "${c[$p]}"; done
}
pick_profile() { local a; mapfile -t a < <(job_loads); "$AGYP" pick "${a[@]}" "$@"; }   # $@: thêm --exclude-email ...
profile_env_in_pane() { herdr pane run "$1" "eval \"\$($AGYP env $2)\" && clear" >/dev/null; sleep 1; }   # $1=pane $2=profile
acct_of() { local p; p=$(meta "$1" PROFILE); [[ -n $p ]] && echo "$p ($(meta "$1" PROFILE_EMAIL))" || echo "~/.gemini (không qua agy-p)"; }

tpath() {  # transcript của agy cho job: tìm bằng marker duy nhất trong prompt
  local jd=$1 id t; id=$(basename "$jd"); t=$(meta "$jd" TRANSCRIPT)
  if [[ -z $t || ! -f $t ]]; then
    t=$(grep -l -F "[agy-hd:$id]" "$BRAIN"/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -1)
    [[ -n $t ]] && setmeta "$jd" TRANSCRIPT "$t"
  fi; echo "$t"
}
cid_of() { local t; t=$(tpath "$1"); [[ -n $t ]] && basename "$(dirname "$(dirname "$(dirname "$t")")")"; }
result_of() {
  local t; t=$(tpath "$1")
  if [[ -n $t ]]; then
    jq -rs '[.[]|select(.source=="MODEL" and .type=="PLANNER_RESPONSE" and ((.content//"")!=""))]|last|.content // "(agy chưa trả lời)"' "$t"
  else echo "(chưa có transcript; xem: agy-hd logs $(basename "$1"))"; fi
}
access() {
  local jd=$1 id ws pane t sp; id=$(basename "$jd"); ws=$(meta "$jd" WORKSPACE); pane=$(meta "$jd" PANE); sp=$(hcli); t=$(tpath "$jd")
  local wl; wl=$(herdr workspace get "$ws" 2>/dev/null | jq -r '.result.workspace.label // empty')
  echo "ACCESS:"
  echo "  session    : ${HERDR_SESSION:-default}"
  echo "  account    : $(acct_of "$jd")"
  if [[ -n ${HERDR_SESSION:-} && $HERDR_SESSION != default ]]; then
    echo "  VÀO XEM    : herdr --session $HERDR_SESSION   → workspace '${wl:-$ws}' → tab '$id'   (hoặc: herdr session attach $HERDR_SESSION)"
  else echo "  VÀO        : herdr   (session default) → workspace '${wl:-$ws}' → tab '$id'"; fi
  echo "  workspace  : $ws ('${wl:-?}')  tab: $(meta "$jd" TAB) (tên: $id)  pane: $pane"
  echo "  xem live   : $sp agent attach $id        (hoặc mở herdr TUI, chọn workspace '$id'; $sp workspace focus $ws)"
  echo "  log live   : agy-hd logs $id      | transcript: ${t:-<chưa có, hiện sau khi prompt đầu được gửi>}"
  echo "  prompt tiếp: agy-hd prompt $id \"...\"   | dừng: agy-hd interrupt $id   | đóng: agy-hd close $id"
  [[ -n $(meta "$jd" BRANCH) ]] && echo "  worktree   : $(meta "$jd" WORKTREE)  (branch $(meta "$jd" BRANCH))"
  echo "  prompt gốc : $jd/prompt.md"
}
finalize() {  # worktree: wrapper (không phải agy) commit những gì agy đã sửa
  local jd=$1 w; w=$(meta "$jd" WORKTREE); [[ -n $w && -d $w ]] || return 0
  if [[ -n $(git -C "$w" status --porcelain) ]]; then
    git -C "$w" add -A; git -C "$w" -c user.name=agy -c user.email=agy@local commit -q -m "agy: $(basename "$jd")" || true
  fi
}
screen() { herdr agent read "$1" --source "${2:-recent-unwrapped}" --lines "${3:-40}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
# agy đang chờ subagent (tool invoke_subagent): agent chính kết thúc lượt bằng "đang chờ subagent", herdr báo idle/done
# và transcript đã có câu trả lời, nhưng việc chưa xong. Thanh trạng thái hiện "· N subagent(s)" tới khi subagent trả về
# (gặp 2026-10-08 khi e2e nhiều account: wait báo DONE trong lúc subagent còn chạy).
subagent_busy() { screen "$1" visible 6 | grep -qE '[0-9]+ subagent\(s\)'; }

await_done() {  # $1=jd $2=timeout_s $3=số dòng transcript trước khi gửi prompt -> in: done|blocked|gone|timeout
  # herdr `agent prompt --wait` trả về ở lần idle đầu tiên, có thể nằm GIỮA các bước của agy (đã đo: báo DONE
  # trong khi agy vẫn working). Nên chỉ coi là xong khi idle/done ổn định VÀ transcript có bước mới kết thúc bằng
  # câu trả lời cuối; hoặc idle ổn định >= 5 lần lấy mẫu (15 s) dù transcript không khớp.
  local jd=$1 id deadline st stable=0 t fin; id=$(basename "$jd"); deadline=$(( $(date +%s) + $2 ))
  while (( $(date +%s) < deadline )); do
    st=$(astate "$id")
    case $st in
      blocked) echo blocked; return;;
      gone) echo gone; return;;
      idle|done)
        if busy "$jd"; then stable=0; sleep 3; continue; fi   # lệnh nền của agy còn chạy: chưa xong
        stable=$((stable+1)); fin=0; t=$(tpath "$jd")
        if [[ -n $t ]] && (( $(wc -l <"$t") > $3 )) && \
           jq -rs 'last|(.source=="MODEL" and .type=="PLANNER_RESPONSE" and ((.content//"")!=""))' "$t" 2>/dev/null | grep -q true; then fin=1; fi
        if (( stable >= 2 && fin )) || (( stable >= 5 )); then echo done; return; fi;;
      *) stable=0;;
    esac
    sleep 3
  done; echo timeout
}
send_prompt() {  # $1=jd  $2=text  $3=wait(1/0)  $4=timeout_s ; in STATUS
  local jd=$1 text=$2 wait=$3 tmo=$4 id out st n0=0 t; id=$(basename "$jd")
  local full="[agy-hd:$id] $text"
  printf '%s\n' "$full" >>"$jd/prompt.md"
  if (( ${#full} > 4000 )); then   # prompt dài: ghi file, gửi tham chiếu (tránh paste khổng lồ)
    local f="$jd/prompt-$(date +%s).md"; printf '%s\n' "$full" >"$f"
    full="[agy-hd:$id] Đọc file $f và làm đúng mọi chỉ dẫn trong đó (prompt đầy đủ của bạn nằm ở đó)."
  fi
  t=$(tpath "$jd"); [[ -n $t ]] && n0=$(wc -l <"$t")
  out=$(herdr agent prompt "$id" "$full" 2>&1); local rc=$?
  for _ in 1 2 3 4 5 6 7 8; do [[ -n $(tpath "$jd") ]] && break; sleep 1; done
  if [[ $rc -ne 0 ]]; then echo "STATUS=ERROR"; echo "$out" | jq -r '.error.message // .' 2>/dev/null | head -3; return 1; fi
  if [[ $wait -eq 0 ]]; then echo "STATUS=RUNNING"; return 0; fi
  st=$(await_done "$jd" "$tmo" "$n0")
  case $st in
    done) echo "STATUS=DONE";;
    blocked) echo "STATUS=BLOCKED  (agy đang chờ bạn: $(hcli) agent attach $id)";;
    timeout) echo "STATUS=TIMEOUT (agy vẫn đang chạy sau ${tmo}s; agy-hd status/wait/interrupt $id)";;
    *) echo "STATUS=$st";;
  esac
  [[ $st == done ]]
}

# ───────────────────────────────────── start
cmd_start() {
  local name=job dir=$PWD pfile="" prompt="" tmo=900 wt=0 carry=0 ro=0 async=0 park=0 o sess=${AGY_HD_SESSION:-} acct=""
  OPTIND=1; while getopts "n:d:f:p:t:S:u:WCRAP" o; do case $o in
    n) name=$OPTARG;; d) dir=$OPTARG;; f) pfile=$OPTARG;; p) prompt=$OPTARG;; t) tmo=$OPTARG;; S) sess=$OPTARG;; u) acct=$OPTARG;;
    P) park=1;;
    W) wt=1;; C) carry=1;; R) ro=1;; A) async=1;; *) sed -n '2,12p' "$SELF"; exit 2;; esac; done
  [[ -n $pfile ]] && prompt=$(<"$pfile")
  [[ -z $prompt && ! -t 0 ]] && prompt=$(cat)
  [[ -z $prompt ]] && die "thiếu prompt (-p, -f hoặc stdin)"
  [[ $carry -eq 1 && $wt -ne 1 ]] && die "-C cần -W"
  [[ -d $dir ]] || die "workdir không tồn tại: $dir"; dir=$(cd "$dir" && pwd)
  [[ -z $sess ]] && sess=$(shared_session)
  if [[ $sess == default ]]; then unset HERDR_SESSION; echo "WARN: chạy trong session 'default' của bạn (do chỉ định -S default)" >&2
  else export HERDR_SESSION=$sess; ensure_session "$sess"; fi; need

  local avail swp; avail=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo); swp=$(free -m | awk '/Swap/{ if ($2>0) printf "%d",$3*100/$2; else print 0}')
  if (( avail < 1500 )) && [[ -z ${AGY_HD_FORCE:-} ]]; then die "RAM trống chỉ ${avail} MB (mỗi agy ~300 MB): đóng bớt agent/job rồi chạy lại, hoặc AGY_HD_FORCE=1"; fi
  (( swp > 85 )) && echo "WARN: swap đang ${swp}% đầy, RAM trống ${avail} MB; mỗi agy thêm ~300 MB. Cân nhắc -P (tự nhả RAM sau khi xong) và giảm -j." >&2
  local prof="" pemail=""
  if have_profiles; then   # chọn account trong khoá: các start song song (fan) thấy job của nhau khi chia tải
    exec 8>"$JOBS/.pick.lock"; flock 8
    if [[ -n $acct ]]; then "$AGYP" env "$acct" >/dev/null || die "profile '$acct' không dùng được (agy-p ls)"; prof=$acct
    else prof=$(pick_profile) || { prof=$("$AGYP" default | awk '{print $1}'); echo "WARN: không account nào còn quota Gemini (agy-p usage); chạy bằng profile mặc định $prof" >&2; }; fi
    pemail=$("$AGYP" email "$prof")
  fi
  local n id jd; n=$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-\n' '-' | cut -c1-20)
  id="a-$n-$(printf '%04x' $((RANDOM % 65536)))"; jd="$JOBS/$id"; mkdir -p "$jd"
  local repo="" wtdir="" branch="" base="" workdir=$dir

  if [[ $wt -eq 1 ]]; then
    repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || die "-W cần workdir là git repo"
    local rel; rel=$(git -C "$dir" rev-parse --show-prefix)
    branch="agy/$id"; wtdir="$repo/../.agy-wt/$(basename "$repo")-$id"; mkdir -p "$(dirname "$wtdir")"
    git -C "$repo" worktree add -q -b "$branch" "$wtdir" HEAD || die "tạo worktree thất bại"
    wtdir=$(cd "$wtdir" && pwd); workdir="$wtdir/$rel"; base=$(git -C "$wtdir" rev-parse HEAD)
    if [[ -n $(git -C "$repo" status --porcelain) ]]; then
      if [[ $carry -eq 1 ]]; then
        git -C "$repo" diff --binary HEAD | git -C "$wtdir" apply --whitespace=nowarn - || die "carry diff thất bại"
        git -C "$repo" ls-files -z -o --exclude-standard | while IFS= read -r -d '' f; do mkdir -p "$wtdir/$(dirname "$f")"; cp -a "$repo/$f" "$wtdir/$f"; done
        git -C "$wtdir" add -A
        git -C "$wtdir" -c user.name=agy -c user.email=agy@local commit -q -m "carry: thay đổi chưa commit trước job $id" && base=$(git -C "$wtdir" rev-parse HEAD)
      else echo "WARN: repo có thay đổi chưa commit, worktree KHÔNG thấy chúng. Dùng -C để mang theo." >&2; fi
    fi
  fi

  local ws pane tab; place_pane "$workdir" "$id"; ws=$PL_WS; pane=$PL_PANE; tab=$PL_TAB
  cat >"$jd/meta.env" <<EOF
ID=$id
NAME=$name
SESSION=${HERDR_SESSION:-default}
WORKSPACE=$ws
TAB=$tab
PANE=$pane
WORKDIR=$workdir
REPO=$repo
WORKTREE=$wtdir
BRANCH=$branch
BASE=$base
CARRY=$carry
RO=$ro
STARTED=$(date +%s)
PROFILE=$prof
PROFILE_EMAIL=$pemail
PROMPT_HEAD=$(printf '%s' "$prompt" | head -c 100 | tr '\n' ' ')
EOF
  have_profiles && flock -u 8
  echo "JOB=$id"
  [[ -n $prof ]] && echo "ACCOUNT=$prof ($pemail)"
  local out sbx=() sig_before=""
  tree_sig() { { git -C "$workdir" status --porcelain; git -C "$workdir" diff HEAD; } 2>/dev/null | md5sum; }
  [[ $ro -eq 1 ]] && { sbx=(--sandbox); sig_before=$(tree_sig); }   # -R: guard trong prompt không chặn gì → thêm --sandbox + kiểm tra cây git sau khi chạy
  [[ -n $prof ]] && profile_env_in_pane "$pane" "$prof"
  out=$(herdr agent start "$id" --kind agy --pane "$pane" --timeout 60000 -- \
        --model "$MODEL" --effort high --dangerously-skip-permissions "${sbx[@]}" 2>&1) || {
    echo "STATUS=ERROR (agent start): $(jq -r '.error.message // .' <<<"$out" 2>/dev/null | head -2)"; access "$jd"; exit 1; }

  # agy hỏi "Do you trust this folder?" ở thư mục mới (bypass KHÔNG bỏ qua, herdr còn báo idle sai).
  # Chỉ xác nhận cho workdir do chính lệnh này chỉ định/tạo.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if screen "$id" visible 30 | grep -q 'Do you trust'; then
      herdr agent send-keys "$id" enter >/dev/null; echo "TRUST: đã xác nhận 'trust folder' cho $workdir"; sleep 2; break; fi
    screen "$id" visible 30 | grep -q 'for shortcuts' && break; sleep 1
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do screen "$id" visible 30 | grep -q 'for shortcuts' && break; sleep 1; done

  local guard="Ràng buộc: không git push/commit/reset/checkout/branch, không xóa file ngoài phạm vi được giao, không truy cập mạng nội bộ 10.0.0.0/8, không bật process nền (nohup/setsid). Chạy mọi lệnh ở chế độ chờ cho tới khi xong: không dùng chế độ chạy nền/bất đồng bộ của công cụ chạy lệnh, không kết thúc lượt khi còn lệnh đang chạy."
  [[ $wt -eq 1 ]] && guard="$guard Bạn đang ở git worktree riêng: chỉ sửa file trong thư mục hiện tại, đừng cd ra ngoài."
  [[ $ro -eq 1 ]] && guard="$guard CHẾ ĐỘ CHỈ ĐỌC: tuyệt đối không tạo/sửa/xóa file, chỉ đọc và báo cáo."
  printf 'GUARD: %s\n' "$guard" >"$jd/prompt.md"
  access "$jd"          # in TRƯỚC khi chờ: người chạy nền đọc được ngay để đưa link cho người dùng
  echo "..."
  local wait=1; [[ $async -eq 1 ]] && wait=0
  send_prompt "$jd" "$prompt

$guard" $wait "$tmo"; local rc=$?
  finalize "$jd"
  [[ $ro -eq 1 && $(tree_sig) != "$sig_before" ]] && { echo "⚠ RO_VIOLATION: cây làm việc đổi trong lúc chạy -R. Xem: git -C $workdir status; hoàn tác trước khi tin kết quả."; rc=1; }
  access "$jd" | grep -E 'transcript' | sed 's/^ *//'
  if [[ $wt -eq 1 ]]; then echo "DIFFSTAT:"; git -C "$repo" diff --stat "$base" "$branch" 2>/dev/null | tail -20; fi
  if [[ $wait -eq 1 ]]; then echo "---"; result_of "$jd"; fi
  [[ $park -eq 1 && $rc -eq 0 ]] && cmd_park "$id" >&2   # DONE rồi mới park; kết quả đã lưu ở transcript
  return $rc
}

# ───────────────────────────────────── điều khiển
cmd_prompt() {
  local k=${1:?job}; shift; local text="" pfile="" wait=1 tmo=900 o; local jd; jd=$(resolve "$k"); use_session "$jd"; need
  if [[ ${1:-} != -* && -n ${1:-} ]]; then text=$1; shift; fi
  OPTIND=1; while getopts "f:At:" o; do case $o in f) pfile=$OPTARG;; A) wait=0;; t) tmo=$OPTARG;; *) exit 2;; esac; done
  [[ -n $pfile ]] && text=$(<"$pfile"); [[ -n $text ]] || die "thiếu prompt"
  [[ $(astate "$(basename "$jd")") == gone ]] && die "agent đã thoát; chạy: agy-hd resume $k"
  send_prompt "$jd" "$text" $wait "$tmo"; local rc=$?; finalize "$jd"
  [[ $wait -eq 1 ]] && { echo "---"; result_of "$jd"; }; return $rc
}
cmd_status() {
  local jd id st t; jd=$(resolve "${1:?job}"); id=$(basename "$jd"); use_session "$jd"; need; st=$(astate "$id")
  echo "JOB=$id  STATE=$st  AGE=$(ago "$(meta "$jd" STARTED)")  WORKSPACE=$(meta "$jd" WORKSPACE)  BRANCH=$(meta "$jd" BRANCH)"
  if [[ $st == working ]]; then t=$(tpath "$jd"); if [[ -n $t ]]; then local i=$(( $(date +%s) - $(stat -c %Y "$t") ))
    echo "IDLE=${i}s$([[ $i -gt $STALL ]] && echo "  ⚠ STALL: transcript không đổi > ${STALL}s (xem logs, cân nhắc interrupt)")"; fi; fi
  [[ $st == blocked ]] && echo "⚠ BLOCKED: agy đang hỏi/chờ duyệt. Xem: agy-hd logs $id ; attach: $(hcli) agent attach $id"
  [[ $st == gone ]] && echo "agent đã thoát (interrupt/crash). Mở lại: agy-hd resume $id"
  echo "--- màn hình cuối:"; screen "$id" recent-unwrapped 14 | grep -v '^\s*$' | tail -8
}
cmd_wait() { local jd id t n0=0 st; jd=$(resolve "${1:?job}"); id=$(basename "$jd"); use_session "$jd"; need
  t=$(tpath "$jd"); [[ -n $t ]] && n0=$(( $(wc -l <"$t") - 1 ))   # đang chờ lượt hiện tại: cho phép bước cuối đã có sẵn
  st=$(await_done "$jd" "${2:-600}" "$n0"); echo "STATE=$st (herdr: $(astate "$id"))"; [[ $st == done ]]; }
cmd_logs() {
  local jd id n=80 tr=0 a; jd=$(resolve "${1:?job}"); shift; id=$(basename "$jd"); use_session "$jd"
  for a in "$@"; do [[ $a == --transcript ]] && tr=1 || n=$a; done
  if [[ $tr -eq 1 ]]; then local t; t=$(tpath "$jd"); [[ -n $t ]] || die "chưa có transcript"
    jq -r '"#\(.step_index) [\(.source)/\(.type)] \(.status // "")  \((.content // (.tool_calls|tostring) // "")|gsub("\n";" ")|.[0:220])"' "$t" | tail -n "$n"
  else need; [[ $(astate "$id") == gone ]] && echo "(agent đã thoát; dùng --transcript)"; screen "$id" recent-unwrapped "$n"; fi
}
cmd_result()  { local jd; jd=$(resolve "${1:?job}"); result_of "$jd"; }
cmd_access()  { local jd; jd=$(resolve "${1:?job}"); use_session "$jd"; access "$jd"; }
cmd_summary() {
  local jd st; jd=$(resolve "${1:?job}"); use_session "$jd"; finalize "$jd"
  echo "JOB=$(basename "$jd")  STATE=$(astate "$(basename "$jd")")"; echo "---"; result_of "$jd"
  local b r; b=$(meta "$jd" BRANCH); r=$(meta "$jd" REPO)
  [[ -n $b ]] && { echo "--- DIFFSTAT $b"; git -C "$r" diff --stat "$(meta "$jd" BASE)" "$b"; }
}
cmd_interrupt() {
  local jd id st i; jd=$(resolve "${1:?job}"); id=$(basename "$jd"); use_session "$jd"; need
  [[ $(astate "$id") == gone ]] && { echo "agent đã thoát sẵn"; return 0; }
  # Đã đo: lệnh chạy foreground -> 1 Ctrl+C huỷ lượt, agy về idle (còn sống, giữ ngữ cảnh).
  # Tác vụ nền của agy -> 1 Ctrl+C chỉ hiện "press ctrl+c again to exit"; Ctrl+C lần 2 mới thoát agy và dọn lệnh con.
  herdr agent send-keys "$id" ctrl+c >/dev/null
  for i in 1 2 3 4 5 6; do sleep 1; st=$(astate "$id"); [[ $st == idle || $st == done || $st == gone ]] && break; done
  if [[ $st == working || $st == blocked ]]; then
    herdr agent send-keys "$id" ctrl+c >/dev/null
    for i in $(seq 20); do st=$(astate "$id"); [[ $st == gone || $st == idle || $st == done ]] && break; sleep 1; done
  fi
  case $st in
    gone) echo "đã interrupt $id: agy thoát, workspace còn. Tiếp hội thoại: agy-hd resume $id";;
    idle|done) echo "đã huỷ lượt đang chạy của $id: agy còn sống, giữ ngữ cảnh. Giao việc tiếp: agy-hd prompt $id \"...\"";;
    *) echo "agy chưa dừng (state=$st): dùng agy-hd close $id"; return 1;;
  esac
}
cmd_park() {  # thoát agy (đang idle) để nhả ~280 MB RAM; workspace + transcript giữ nguyên; agy-hd resume để mở lại
  local jd id st i; jd=$(resolve "${1:?job}"); id=$(basename "$jd"); use_session "$jd"; need; finalize "$jd"
  st=$(astate "$id"); [[ $st == gone ]] && { echo "$id: agy đã thoát sẵn"; return 0; }
  [[ $st == working || $st == blocked ]] && die "$id đang $st: chờ xong hoặc dùng interrupt trước"
  busy "$jd" && die "$id còn lệnh đang chạy (agy chạy nền): chờ xong rồi park"
  herdr agent send-keys "$id" ctrl+c >/dev/null; sleep 1; herdr agent send-keys "$id" ctrl+c >/dev/null   # idle: lần 1 hiện banner, lần 2 thoát
  for i in $(seq 15); do [[ $(astate "$id") == gone ]] && { echo "đã park $id: nhả RAM agy, workspace còn. Mở lại: agy-hd resume $id"; return 0; }; sleep 1; done
  echo "agy chưa thoát: dùng agy-hd close $id"; return 1
}
cmd_resume() {
  local jd id cid; jd=$(resolve "${1:?job}"); id=$(basename "$jd"); use_session "$jd"; need
  [[ $(astate "$id") == gone ]] || die "agent vẫn đang chạy; dùng agy-hd prompt"
  cid=$(cid_of "$jd"); [[ -n $cid ]] || die "không biết conversation id"
  local prof; prof=$(meta "$jd" PROFILE); [[ -n $prof ]] && profile_env_in_pane "$(meta "$jd" PANE)" "$prof"
  herdr agent start "$id" --kind agy --pane "$(meta "$jd" PANE)" --timeout 60000 -- \
    --model "$MODEL" --effort high --dangerously-skip-permissions --conversation "$cid" >/dev/null 2>&1 || die "agent start thất bại"
  sleep 3; screen "$id" visible 30 | grep -q 'Do you trust' && herdr agent send-keys "$id" enter >/dev/null
  echo "đã mở lại $id với conversation $cid, account $(acct_of "$jd")"
}
# Hết hạn mức Antigravity giữa chừng: màn hình agent hiện "Individual quota reached ... Resets in 3h16m" (log
# ~/.gemini/antigravity-cli/log/cli-*.log ghi RESOURCE_EXHAUSTED (code 429)); agy đứng im ở idle/done mà việc chưa xong
# (gặp 2026-10-05 trên cả 4 agent chấm điểm). Người dùng: tắt session agy đó đi rồi mở lại là chạy được.
# Chỉ xét ~12 dòng cuối đang hiện: thông báo cũ trôi lên khi agy chạy tiếp sau restart.
quota_hit() { screen "$1" visible 40 | grep -v '^[[:space:]]*$' | tail -12 | grep -q -E 'Individual quota reached|RESOURCE_EXHAUSTED|[Qq]uota (reached|exceeded)'; }
cmd_restart() {
  local jd id i msg; jd=$(resolve "${1:?job}"); shift; id=$(basename "$jd"); use_session "$jd"; need
  msg=${1:-"Phiên agy trước của bạn bị dừng giữa chừng (hết hạn mức Antigravity) và vừa được mở lại. Tiếp tục ĐÚNG việc đang làm dở: xem lại các file bạn đã ghi để biết đã xong tới đâu, làm tiếp phần còn thiếu, không làm lại từ đầu, rồi báo cáo đúng format đã yêu cầu. Chạy mọi lệnh ở chế độ chờ cho tới khi xong."}
  if [[ $(astate "$id") != gone ]]; then   # idle: ctrl+c lần 1 hiện banner, lần 2 thoát; working: lần 1 huỷ lượt
    for i in 1 2 3 4; do herdr agent send-keys "$id" ctrl+c >/dev/null; sleep 1; [[ $(astate "$id") == gone ]] && break; done
    for i in $(seq 15); do [[ $(astate "$id") == gone ]] && break; sleep 1; done
    [[ $(astate "$id") == gone ]] || die "$id không thoát được: agy-hd close $id rồi start lại job"
  fi
  if have_profiles && [[ -n $(meta "$jd" PROFILE) ]]; then   # hết quota: chuyển sang account khác còn quota
    local qe e ex=() np; qe="$(meta "$jd" QUOTA_EMAILS) $(meta "$jd" PROFILE_EMAIL)"
    qe=$(tr ' ' '\n' <<<"$qe" | grep -v '^$' | sort -u | tr '\n' ' '); setmeta "$jd" QUOTA_EMAILS "$qe"
    "$AGYP" usage --tsv --max-age 0 >/dev/null 2>&1   # làm mới quota: account vừa hết sẽ hiện 0%
    for e in $qe; do ex+=(--exclude-email "$e"); done
    exec 8>"$JOBS/.pick.lock"; flock 8
    if np=$(pick_profile "${ex[@]}" 2>/dev/null); then
      echo "đổi account: $(acct_of "$jd") → $np ($("$AGYP" email "$np"))"
      setmeta "$jd" PROFILE "$np"; setmeta "$jd" PROFILE_EMAIL "$("$AGYP" email "$np")"
    else echo "không còn account nào khác có quota: mở lại trên $(acct_of "$jd")"; fi
    flock -u 8
  fi
  cmd_resume "$id" || return 1
  for i in $(seq 30); do screen "$id" visible 30 | grep -q 'for shortcuts' && break; sleep 1; done
  send_prompt "$jd" "$msg" 0 900
  setmeta "$jd" RESTARTS $(( $(meta "$jd" RESTARTS || echo 0) + 1 )); setmeta "$jd" LAST_RESTART "$(date +%s)"
  for i in $(seq 20); do [[ $(astate "$id") == working ]] && break; sleep 1; done
  if [[ $(astate "$id") == working ]]; then echo "đã khởi động lại $id, agy đang làm tiếp. Theo dõi: agy-hd watch $id"
  else echo "⚠ đã khởi động lại $id nhưng agy chưa chạy ($(astate "$id")); xem agy-hd status $id"; fi
}
# tick: một lượt kiểm mọi job đang mở. systemd user timer agy-hd-tick.timer chạy nó MỖI PHÚT, độc lập với phiên
# Claude (một watch chạy nền trong phiên có thể bị Claude Code dừng khi máy thiếu RAM, như ngày 2026-10-05: 4 agent
# hết hạn mức mà phiên không biết). Mỗi job được gán một trạng thái:
#   RUNNING  agy đang làm (working, hoặc còn lệnh đang chạy)
#   DONE     xong: không còn lệnh chạy, transcript kết thúc bằng câu trả lời cuối (cả khi agy đã park/thoát)
#   QUOTA    hết hạn mức Antigravity: tick TỰ restart (tối đa 5 lần mỗi job, cách nhau >= 3 phút)
#   STOPPED  đã dừng giữa chừng: agy thoát mà không có câu trả lời cuối, hoặc đứng im không có câu trả lời
#   STALL    treo: lệnh chạy quá AGY_CMD_STALL_SEC, hoặc working mà transcript đứng yên quá AGY_STALL_SEC
#   BLOCKED  agy đang hỏi/chờ duyệt
# Job DONE quá AGY_AUTOCLOSE_MIN phút (15) thì tick đóng tab (người dùng 2026-10-05: "khi done task subagent thì đóng
# tab lại"). Transcript và worktree vẫn còn: agy-hd result / wt-diff đọc được sau khi đóng.
# Ghi $JOBS/STATUS.tsv (bảng hiện tại) và nối mỗi lần đổi trạng thái vào $JOBS/events.log. Bỏ qua job đã đóng
# (close/wt-merge/wt-drop/gc) và job bắt đầu quá 24 giờ trước.
cmd_tick() {
  local show=0; [[ ${1:-} == --show ]] && show=1
  exec 9>"$JOBS/.tick.lock"; flock -w 50 9 || die "tick khác đang chạy"
  local now jd id st t age steps bc cage cmd v prev started tmp rs lr
  now=$(date +%s); tmp="$JOBS/.status.$$"
  printf 'job\tstate\tsince\tsteps\ttx_age_s\trestarts\tworkspace\tcmd\taccount\n' >"$tmp"
  for jd in "$JOBS"/a-*/; do
    jd=${jd%/}; [[ -f $jd/meta.env ]] || continue
    [[ $(meta "$jd" CLOSED) == 1 ]] && continue
    started=$(meta "$jd" STARTED); [[ -n $started ]] && (( now - started > 86400 )) && continue
    id=$(basename "$jd"); use_session "$jd"; st=$(astate "$id"); t=$(tpath "$jd")
    # agy đã thoát VÀ pane không còn: tab đã bị đóng (tay, hoặc trước khi close_ui biết đánh dấu CLOSED).
    # Một job đã park thì pane còn, nên vẫn được xét (DONE hoặc STOPPED).
    if [[ $st == gone ]] && ! herdr pane get "$(meta "$jd" PANE)" 2>/dev/null | grep -q '"result"'; then setmeta "$jd" CLOSED 1; continue; fi
    age=-; steps=0; [[ -n $t && -f $t ]] && { age=$(( now - $(stat -c %Y "$t") )); steps=$(wc -l <"$t"); }
    (( age != - && age < 0 )) 2>/dev/null && age=0
    bc=$(watch_cmd "$jd"); cage=${bc%% *}; cmd=${bc#* }; [[ -z $bc ]] && { cage=0; cmd=""; }
    if [[ $st != gone ]] && quota_hit "$id"; then v=QUOTA
    elif [[ $st == blocked ]]; then v=BLOCKED
    elif [[ -n $cmd ]]; then v=RUNNING; (( cage > CMD_STALL )) && v=STALL
    elif [[ $st != gone ]] && subagent_busy "$id"; then v=RUNNING
    elif watch_fin "$jd" && [[ $st == idle || $st == done || $st == gone ]]; then v=DONE
    elif [[ $st == gone ]]; then v=STOPPED
    elif [[ $st == working ]]; then v=RUNNING; [[ $age != - ]] && (( age > STALL )) && v=STALL
    elif [[ $age != - ]] && (( age > STALL )); then v=STOPPED
    else v=RUNNING; fi
    prev=$(meta "$jd" TICK_STATE)
    if [[ $v != "$prev" ]]; then
      setmeta "$jd" TICK_STATE "$v"; setmeta "$jd" TICK_SINCE "$now"
      echo "$(date '+%F %T') $id ${prev:-NEW} -> $v${cmd:+ (cmd: ${cmd:0:50})}" >>"$JOBS/events.log"
    fi
    if [[ $v == DONE ]] && (( AUTOCLOSE_MIN > 0 )) && (( now - $(meta "$jd" TICK_SINCE) >= AUTOCLOSE_MIN * 60 )); then
      ( close_ui "$jd" ) >/dev/null 2>&1
      echo "$(date '+%F %T') $id DONE quá ${AUTOCLOSE_MIN} phút: đã đóng tab" >>"$JOBS/events.log"; continue
    fi
    if [[ $v == QUOTA ]]; then
      rs=$(meta "$jd" RESTARTS); rs=${rs:-0}; lr=$(meta "$jd" LAST_RESTART); lr=${lr:-0}
      local gap=180; have_profiles && [[ -n $(meta "$jd" PROFILE) ]] && gap=60   # có account khác để chuyển: restart sớm
      if (( rs < 5 && now - lr >= gap )); then
        echo "$(date '+%F %T') $id auto-restart #$((rs+1)) (quota)" >>"$JOBS/events.log"
        ( cmd_restart "$id" ) >>"$JOBS/events.log" 2>&1
      elif (( rs >= 5 )); then
        [[ $(meta "$jd" QUOTA_GAVE_UP) == 1 ]] || { setmeta "$jd" QUOTA_GAVE_UP 1; echo "$(date '+%F %T') $id QUOTA: đã restart 5 lần, dừng tự restart (báo người dùng)" >>"$JOBS/events.log"; }
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$v" "$(date -d "@$(meta "$jd" TICK_SINCE)" +%H:%M:%S)" "$steps" "$age" \
      "$(rs=$(meta "$jd" RESTARTS); echo "${rs:-0}")" "$(meta "$jd" WORKSPACE)" "${cmd:0:50}" "$(meta "$jd" PROFILE)" >>"$tmp"
  done
  mv "$tmp" "$JOBS/STATUS.tsv"; printf '%s\n' "$(date '+%F %T')" >"$JOBS/STATUS.updated"
  (( show )) && { column -t -s$'\t' "$JOBS/STATUS.tsv"; echo "--- 8 sự kiện cuối ($JOBS/events.log):"; tail -8 "$JOBS/events.log" 2>/dev/null; }
  return 0
}
cmd_close() {
  local jd; jd=$(resolve "${1:?job}"); use_session "$jd"; need; finalize "$jd"
  close_ui "$jd"; echo "đã đóng tab $(meta "$jd" TAB) của $(basename "$jd") (workspace của phiên giữ nguyên nếu còn tab khác)"
}
ps_one() {  # bảng theo workspace (= 1 phiên Claude Code) -> pane (= 1 subagent); ★ = job do agy-hd tạo; $1=1 thì tự làm mới
  local watch=${1:-0}; need
  while :; do
    local ws ag out map; ws=$(herdr workspace list 2>/dev/null); ag=$(herdr agent list 2>/dev/null)
    map=$(for d in "$JOBS"/*/; do d=${d%/}; [[ $(meta "$d" SESSION) == "${HERDR_SESSION:-default}" ]] && printf '%s %s\n' "$(meta "$d" PANE)" "$(basename "$d")"; done)
    out=$(jq -rn --argjson ws "${ws:-null}" --argjson ag "${ag:-null}" --arg map "$map" '
      ($map|split("\n")|map(select(length>0)|split(" ")|{(.[0]):.[1]})|add // {}) as $jobs
      | ($ag.result.agents // []) as $A
      | ({"working":"● working","idle":"○ idle","done":"✓ done","blocked":"⚠ BLOCKED","unknown":"? unknown"}) as $sym
      | $ws.result.workspaces[] | . as $w
      | ($A|map(select(.workspace_id==$w.workspace_id))) as $as
      | if ($as|length)==0 then [" ",$w.label,"-","-",($sym[$w.agent_status] // $w.agent_status),"",""]
        else $as[] | [ (if $jobs[.pane_id] then "★" else " " end), $w.label, .tab_id, .agent, ($sym[.agent_status] // .agent_status),
                       ((.cwd // "")|split("/")|.[-2:]|join("/")), ($jobs[.pane_id] // "") ] end | @tsv')
    [[ $watch -eq 1 ]] && clear
    echo "herdr session: ${HERDR_SESSION:-default}   ($(date +%H:%M:%S))   ★ = job do agy-hd tạo   |   workspace = 1 phiên Claude Code, tab = 1 subagent"
    { printf 'W\tWORKSPACE\tTAB\tAGENT\tSTATE\tDIR\tJOB\n'; echo "$out"; } | column -t -s$'\t'
    echo; echo "Xem: agy-hd open <job>   log: agy-hd logs <job>   chi tiết: agy-hd status <job>"
    [[ $watch -eq 0 ]] && return 0; sleep 2
  done
}
cmd_ps() {  # agy-hd ps [-w] [-a]
  local w=0 all=0 a n; for a in "$@"; do [[ $a == -w ]] && w=1; [[ $a == -a ]] && all=1; done
  if [[ $all -eq 1 ]]; then
    while :; do
      [[ $w -eq 1 ]] && clear
      for n in $(herdr session list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}'); do
        ( [[ $n == default ]] && unset HERDR_SESSION || export HERDR_SESSION=$n; ps_one 0 ); echo
      done
      [[ $w -eq 0 ]] && return 0; sleep 2
    done
  else
    local sn; sn=$(shared_session)
    if session_running "$sn"; then ( export HERDR_SESSION=$sn; ps_one "$w" )
    else echo "Session herdr '$sn' chưa chạy (chưa có subagent nào). Tạo sẵn: agy-hd init  |  mọi session: agy-hd sessions"; fi
  fi
}
cmd_init() {  # tạo sẵn session dùng chung để bạn attach được ngay
  local n; n=$(shared_session); ensure_session "$n"; export HERDR_SESSION=$n; need
  echo "session '$n' đang chạy. Vào xem: herdr --session $n"
}
cmd_rename_space() {  # đổi tên nhiệm vụ của phiên Claude này: nhãn workspace = "#<số> <tên>"
  local topic=${1:?tên mới}; local n key ccf ws label; n=$(shared_session); export HERDR_SESSION=$n; key=$(cc_key); ccf="$JOBS/.cc/$key@$n"
  label=$("$AGY_ID_BIN" rename "$topic") || die "agy-id rename thất bại"
  if [[ -f $ccf ]] && need 2>/dev/null; then ws=$(sed -n 's/^WS=//p' "$ccf"); herdr workspace rename "$ws" "$label" >/dev/null && echo "đã đổi tên workspace $ws → '$label'"
  else echo "đã đặt tên nhiệm vụ: $label (workspace sẽ mang nhãn này khi chạy subagent đầu tiên)"; fi
}
cmd_sessions() {  # các session herdr + số workspace; (agy-hd) = do agy-hd tạo
  printf '%-24s %-8s %-4s %s\n' SESSION STATUS WS NOTE
  herdr session list 2>/dev/null | awk 'NR>1{print $1, $2}' | while read -r n st; do
    local c="-"; [[ $st == running ]] && c=$( ( [[ $n == default ]] && unset HERDR_SESSION || export HERDR_SESSION=$n; herdr workspace list 2>/dev/null | jq '.result.workspaces|length' 2>/dev/null ) || echo -)
    printf '%-24s %-8s %-4s %s\n' "$n" "$st" "${c:--}" "$([[ -f $JOBS/.sessions/$n.log ]] && echo '(agy-hd) vào xem: herdr --session '$n)"
  done
}
cmd_session_stop() {  # chỉ dừng/xóa session do agy-hd tạo (không bao giờ đụng default)
  local n=${1:?tên session}; [[ $n == default ]] && die "không dừng session default"
  [[ -f $JOBS/.sessions/$n.log ]] || die "'$n' không do agy-hd tạo: không đụng vào"
  herdr session stop "$n" >/dev/null 2>&1; sleep 1; herdr session delete "$n" >/dev/null 2>&1; rm -f "$JOBS/.sessions/$n.log"; echo "đã dừng và xóa session $n"
}
cmd_open() {  # attach thẳng vào agent của job (hoặc workspace id wX)
  local k=${1:?job hoặc workspace id}; need
  if [[ $k =~ ^w[A-Za-z0-9]+$ ]] && ! ls -d "$JOBS/$k"* >/dev/null 2>&1; then herdr workspace focus "$k"; return; fi
  local jd; jd=$(resolve "$k"); use_session "$jd"; exec herdr agent attach "$(basename "$jd")"
}
cmd_list() {
  local d
  for d in $(ls -1dt "$JOBS"/*/ 2>/dev/null | tac); do d=${d%/}
    local st; st=$( ( use_session "$d"; herdr status server 2>/dev/null | grep -q running && astate "$(basename "$d")" || echo no-server ) )
    printf '%-8s %-7s %-14s %-6s %-22s %-14s %s  %s\n' "$st" "$(ago "$(meta "$d" STARTED)")" "$(meta "$d" SESSION)" "$(meta "$d" WORKSPACE)" "$(basename "$d")" "$(p=$(meta "$d" PROFILE); echo "${p:--}")" "$(meta "$d" BRANCH)" "$(p=$(meta "$d" PROMPT_HEAD); echo "${p:0:40}")"
  done
}
cmd_wt() {
  local sub=$1 jd r b w base; jd=$(resolve "${2:?job}"); r=$(meta "$jd" REPO); b=$(meta "$jd" BRANCH); w=$(meta "$jd" WORKTREE); base=$(meta "$jd" BASE)
  [[ -n $b ]] || die "job này không chạy với -W"; use_session "$jd"
  case $sub in
  wt-diff) finalize "$jd"; git -C "$r" diff "$base" "$b" ;;
  wt-merge)
    [[ $(astate "$(basename "$jd")") == working ]] && die "agy còn đang chạy (agy-hd wait / interrupt)"; finalize "$jd"
    if [[ $(meta "$jd" CARRY) == 1 ]]; then
      git -C "$r" diff --binary "$base" "$b" | git -C "$r" apply --3way --whitespace=nowarn - \
        || { echo "CONFLICT khi áp diff vào cây làm việc của $r. Worktree giữ nguyên: $w"; exit 1; }
      echo "đã áp thay đổi của agy vào cây làm việc (chưa commit)"
    else git -C "$r" merge --no-ff -m "Merge $b (agy subagent)" "$b" || { echo "CONFLICT: giải quyết tay trong $r rồi commit, hoặc git merge --abort"; exit 1; }; fi
    close_ui "$jd"
    git -C "$r" worktree remove --force "$w" && git -C "$r" branch -D "$b" >/dev/null && echo "đã dọn $b + đóng tab" ;;
  wt-drop)
    close_ui "$jd"
    git -C "$r" worktree remove --force "$w"; git -C "$r" branch -D "$b"; echo "đã bỏ $b" ;;
  esac
}
cmd_gc() {
  local days=3 yes=0 a d now keep=0 del=0; for a in "$@"; do [[ $a == -y ]] && yes=1 || days=$a; done; now=$(date +%s)
  for d in "$JOBS"/*/; do d=${d%/}; (( now - $(meta "$d" STARTED) < days*86400 )) && continue
    local id st b w r; id=$(basename "$d"); b=$(meta "$d" BRANCH); w=$(meta "$d" WORKTREE); r=$(meta "$d" REPO)
    st=$( ( use_session "$d"; astate "$id" ) )
    [[ $st == working || $st == blocked ]] && continue
    if [[ -n $b && -d $w && $(git -C "$r" rev-parse "$b" 2>/dev/null) != $(meta "$d" BASE) ]]; then
      echo "GIỮ   $id  ($b có thay đổi chưa merge)"; keep=$((keep+1)); continue; fi
    echo "DỌN   $id  ($st)"; del=$((del+1))
    if [[ $yes -eq 1 ]]; then ( use_session "$d"; close_ui "$d" )
      [[ -n $b && -d $w ]] && { git -C "$r" worktree remove --force "$w"; git -C "$r" branch -D "$b" >/dev/null; }; rm -rf "$d"; fi
  done
  local f n c
  for f in "$JOBS"/.sessions/*.log; do [[ -f $f ]] || continue; n=$(basename "$f" .log)
    [[ $n == "$(shared_session)" ]] && continue
    c=$( ( export HERDR_SESSION=$n; herdr workspace list 2>/dev/null | jq '.result.workspaces|length' 2>/dev/null ) || echo 0 )
    if [[ ${c:-0} -eq 0 ]]; then echo "DỌN   session rỗng $n"; [[ $yes -eq 1 ]] && cmd_session_stop "$n" >/dev/null; fi
  done
  echo "$del job dọn$([[ $yes -eq 0 ]] && echo ' (chưa xóa, thêm -y)'), $keep giữ lại"
}
cmd_fan() {
  local tasks="" res="" j=3 dir=$PWD fl=() tmo=900 o; OPTIND=1
  local keep=0 fsess=""; while getopts "i:o:j:d:WCRt:S:Ku:" o; do case $o in K) keep=1;; S) fsess=$OPTARG;; u) fl+=(-u "$OPTARG");; i) tasks=$OPTARG;; o) res=$OPTARG;; j) j=$OPTARG;; d) dir=$OPTARG;;
    W) fl+=(-W);; C) fl+=(-C);; R) fl+=(-R);; t) tmo=$OPTARG;; *) exit 2;; esac; done
  [[ -z $fsess ]] && fsess=$(shared_session); fl+=(-S "$fsess")
  [[ $keep -eq 0 ]] && fl+=(-P)   # mặc định nhả RAM từng agent ngay khi task xong (-K để giữ sống)
  [[ -d $tasks && -n $res ]] || die "fan: cần -i tasks_dir -o results_dir"; (( j > 4 )) && j=4; mkdir -p "$res"; : >"$res/SUMMARY.tsv"; : >"$res/ACCESS.txt"
  export SELF res dir tmo; export fl_str="${fl[*]:-}"
  ls "$tasks"/*.md | xargs -P "$j" -I{} bash -c '
    f=$1; id=$(basename "$f" .md); "$SELF" start -n "$id" -f "$f" -d "$dir" -t "$tmo" $fl_str >"$res/$id.out" 2>"$res/$id.err"; rc=$?
    job=$(sed -n "s/^JOB=//p" "$res/$id.out" | head -1)
    printf "%s\t%s\t%s\t%s\t%s\n" "$id" "$(sed -n "s/^STATUS=//p" "$res/$id.out" | head -1 | cut -c1-12)" "$job" \
      "$(sed -n "s/.*  tab: \([^ ]*\) .*/\1/p" "$res/$id.out" | head -1)" "$(sed -n "s/^BRANCH=//p;s/.*(branch \(.*\))/\1/p" "$res/$id.out" | head -1)" >>"$res/SUMMARY.tsv"' _ {} &
  local fan=$!
  # ACCESS.txt: gom dòng truy cập ngay khi từng task đã lên (đọc được trong lúc đang chạy)
  while kill -0 $fan 2>/dev/null; do for f in "$res"/*.out; do [[ -f $f ]] && grep -q '^ACCESS:' "$f" && ! grep -q "^== $(basename "$f" .out)$" "$res/ACCESS.txt" \
      && { echo "== $(basename "$f" .out)"; sed -n '/^ACCESS:/,/^\.\.\./p' "$f" | grep -v '^\.\.\.'; } >>"$res/ACCESS.txt"; done; sleep 3; done; wait $fan
  sort -o "$res/SUMMARY.tsv" "$res/SUMMARY.tsv"; column -t -s$'\t' "$res/SUMMARY.tsv"; echo "ACCESS cả đợt: $res/ACCESS.txt"
  ! grep -qv $'\tDONE' "$res/SUMMARY.tsv"
}

# watch: agy có thể treo giữa chừng: herdr vẫn báo working mà transcript đứng yên, hoặc một lệnh nó chạy
# (test, build) không bao giờ xong. start/wait chỉ ngồi chờ tới timeout mà không nói gì. watch kiểm mỗi -i giây
# (mặc định 60), in một dòng cho mỗi job, và THOÁT NGAY khi có job BLOCKED (mã 3), GONE (4) hoặc STALL (2), để phiên
# Claude chạy nó nền được báo. Hết hạn mức Antigravity (quota) thì thoát 6: chạy agy-hd restart <job>.
# Mọi job DONE thì thoát 0; quá -t giây (mặc định 3600) thì 5.
#   STALL = không có lệnh nào đang chạy và transcript đứng yên quá AGY_STALL_SEC (180 s),
#           hoặc một lệnh đã chạy quá AGY_CMD_STALL_SEC (900 s).
#   DONE  = idle/done, không còn lệnh nào chạy, transcript kết thúc bằng câu trả lời cuối, và vẫn y nguyên sau 5 s.
watch_cmd() {  # $1=jd -> "<giây đã chạy> <lệnh>" của lệnh (không phải MCP server) mà agy đang chạy, rỗng nếu không có
  local p c cl
  for p in $(agy_pids "$1"); do for c in $(pgrep -P "$p"); do
    cl=$(tr '\0\n\t' '   ' <"/proc/$c/cmdline" 2>/dev/null); [[ ${cl,,} == *mcp* ]] && continue   # một dòng, kể cả python -c nhiều dòng
    echo "$(ps -o etimes= -p "$c" 2>/dev/null | tr -d ' ') ${cl:0:70}"; return 0
  done; done
}
watch_fin() { local t; t=$(tpath "$1"); [[ -n $t ]] && jq -rs 'last|(.source=="MODEL" and .type=="PLANNER_RESPONSE" and ((.content//"")!=""))' "$t" 2>/dev/null | grep -q true; }
cmd_watch() {
  local every=60 tmo=3600 o; OPTIND=1
  while getopts "i:t:" o; do case $o in i) every=$OPTARG;; t) tmo=$OPTARG;; *) exit 2;; esac; done; shift $((OPTIND-1))
  (( $# )) || die "watch: cần ít nhất một job"
  local deadline=$(( $(date +%s) + tmo )) k jd id st t age steps bc cage cmd v worst=0 code
  local -A left=()
  for k in "$@"; do jd=$(resolve "$k"); left[$jd]=1; done
  echo "watch: ${#left[@]} job, kiểm mỗi ${every}s (STALL ${STALL}s, lệnh ${CMD_STALL}s)"
  while :; do
    worst=0
    for jd in "${!left[@]}"; do
      id=$(basename "$jd"); use_session "$jd"; st=$(astate "$id"); t=$(tpath "$jd")
      age=-; steps=0; [[ -n $t ]] && { age=$(( $(date +%s) - $(stat -c %Y "$t") )); steps=$(wc -l <"$t"); }
      bc=$(watch_cmd "$jd"); cage=${bc%% *}; cmd=${bc#* }; [[ -z $bc ]] && { cage=0; cmd=""; }
      v=ok
      if [[ $st != gone ]] && quota_hit "$id"; then st=quota; fi
      case $st in
        quota) v=QUOTA;;
        blocked) v=BLOCKED;;
        gone) if watch_fin "$jd"; then v=DONE; else v=GONE; fi;;
        *) if [[ -n $cmd ]]; then (( cage > CMD_STALL )) && v=STALL
           elif subagent_busy "$id"; then v=ok
           elif [[ $st == idle || $st == done ]] && watch_fin "$jd"; then
             sleep 5; [[ $(astate "$id") == "$st" && -z $(watch_cmd "$jd") && $(wc -l <"$t") -eq $steps ]] && v=DONE
           elif [[ $age != - ]] && (( age > STALL )); then v=STALL; fi;;
      esac
      printf '%s  %-16s %-8s steps=%-4s tx=%ss%s  -> %s\n' "$(date +%H:%M:%S)" "$id" "$st" "$steps" "$age" \
        "$([[ -n $cmd ]] && printf "  cmd='%s' %ss" "$cmd" "$cage")" "$v"
      case $v in
        DONE) unset "left[$jd]";;
        STALL) (( worst < 2 )) && worst=2; echo "  ⚠ STALL $id: xem agy-hd logs $id 40 / agy-hd status $id; treo thật thì agy-hd interrupt $id rồi agy-hd prompt $id \"...\" (hoặc resume)";;
        GONE) (( worst < 4 )) && worst=4; echo "  ⚠ GONE $id: agy đã thoát giữa chừng. Mở lại: agy-hd resume $id";;
        BLOCKED) (( worst < 3 || worst == 4 )) && worst=3; echo "  ⚠ BLOCKED $id: agy đang hỏi/chờ duyệt. Báo người dùng: $(hcli) agent attach $id";;
        QUOTA) worst=6; echo "  ⚠ QUOTA $id: hết hạn mức Antigravity. Tắt và mở lại: agy-hd restart $id (rồi chạy lại watch)";;
      esac
    done
    if (( worst )); then case $worst in 2) code=STALL;; 3) code=BLOCKED;; 4) code=GONE;; 6) code=QUOTA;; esac; echo "WATCH=$code"; return $worst; fi
    (( ${#left[@]} == 0 )) && { echo "WATCH=DONE"; return 0; }
    (( $(date +%s) >= deadline )) && { echo "WATCH=TIMEOUT (${tmo}s; job vẫn chạy: ${!left[*]##*/})"; return 5; }
    sleep "$every"
  done
}

sub=${1:-}; shift || true
case $sub in
  start) cmd_start "$@";; prompt) cmd_prompt "$@";; status) cmd_status "$@";; wait) cmd_wait "$@";; watch) cmd_watch "$@";; restart) cmd_restart "$@";; tick) cmd_tick "$@";;
  logs) cmd_logs "$@";; result) cmd_result "$@";; summary) cmd_summary "$@";; access) cmd_access "$@";;
  interrupt) cmd_interrupt "$@";; resume) cmd_resume "$@";; close) cmd_close "$@";; list) cmd_list "$@";;
  wt-diff|wt-merge|wt-drop) cmd_wt "$sub" "$@";; gc) cmd_gc "$@";; fan) cmd_fan "$@";;
  init) cmd_init;; rename-space) cmd_rename_space "$@";; park) cmd_park "$@";; ps|ls|"") cmd_ps "$@";; open) cmd_open "$@";; sessions) cmd_sessions;; session-stop) cmd_session_stop "$@";;
  *) sed -n '2,36p' "$0"; exit 2;;
esac
