#!/usr/bin/env bash
# Chạy agy (Antigravity CLI) như một subagent: 1 prompt vào, kết quả gọn ra.
# LUÔN bypass permission + gemini-3.8-flash-high. Không có cờ để tắt, cố ý.
#
# Usage:
#   agy-sub.sh -p "prompt"            # hoặc -f prompt.md, hoặc đọc stdin
#             [-n name]               # tên job (dễ nhớ; id = name-HHMMSS)
#             [-d workdir]            # cwd của agy (mặc định: $PWD)
#             [-u profile]            # account agy-p (skill agy-accounts); không có: $AGY_PROFILE, không thì agy-p pick
#             [-W]                    # chạy trong git worktree riêng (branch agy/<id>), tự commit
#             [-C]                    # (cần -W) mang thay đổi CHƯA commit của repo vào worktree
#             [-S]                    # chạy agy với --sandbox (hạn chế terminal)
#             [-r conversation_id]    # tiếp tục hội thoại trước
#             [-s schema.json|'{...}']# ép structured output
#             [-a extra_dir]          # --add-dir (lặp được)
#             [-o out.json]           # nơi copy JSON kết quả (mặc định: <jobdir>/result.json)
#             [-t seconds]            # timeout (mặc định 600)
#             [-R]                    # read-only: ngầm bật --sandbox + lệnh "không sửa file" + so sánh cây git trước/sau (RO_VIOLATION, exit 1)
#
# Mỗi job có thư mục $AGY_JOBS/<id>/ (mặc định ~/.cache/agy-jobs): meta.env, pid,
# events.jsonl (stream trực tiếp), result.json. Điều khiển bằng agy-ctl.sh
# (list/status/tail/history/summary/stop/wt-*).
#
# stdout: JOB=<id>, CONVERSATION_ID, STATUS, [BRANCH/WORKTREE/DIFFSTAT], `---`, response.
# exit:   0 = SUCCESS, 1 = agy lỗi / status khác SUCCESS, 124 = timeout, 130 = bị stop.
set -uo pipefail

MODEL="gemini-3.8-flash-high"
JOBS="${AGY_JOBS:-$HOME/.cache/agy-jobs}"
prompt="" pfile="" workdir="$PWD" conv="" schema="" out="" tmo=600 ro=0 wt=0 carry=0 sbx=0 name="job" acct=""
adddirs=()
while getopts "p:f:n:d:r:s:a:o:t:u:RWCS" o; do
  case $o in
    p) prompt=$OPTARG ;; f) pfile=$OPTARG ;; n) name=${OPTARG//[^A-Za-z0-9_.-]/_} ;;
    d) workdir=$OPTARG ;; r) conv=$OPTARG ;; s) schema=$OPTARG ;; a) adddirs+=(--add-dir "$OPTARG") ;;
    o) out=$OPTARG ;; t) tmo=$OPTARG ;; u) acct=$OPTARG ;; R) ro=1 ;; W) wt=1 ;; C) carry=1 ;; S) sbx=1 ;;
    *) sed -n '2,28p' "$0"; exit 2 ;;
  esac
done

[[ -n $pfile ]] && prompt=$(<"$pfile")
[[ -z $prompt && ! -t 0 ]] && prompt=$(cat)
[[ -z $prompt ]] && { echo "agy-sub: thiếu prompt (-p, -f hoặc stdin)" >&2; exit 2; }
command -v agy >/dev/null || { echo "agy-sub: không thấy agy trong PATH" >&2; exit 2; }
# Nhiều account (agy-p): chọn profile trong khoá, chia tải theo số job agy-sub đang chạy trên từng profile.
AGYP=$(command -v agy-p 2>/dev/null || echo "$HOME/.local/bin/agy-p"); prof="" pemail=""
if [[ -x $AGYP ]]; then
  mkdir -p "$JOBS"; exec 8>"$JOBS/.pick.lock"; flock 8
  prof=${acct:-${AGY_PROFILE:-}}
  if [[ -z $prof ]]; then
    loads=(); for m in "$JOBS"/*/meta.env; do [[ -f $m ]] || continue; p=$(sed -n "s/^PROFILE=//p" "$m"); pd=$(dirname "$m")
      [[ -n $p && -f $pd/pid && ! -f $pd/done ]] && kill -0 "$(<"$pd/pid")" 2>/dev/null && loads+=(--load "$p=1"); done
    prof=$("$AGYP" pick "${loads[@]}" 2>/dev/null) || prof=$("$AGYP" default | awk '{print $1}')
  fi
  "$AGYP" env "$prof" >/dev/null || { echo "agy-sub: profile '$prof' không dùng được (agy-p ls)" >&2; exit 2; }
  pemail=$("$AGYP" email "$prof")
fi
[[ -d $workdir ]] || { echo "agy-sub: workdir không tồn tại: $workdir" >&2; exit 2; }
workdir=$(cd "$workdir" && pwd)

id="$name-$(date +%H%M%S)-$RANDOM"
jd="$JOBS/$id"; mkdir -p "$jd"
branch="" wtdir="" repo="" base=""
[[ $carry -eq 1 && $wt -ne 1 ]] && { echo "agy-sub: -C cần -W" >&2; exit 2; }

if [[ $wt -eq 1 ]]; then
  repo=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "agy-sub: -W cần workdir là git repo" >&2; exit 2; }
  rel=$(git -C "$workdir" rev-parse --show-prefix)
  branch="agy/$id"; wtdir="$repo/../.agy-wt/$(basename "$repo")-$id"
  mkdir -p "$(dirname "$wtdir")"
  git -C "$repo" worktree add -q -b "$branch" "$wtdir" HEAD || { echo "agy-sub: tạo worktree thất bại" >&2; exit 2; }
  wtdir=$(cd "$wtdir" && pwd); workdir="$wtdir/$rel"
  base=$(git -C "$wtdir" rev-parse HEAD)
  if [[ -n $(git -C "$repo" status --porcelain) ]]; then
    if [[ $carry -eq 1 ]]; then
      # Thay đổi tracked (kể cả binary) + file untracked (không bị ignore) sang worktree, rồi chốt thành commit nền.
      git -C "$repo" diff --binary HEAD | git -C "$wtdir" apply --whitespace=nowarn - || { echo "agy-sub: carry diff thất bại" >&2; exit 2; }
      git -C "$repo" ls-files -z -o --exclude-standard | while IFS= read -r -d '' f; do mkdir -p "$wtdir/$(dirname "$f")"; cp -a "$repo/$f" "$wtdir/$f"; done
      git -C "$wtdir" add -A
      git -C "$wtdir" -c user.name=agy -c user.email=agy@local commit -q -m "carry: thay đổi chưa commit của repo trước job $id" && base=$(git -C "$wtdir" rev-parse HEAD)
    else
      echo "WARN: repo có thay đổi chưa commit, worktree KHÔNG thấy chúng (chỉ thấy HEAD). Dùng -C để mang theo." >&2
    fi
  fi
fi

guard="Ràng buộc: không git push/commit/reset/checkout/branch, không xóa file ngoài phạm vi được giao, không truy cập mạng nội bộ 10.0.0.0/8, không bật process nền (nohup/setsid)."
[[ $ro -eq 1 ]] && sbx=1   # -R: guard trong prompt không chặn được gì, nên bắt buộc thêm --sandbox
[[ $sbx -eq 1 ]] && args_extra=(--sandbox) || args_extra=()
# -R: chụp trạng thái cây làm việc trước/sau; khác nhau = agy đã vi phạm chế độ chỉ đọc (kiểm tra thật, không dựa vào prompt)
tree_sig() { { git -C "$workdir" status --porcelain; git -C "$workdir" diff HEAD; } 2>/dev/null | md5sum; }
[[ $ro -eq 1 ]] && sig_before=$(tree_sig)
[[ $wt -eq 1 ]] && guard="$guard Bạn đang ở git worktree riêng: chỉ sửa file trong thư mục hiện tại, đừng cd ra ngoài."
[[ $ro -eq 1 ]] && guard="$guard CHẾ ĐỘ CHỈ ĐỌC: tuyệt đối không tạo/sửa/xóa file, chỉ đọc và báo cáo."
prompt="$prompt

$guard"

args=(-p "$prompt" --model "$MODEL" --effort high --dangerously-skip-permissions
      --output-format stream-json "${args_extra[@]}" "${adddirs[@]}")
[[ -n $conv ]] && args+=(--conversation "$conv")
[[ -n $schema ]] && args+=(--json-schema "$schema")

cat >"$jd/meta.env" <<EOF
ID=$id
NAME=$name
WORKDIR=$workdir
REPO=$repo
WORKTREE=$wtdir
BRANCH=$branch
BASE=$base
CARRY=$carry
STARTED=$(date +%s)
TIMEOUT=$tmo
RO=$ro
PROFILE=$prof
PROFILE_EMAIL=$pemail
PROMPT_HEAD=$(printf '%s' "$prompt" | head -c 120 | tr '\n"$`\\' ' ')
EOF
echo "JOB=$id" >&2   # in sớm để người chạy nền biết id ngay
[[ -n $prof ]] && echo "ACCOUNT=$prof ($pemail)" >&2

killtree() { local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done; kill -TERM "$p" 2>/dev/null; }

# Chạy nền để lấy PID rồi wait: stop = kill cây tiến trình theo PID này.
# Timeout bằng watchdog + killtree (GNU timeout chỉ kill agy, lệnh con của agy sống sót thành mồ côi).
if [[ -n $prof ]]; then ( cd "$workdir" && exec "$AGYP" "$prof" "${args[@]}" </dev/null >"$jd/events.jsonl" 2>"$jd/err" ) &
else ( cd "$workdir" && exec agy "${args[@]}" </dev/null >"$jd/events.jsonl" 2>"$jd/err" ) & fi
pid=$!; echo "$pid" >"$jd/pid"
[[ -n $prof ]] && flock -u 8
( sleep "$tmo"; touch "$jd/timedout"; killtree "$pid"; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
wd=$!
wait "$pid"; rc=$?
killtree "$wd"; wait "$wd" 2>/dev/null
rm -f "$jd/pid"

result=$(jq -c 'select(.event=="result").result' "$jd/events.jsonl" 2>/dev/null | tail -1)
cid=$(jq -r 'select(.event=="init").conversation_id' "$jd/events.jsonl" 2>/dev/null | head -1)
[[ -n $result ]] && printf '%s\n' "$result" >"$jd/result.json"
[[ -n $out && -n $result ]] && cp "$jd/result.json" "$out"

state=""
if [[ -f $jd/stopped ]]; then state=STOPPED; rc=130
elif [[ -f $jd/timedout ]]; then state=TIMEOUT; rc=124
elif [[ -z $result ]]; then state=ERROR
else state=$(jq -r '.status' "$jd/result.json"); fi
ro_violation=0
if [[ $ro -eq 1 && $(tree_sig) != "$sig_before" ]]; then ro_violation=1; state="RO_VIOLATION"; fi
echo "$state" >"$jd/state"

# Worktree: wrapper (không phải agy) commit kết quả lên branch agy/<id>.
diffstat=""
if [[ -n $wtdir ]]; then
  if [[ -n $(git -C "$wtdir" status --porcelain) ]]; then
    git -C "$wtdir" add -A
    git -C "$wtdir" -c user.name=agy -c user.email=agy@local commit -q -m "agy($name): $id" || true
  fi
  diffstat=$(git -C "$repo" diff --stat "$base" "$branch" 2>/dev/null | tail -20)
fi

echo "JOB=$id"
echo "CONVERSATION_ID=${cid:--}"
echo "STATUS=$state"
if [[ -n $result ]]; then
  echo "TOKENS=$(jq -r '.usage.total_tokens' "$jd/result.json") DURATION=$(jq -r '.duration_seconds|floor' "$jd/result.json")s"
fi
echo "RAW=$jd/result.json"
[[ -n $wtdir ]] && { echo "BRANCH=$branch"; echo "WORKTREE=$wtdir"; echo "DIFFSTAT:"; echo "${diffstat:-  (không có thay đổi)}"; }
echo "---"
if [[ -n $result ]]; then
  # agy giữ schema của lượt trước khi resume: chỉ coi là structured nếu lần này có -s
  if [[ -n $schema ]] && jq -e 'has("structured_output")' "$jd/result.json" >/dev/null; then jq '.structured_output' "$jd/result.json"
  else jq -r '.response' "$jd/result.json"; fi
else
  echo "(không có kết quả; xem $jd/err và $jd/events.jsonl)"; tail -5 "$jd/err" 2>/dev/null
fi
[[ $ro_violation -eq 1 ]] && echo "⚠ RO_VIOLATION: cây làm việc đổi trong lúc chạy -R. Xem: git -C $workdir status; hoàn tác trước khi tin kết quả." >&2
[[ $state == SUCCESS ]] && exit 0
[[ $state == TIMEOUT ]] && exit 124
[[ $state == STOPPED ]] && exit 130
exit 1
