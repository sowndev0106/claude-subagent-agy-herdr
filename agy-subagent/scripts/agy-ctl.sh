#!/usr/bin/env bash
# Điều khiển các job agy: xem trạng thái, interrupt, đọc history/summary, quản lý worktree.
#
#   agy-ctl.sh list                    mọi job (mới nhất cuối): state, tuổi, tên, branch
#   agy-ctl.sh status <job>            đang chạy hay xong; số step; bước/ chữ gần nhất
#   agy-ctl.sh tail <job> [n=15]       n event gần nhất, dạng rút gọn (theo dõi tiến độ)
#   agy-ctl.sh history <job|cid> [n]   transcript đầy đủ của agy (user/model/tool), cắt gọn
#   agy-ctl.sh summary <job>           kết quả cuối + token + (worktree) diffstat
#   agy-ctl.sh stop <job>|all -y       INTERRUPT: kill cả cây tiến trình, đánh dấu STOPPED (all cần -y, vì registry dùng chung mọi phiên)
#   agy-ctl.sh wait <job> [sec=600]    chờ job xong (poll 3s), in state
#   agy-ctl.sh gc [days=3] [-y]        dọn job xong cũ hơn N ngày + worktree không có thay đổi (mặc định chỉ liệt kê)
#   agy-ctl.sh wt-list                 worktree agy/* đang tồn tại
#   agy-ctl.sh wt-diff <job>           diff đầy đủ branch agy/<id> so với nơi tách ra
#   agy-ctl.sh wt-merge <job>          merge agy/<id> vào repo rồi dọn (job -C: áp diff vào cây làm việc, không commit)
#   agy-ctl.sh wt-drop <job>           bỏ worktree + branch (không merge)
#
# <job> là id đầy đủ hoặc tiền tố/tên; khớp nhiều thì lấy job mới nhất.
# Nạp lớp tương thích (macOS/BSD/busybox, bash >= 4.4): tìm thư mục thật của script qua symlink mà không cần readlink -f
_s=$0; while [[ -L $_s ]]; do _d=$(cd -P "$(dirname "$_s")" && pwd); _s=$(readlink "$_s"); [[ $_s == /* ]] || _s=$_d/$_s; done
_HERE=$(cd -P "$(dirname "$_s")" && pwd)
for _c in "$_HERE/compat.sh" "$_HERE/../../agy-subagent/scripts/compat.sh"; do [[ -f $_c ]] && { source "$_c"; break; }; done
declare -F agy_require >/dev/null && agy_require jq   # thiếu thì tự sửa (setup.sh fix -y)
set -uo pipefail
JOBS="${AGY_JOBS:-$HOME/.cache/agy-jobs}"
BRAIN="$HOME/.gemini/antigravity-cli/brain"
mkdir -p "$JOBS"

die() { echo "agy-ctl: $*" >&2; exit 2; }
resolve() {  # in: tiền tố; out: thư mục job
  local m; m=$(ls -1dt "$JOBS/$1"* 2>/dev/null | head -1)
  [[ -n $m ]] || m=$(ls -1dt "$JOBS"/*"$1"* 2>/dev/null | head -1)
  [[ -n $m ]] || die "không tìm thấy job '$1' (agy-ctl.sh list)"
  echo "$m"
}
meta() { sed -n "s/^$2=//p" "$1/meta.env" | head -1; }   # không source: PROMPT_HEAD có ký tự lạ
alive() { [[ -f $1/pid ]] && kill -0 "$(<"$1/pid")" 2>/dev/null; }
jstate() {
  if alive "$1"; then echo RUNNING
  elif [[ -f $1/state ]]; then cat "$1/state"
  else echo DEAD; fi   # tiến trình chết mà không ghi state (máy tắt, kill -9)
}
age() { local s; s=$(( $(date +%s) - $(meta "$1" STARTED) )); printf '%dm%02ds' $((s/60)) $((s%60)); }
idle() { local m; m=$(file_mtime "$1/events.jsonl" 2>/dev/null) || m=$(meta "$1" STARTED); echo $(( $(date +%s) - m )); }
STALL=${AGY_STALL_SEC:-180}
cid_of() { jq -r 'select(.event=="init").conversation_id' "$1/events.jsonl" 2>/dev/null | head -1; }
killtree() {
  local p=$1 c
  for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done
  kill -TERM "$p" 2>/dev/null
}

cmd=${1:-}; shift || true
case $cmd in
list)
  for d in $(ls -1dt "$JOBS"/*/ 2>/dev/null | tac); do d=${d%/}
    st=$(jstate "$d"); [[ $st == RUNNING && $(idle "$d") -gt $STALL ]] && st=STALL?
    printf '%-9s %-7s %s  %s  %s\n' "$st" "$(age "$d")" "$(basename "$d")" "$(meta "$d" BRANCH)" "$(p=$(meta "$d" PROMPT_HEAD); echo "${p:0:50}")"
  done ;;
status)
  d=$(resolve "${1:?job}"); ev=$d/events.jsonl
  echo "JOB=$(basename "$d")  STATE=$(jstate "$d")  AGE=$(age "$d")  CID=$(cid_of "$d")"
  echo "WORKDIR=$(meta "$d" WORKDIR)  BRANCH=$(meta "$d" BRANCH)"
  if alive "$d"; then i=$(idle "$d"); echo "IDLE=${i}s$([[ $i -gt $STALL ]] && echo '  ⚠ STALL: không có event mới > '"$STALL"'s (xem history, cân nhắc stop)')"; fi
  if [[ -s $ev ]]; then
    echo "STEPS=$(jq -r 'select(.event=="step_update").step_update.step_index' "$ev" | sort -un | tail -1)"
    echo "LAST_STEP: $(jq -r 'select(.event=="step_update").step_update|"#\(.step_index) \(.step_type) \(.state)"' "$ev" | tail -1)"
    echo "LAST_TEXT: $(jq -r 'select(.event=="step_update").step_update.text_delta // empty' "$ev" | tr -d '\n' | tail -c 300)"
  else echo "(chưa có event; agy đang khởi động)"; fi
  [[ -s $d/err ]] && { echo "STDERR:"; tail -3 "$d/err"; } ;;
tail)
  d=$(resolve "${1:?job}"); n=${2:-15}
  jq -r 'select(.event=="step_update").step_update
    | "#\(.step_index) \(.step_type) \(.state)" + (if .text_delta then "  " + (.text_delta|gsub("\n";" ")|.[0:160]) else "" end)' \
    "$d/events.jsonl" | tail -n "$n" ;;
history)
  k=${1:?job|cid}; n=${2:-40}
  jd=$(ls -1dt "$JOBS/$k"* "$JOBS"/*"$k"* 2>/dev/null | head -1)
  if [[ -n $jd ]]; then cid=$(cid_of "$jd"); else cid=$k; fi
  t="$BRAIN/$cid/.system_generated/logs/transcript.jsonl"
  [[ -f $t ]] || die "không có transcript cho conversation '$cid'"
  jq -r '"#\(.step_index) [\(.source)/\(.type)] \(.status // "")  \((.content // (.tool_calls|tostring) // "")|gsub("\n";" ")|.[0:220])"' "$t" | tail -n "$n" ;;
summary)
  d=$(resolve "${1:?job}"); echo "JOB=$(basename "$d")  STATE=$(jstate "$d")"
  if [[ -f $d/result.json ]]; then
    jq -r '"TOKENS=\(.usage.total_tokens) TURNS=\(.num_turns) DURATION=\(.duration_seconds|floor)s"' "$d/result.json"
    echo "---"; jq -r '.response' "$d/result.json"
  else echo "(chưa có result — job ${1} chưa xong hoặc lỗi; dùng status/tail/history)"; fi
  b=$(meta "$d" BRANCH); r=$(meta "$d" REPO)
  [[ -n $b ]] && { echo "--- DIFFSTAT $b"; git -C "$r" diff --stat "HEAD...$b" 2>/dev/null; } ;;
stop)
  k=${1:?job|all}; targets=()
  if [[ $k == all ]]; then for d in "$JOBS"/*/; do alive "${d%/}" && targets+=("${d%/}"); done
    # Registry dùng chung giữa mọi phiên Claude Code: không kill hàng loạt khi chưa xác nhận.
    if [[ ${2:-} != -y ]]; then echo "Sẽ kill ${#targets[@]} job (có thể của phiên khác):"; for d in "${targets[@]}"; do echo "  $(basename "$d")  $(meta "$d" WORKDIR)"; done; echo "Chạy lại: agy-ctl.sh stop all -y"; exit 1; fi
  else targets+=("$(resolve "$k")"); fi
  [[ ${#targets[@]} -eq 0 ]] && { echo "không có job nào đang chạy"; exit 0; }
  for d in "${targets[@]}"; do
    alive "$d" || { echo "$(basename "$d"): không chạy"; continue; }
    touch "$d/stopped"; killtree "$(<"$d/pid")"; sleep 1
    alive "$d" && killtree "$(<"$d/pid")" && kill -KILL "$(<"$d/pid")" 2>/dev/null
    echo "$(basename "$d"): đã interrupt (resume được bằng agy-sub.sh -r $(cid_of "$d"))"
  done ;;
wait)
  d=$(resolve "${1:?job}"); lim=${2:-600}; t0=$(date +%s)
  while alive "$d"; do (( $(date +%s) - t0 > lim )) && { echo "RUNNING (hết ${lim}s chờ)"; exit 1; }; sleep 3; done
  jstate "$d" ;;
wt-list)
  for d in "$JOBS"/*/; do d=${d%/}; w=$(meta "$d" WORKTREE); [[ -n $w && -d $w ]] && echo "$(jstate "$d")  $(meta "$d" BRANCH)  $w"; done ;;
wt-diff)
  d=$(resolve "${1:?job}"); git -C "$(meta "$d" REPO)" diff "$(meta "$d" BASE)" "$(meta "$d" BRANCH)" ;;
wt-merge)
  d=$(resolve "${1:?job}"); r=$(meta "$d" REPO); b=$(meta "$d" BRANCH); w=$(meta "$d" WORKTREE); base=$(meta "$d" BASE)
  [[ -n $b ]] || die "job này không chạy với -W"
  [[ $(jstate "$d") == RUNNING ]] && die "job còn đang chạy"
  if [[ $(meta "$d" CARRY) == 1 ]]; then
    # Job -C: nhánh chứa commit "carry" (thay đổi chưa commit của repo), merge sẽ đè lên cây bẩn.
    # Chỉ áp phần agy làm thêm (BASE..branch) vào cây làm việc, để nguyên dạng chưa commit.
    git -C "$r" diff --binary "$base" "$b" | git -C "$r" apply --3way --whitespace=nowarn - \
      || { echo "CONFLICT khi áp diff vào cây làm việc của $r (xem git status, file *.rej / marker). Worktree giữ nguyên: $w"; exit 1; }
    echo "đã áp thay đổi của agy vào cây làm việc (chưa commit)"
  else
    git -C "$r" merge --no-ff -m "Merge $b (agy subagent)" "$b" || { echo "CONFLICT: giải quyết tay trong $r rồi commit, hoặc git merge --abort"; exit 1; }
  fi
  git -C "$r" worktree remove --force "$w" && git -C "$r" branch -D "$b" >/dev/null && echo "đã dọn $b" ;;
wt-drop)
  d=$(resolve "${1:?job}"); r=$(meta "$d" REPO); b=$(meta "$d" BRANCH); w=$(meta "$d" WORKTREE)
  [[ -n $b ]] || die "job này không chạy với -W"
  git -C "$r" worktree remove --force "$w"; git -C "$r" branch -D "$b"; echo "đã bỏ $b" ;;
gc)
  days=3; yes=0; for a in "$@"; do [[ $a == -y ]] && yes=1 || days=$a; done
  now=$(date +%s); keep=0; del=0
  for d in "$JOBS"/*/; do d=${d%/}; alive "$d" && continue
    st=$(jstate "$d"); [[ $st == DEAD || $st == RUNNING ]] && [[ -f $d/pid ]] && continue
    (( now - $(meta "$d" STARTED) < days*86400 )) && continue
    b=$(meta "$d" BRANCH); w=$(meta "$d" WORKTREE); r=$(meta "$d" REPO)
    if [[ -n $b && -d $w ]]; then
      # worktree còn tồn tại: chỉ dọn khi agy không để lại thay đổi nào (branch == BASE) hoặc đã bị bỏ
      if [[ $(git -C "$r" rev-parse "$b" 2>/dev/null) != $(meta "$d" BASE) ]]; then
        echo "GIỮ   $(basename "$d")  ($b có thay đổi chưa merge: wt-merge hoặc wt-drop)"; keep=$((keep+1)); continue; fi
      echo "DỌN   $(basename "$d")  + worktree rỗng $w"
      [[ $yes -eq 1 ]] && { git -C "$r" worktree remove --force "$w"; git -C "$r" branch -D "$b" >/dev/null; }
    else echo "DỌN   $(basename "$d")  ($st)"; fi
    del=$((del+1)); [[ $yes -eq 1 ]] && rm -rf "$d"
  done
  for r in $(for d in "$JOBS"/*/; do meta "${d%/}" REPO; done | sort -u); do [[ -n $r && -d $r ]] && git -C "$r" worktree prune; done
  echo "$del job dọn$([[ $yes -eq 0 ]] && echo ' (chưa xóa, thêm -y)'), $keep job giữ lại" ;;
*) sed -n '2,21p' "$0"; exit 2 ;;
esac
