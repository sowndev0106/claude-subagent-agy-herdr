#!/usr/bin/env bash
# Chạy NHIỀU agy song song. Mỗi task = 1 file prompt trong thư mục tasks/.
#
# Usage: agy-fan.sh -i tasks_dir -o results_dir [-j 3] [-d workdir] [-t 900] [-R] [-W [-C]]
#   -C  (với -W) mang thay đổi chưa commit của repo vào mỗi worktree
#   -W  mỗi task chạy trong git worktree riêng (branch agy/<id>); gộp sau bằng agy-ctl.sh wt-merge
#   tasks_dir/*.md   mỗi file là prompt của 1 subagent (tên file = id task)
#   results_dir/<id>.out    response text
#   results_dir/<id>.json   JSON đầy đủ (conversation_id để resume)
#   results_dir/SUMMARY.tsv id status job tokens seconds branch (job dùng với agy-ctl.sh)
#
# Chạy bằng Bash run_in_background:true -> Claude Code được báo khi xong, không cần poll.
# exit 0 = mọi task SUCCESS; 1 = có task lỗi (xem SUMMARY.tsv).
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
tasks="" res="" jobs=3 wd="$PWD" tmo=900 ro=() wtf=0 cf=0
while getopts "i:o:j:d:t:RWC" o; do
  case $o in i) tasks=$OPTARG;; o) res=$OPTARG;; j) jobs=$OPTARG;; d) wd=$OPTARG;;
    t) tmo=$OPTARG;; R) ro=(-R);; W) wtf=1;; C) cf=1;; *) sed -n '2,14p' "$0"; exit 2;; esac
done
[[ -d $tasks && -n $res ]] || { sed -n '2,14p' "$0"; exit 2; }
(( jobs > 4 )) && jobs=4   # trần cứng: 4 agy cùng lúc
mkdir -p "$res"; : >"$res/SUMMARY.tsv"

run_one() {
  f=$1; id=$(basename "$f" .md); r=(); [[ -n ${ro_str:-} ]] && r=(-R); [[ ${wtf:-0} -eq 1 ]] && r+=(-W); [[ ${cf:-0} -eq 1 ]] && r+=(-C)
  "$here/agy-sub.sh" -n "$id" -f "$f" -d "$wd" -t "$tmo" -o "$res/$id.json" "${r[@]}" >"$res/$id.out" 2>"$res/$id.err"
  rc=$?
  if jq -e . "$res/$id.json" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(jq -r .status "$res/$id.json")" \
      "$(sed -n 's/^JOB=//p' "$res/$id.out" | head -1)" "$(jq -r .usage.total_tokens "$res/$id.json")" \
      "$(jq -r '.duration_seconds|floor' "$res/$id.json")" "$(sed -n 's/^BRANCH=//p' "$res/$id.out")" >>"$res/SUMMARY.tsv"
  else
    printf '%s\tFAILED(rc=%s)\t%s\t-\t-\t-\n' "$id" "$rc" "$(sed -n 's/^JOB=//p' "$res/$id.out" | head -1)" >>"$res/SUMMARY.tsv"
  fi
}
export -f run_one
export here res wd tmo wtf cf; export ro_str="${ro[*]:-}"  # mảng không export được

ls "$tasks"/*.md | xargs -P "$jobs" -I{} bash -c 'run_one "$1"' _ {}
sort -o "$res/SUMMARY.tsv" "$res/SUMMARY.tsv"
column -t -s$'\t' "$res/SUMMARY.tsv"
! grep -qv $'\tSUCCESS\t' "$res/SUMMARY.tsv"
