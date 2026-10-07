#!/usr/bin/env bash
# Test tự động cho agy-hd. Gọi agy thật (~5 phút). Dựng session herdr RIÊNG (headless) + repo tạm +
# registry riêng; KHÔNG đụng session default hay job thật. Tự dừng/xóa session và dọn khi xong.
# Usage: selftest-hd.sh [ro followup carry conflict interrupt fan gc ...]
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd); HD=$here/agy-hd.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/agyhd-selftest.XXXXXX"); SESS="agyhdtest$$"
export HERDR_SESSION=$SESS AGY_HD_JOBS=$T/jobs AGY_ID_DIR=$T/ids CLAUDE_CODE_SESSION_ID=selftest-0000-0000
herdr --session "$SESS" server >"$T/server.log" 2>&1 & SRV=$!
cleanup() { herdr session stop "$SESS" >/dev/null 2>&1; sleep 1; kill "$SRV" 2>/dev/null; herdr session delete "$SESS" >/dev/null 2>&1
            git -C "$T/repo" worktree prune 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
for _ in $(seq 20); do herdr workspace list >/dev/null 2>&1 && break; sleep 0.5; done
herdr workspace list >/dev/null 2>&1 || { echo "không dựng được session herdr $SESS"; exit 1; }

pass=0 fail=0; ok() { echo "  PASS $*"; pass=$((pass+1)); }; bad() { echo "  FAIL $*"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
WANT=("$@"); run() { [[ ${#WANT[@]} -eq 0 ]] && return 0; local t; for t in "${WANT[@]}"; do [[ $t == "$1" ]] && return 0; done; return 1; }
G="git -c user.name=t -c user.email=t@t"
mkrepo() { rm -rf "$T/repo" "$T/.agy-wt"; mkdir -p "$T/repo"; ( cd "$T/repo" && git init -q -b main \
  && printf 'def add(a, b):\n    return a - b\n' > a.py && printf 'x=1\n' > keep.txt && git add -A && $G commit -qm init ); }
mkdir -p "$T/ro"; "$here/../../claude-task-id/scripts/agy-id.sh" claim "Selftest agy" >/dev/null

if run ro; then echo "== ro: start chỉ đọc, ACCESS, result"
  out=$($HD start -n ro -R -d "$T/ro" -t 120 -p "Trả lời đúng một dòng: 2+3 bằng mấy?" 2>&1); rc=$?
  check "exit 0 + STATUS=DONE"      "[[ $rc -eq 0 ]] && grep -q '^STATUS=DONE' <<<\"\$out\""
  check "khối ACCESS có attach"     "grep -q 'herdr agent attach a-ro-' <<<\"\$out\""
  check "ACCESS có workspace"       "grep -q 'workspace  : w' <<<\"\$out\""
  check "ACCESS có transcript"      "grep -q 'transcript: /' <<<\"\$out\""
  check "trả lời chứa 5"            "grep -q 5 <<<\"\${out#*---}\""
  check "TRUST được báo"            "grep -q '^TRUST:' <<<\"\$out\""
  check "list thấy job"             "$HD list | grep -q a-ro-"
  check "workspace mang nhãn #số + tên" "herdr workspace list | jq -r '.result.workspaces[].label' | grep -q '^#100 Selftest agy'"
  check "tab mang tên job"           "herdr tab list --workspace \$(herdr workspace list | jq -r '.result.workspaces[0].workspace_id') | grep -q a-ro-"
fi

if run followup; then echo "== followup: prompt tiếp nhớ ngữ cảnh + logs + status"
  $HD start -n fu -R -d "$T/ro" -t 120 -p "Hãy nhớ số bí mật là 4242. Trả lời: OK." >/dev/null 2>&1
  out=$($HD prompt fu "Số bí mật là gì? Chỉ nói số." -t 120 2>&1)
  check "nhớ số 4242"               "grep -q 4242 <<<\"\$out\""
  check "status = idle|done"        "[[ \$($HD status fu | head -1) =~ STATE=(idle|done) ]]"
  check "logs live có nội dung"     "[[ -n \$($HD logs fu 20) ]]"
  check "logs --transcript có USER_INPUT" "[[ \$($HD logs fu 10 --transcript) == *USER_INPUT* ]]"
  check "result = câu trả lời cuối" "grep -q 4242 <<<\"\$($HD result fu)\""
fi

if run carry; then echo "== -W -C: mang thay đổi chưa commit, merge không commit"
  mkrepo; ( cd "$T/repo" && printf 'x=2\n' > keep.txt )
  out=$($HD start -n carry -W -C -d "$T/repo" -t 150 -p "Sửa a.py: add phải cộng (a+b). Chỉ sửa a.py. Đọc keep.txt nhưng KHÔNG sửa nó." 2>&1)
  wtd=$(sed -n 's/^  worktree   : \([^ ]*\) .*/\1/p' <<<"$out" | head -1)
  check "STATUS=DONE"                "grep -q '^STATUS=DONE' <<<\"\$out\""
  check "worktree thấy keep.txt bẩn" "grep -q 'x=2' '$wtd/keep.txt'"
  check "diffstat chỉ a.py"          "grep -q 'a.py' <<<\"\$out\" && ! grep -q 'keep.txt |' <<<\"\$out\""
  $HD wt-merge carry >/dev/null 2>&1
  check "a.py đã sửa ở main"         "grep -q 'a + b' '$T/repo/a.py'"
  check "keep.txt bẩn chưa commit"   "grep -q 'x=2' '$T/repo/keep.txt' && git -C '$T/repo' status --porcelain | grep -q keep.txt"
  check "không có commit mới"        "[[ \$(git -C '$T/repo' rev-list --count HEAD) -eq 1 ]]"
  check "tab + worktree đã dọn"     "[[ ! -d '$wtd' ]] && ! herdr agent list | jq -r '.result.agents[].name // empty' | grep -q a-carry-"
fi

if run conflict; then echo "== merge conflict (không -C)"
  mkrepo
  $HD start -n conf -W -d "$T/repo" -t 150 -p "Sửa a.py: add phải cộng (a+b). Chỉ sửa a.py." >/dev/null 2>&1
  ( cd "$T/repo" && printf 'def add(a, b):\n    return b + a\n' > a.py && $G commit -qam "main sửa khác" )
  out=$($HD wt-merge conf 2>&1); rc=$?
  check "exit 1 + CONFLICT"          "[[ $rc -eq 1 ]] && grep -q CONFLICT <<<\"\$out\""
  git -C "$T/repo" merge --abort 2>/dev/null
  check "wt-drop dọn"                "$HD wt-drop conf >/dev/null 2>&1; ! git -C '$T/repo' branch | grep -q agy/"
fi

if run interrupt; then echo "== interrupt (dọn lệnh con) + resume"
  $HD start -A -n slow -R -d "$T/ro" -p "Chạy đúng lệnh shell: sleep 313. Sau đó báo xong." >/dev/null 2>&1
  for _ in $(seq 40); do pgrep -fx 'sleep 313' >/dev/null && break; sleep 1; done
  check "agy đang chạy lệnh dài"     "pgrep -fx 'sleep 313' >/dev/null"
  check "status = working"           "[[ \$($HD status slow | head -1) == *STATE=working* ]]"
  out=$($HD interrupt slow 2>&1)
  check "interrupt báo đã dừng"      "grep -qE 'đã interrupt|đã huỷ lượt' <<<\"\$out\""
  sleep 2; check "sleep con đã chết" "! pgrep -fx 'sleep 313' >/dev/null"
  check "status = idle|done|gone"    "[[ \$($HD status slow | head -1) =~ STATE=(idle|done|gone) ]]"
  [[ $($HD status slow | head -1) == *STATE=gone* ]] && $HD resume slow >/dev/null 2>&1
  out=$($HD prompt slow "Lệnh shell nào bạn vừa được yêu cầu chạy? Trả lời ngắn." -t 120 2>&1)
  check "còn ngữ cảnh sau interrupt"  "grep -q 313 <<<\"\$out\""
fi

if run fan; then echo "== fan 3 task -j 2 -W, ACCESS.txt sớm"
  mkrepo; mkdir -p "$T/tasks"
  for i in 1 2 3; do printf 'Tạo file f%s.txt chứa đúng ký tự %s (kèm xuống dòng cuối). Chỉ tạo f%s.txt, xong thì trả lời 1 dòng.\n' $i $i $i >"$T/tasks/t$i.md"; done
  $HD fan -i "$T/tasks" -o "$T/res" -j 2 -d "$T/repo" -W -t 150 >"$T/fan.out" 2>&1 &
  fp=$!; early=0; for _ in $(seq 60); do [[ $(grep -c '^== ' "$T/res/ACCESS.txt" 2>/dev/null) -ge 1 ]] && { early=1; break; }; sleep 1; done
  check "ACCESS.txt có sớm khi đang chạy" "[[ $early -eq 1 ]] && kill -0 $fp 2>/dev/null"
  wait $fp
  check "3 dòng SUMMARY, đều DONE"   "[[ \$(wc -l <'$T/res/SUMMARY.tsv') -eq 3 && \$(grep -c DONE '$T/res/SUMMARY.tsv') -eq 3 ]]"
  check "mỗi subagent 1 tab (không chia màn hình)" "ws=\$(herdr workspace list | jq -r '.result.workspaces[0].workspace_id'); tc=\$(herdr tab list --workspace \$ws | jq '.result.tabs|length'); pc=\$(herdr workspace get \$ws | jq '.result.workspace.pane_count'); [[ \$tc -ge 3 && \$tc -eq \$pc ]]"
  check "3 tab riêng, cùng 1 workspace" "[[ \$(cut -f4 '$T/res/SUMMARY.tsv' | sort -u | wc -l) -eq 3 && \$(cut -f4 '$T/res/SUMMARY.tsv' | cut -d: -f1 | sort -u | wc -l) -eq 1 ]]"
  for i in 1 2 3; do $HD wt-merge "t$i" >/dev/null 2>&1; done
  check "3 file đã merge"            "[[ \$(cat '$T'/repo/f?.txt 2>/dev/null | tr -d '\n') == 123 ]]"
fi

if run gc; then echo "== gc"
  n=$(ls "$AGY_HD_JOBS" | wc -l)
  check "gc 0 không -y: chỉ liệt kê"  "$HD gc 0 >/dev/null 2>&1; [[ \$(ls '$AGY_HD_JOBS' | wc -l) -eq $n ]]"
  $HD gc 0 -y >/dev/null 2>&1
  check "gc 0 -y: xóa job xong"       "[[ \$(ls '$AGY_HD_JOBS' | wc -l) -lt $n || $n -eq 0 ]]"
fi

echo; echo "PASS=$pass FAIL=$fail"; [[ $fail -eq 0 ]]
