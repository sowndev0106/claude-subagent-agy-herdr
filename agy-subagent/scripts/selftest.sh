#!/usr/bin/env bash
# Test tự động cho agy-sub / agy-ctl / agy-fan. Gọi agy thật (~5 phút, ~600k token).
# Dùng registry riêng + repo tạm, không đụng job/ repo thật. Usage: selftest.sh [tên-test ...]
# Test: ro schema resume carry conflict stop timeout fan gc
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SUB=$here/agy-sub.sh CTL=$here/agy-ctl.sh FAN=$here/agy-fan.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/agy-selftest.XXXXXX"); export AGY_JOBS=$T/jobs
pass=0 fail=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
want() { [[ $# -eq 0 ]] && return 0; local t; for t in "${WANT[@]}"; do [[ $t == "$1" ]] && return 0; done; return 1; }
WANT=("$@"); run() { [[ ${#WANT[@]} -eq 0 ]] || want "$1"; }
G="git -c user.name=t -c user.email=t@t"
mkrepo() { rm -rf "$T/repo" "$T/.agy-wt"; mkdir -p "$T/repo"; ( cd "$T/repo" && git init -q -b main \
  && printf 'def add(a, b):\n    return a - b\n' > a.py && printf 'x=1\n' > keep.txt && git add -A && $G commit -qm init ); }
trap 'rm -rf "$T"' EXIT

if run ro; then echo "== ro: chỉ đọc + output"
  out=$($SUB -R -n ro -d "$T" -p "Reply with exactly: PONG" 2>/dev/null); rc=$?
  check "exit 0"        "[[ $rc -eq 0 ]]"
  check "STATUS=SUCCESS" "grep -q '^STATUS=SUCCESS' <<<\"\$out\""
  check "response PONG"  "grep -q PONG <<<\"\$out\""
fi

if run schema; then echo "== schema"
  out=$($SUB -R -n sch -d "$T" -s '{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}' -p "n = 7" 2>/dev/null)
  check "structured_output JSON" "jq -e '.n==7' >/dev/null <<<\"\${out#*---}\""
fi

if run resume; then echo "== resume (không rò schema cũ)"
  $SUB -R -n res1 -d "$T" -s '{"type":"object","properties":{"c":{"type":"string"}},"required":["c"]}' -p "c = blue" >/dev/null 2>&1
  cid=$($CTL status res1 | sed -n 's/.*CID=//p')
  out=$($SUB -R -n res2 -d "$T" -r "$cid" -p "What was c? Answer in one word, plain text." 2>/dev/null)
  check "nhớ ngữ cảnh"       "grep -qi blue <<<\"\$out\""
  check "không in JSON cũ"   "! jq -e . >/dev/null 2>&1 <<<\"\${out#*---}\""
  check "history theo cid"   "$CTL history $cid 3 | grep -q USER_INPUT"
fi

if run carry; then echo "== -W -C: mang thay đổi chưa commit, merge không commit"
  mkrepo; ( cd "$T/repo" && printf 'x=2\n' > keep.txt && printf 'new\n' > untracked.txt )
  out=$($SUB -W -C -n carry -d "$T/repo" -p "Sửa a.py: add phải cộng (a+b). Đọc keep.txt và untracked.txt nhưng KHÔNG sửa. Chỉ sửa a.py." 2>/dev/null)
  wtd=$(sed -n 's/^WORKTREE=//p' <<<"$out")
  check "worktree thấy keep.txt bẩn"     "grep -q 'x=2' '$wtd/keep.txt'"
  check "worktree thấy file untracked"   "[[ -f '$wtd/untracked.txt' ]]"
  check "diffstat chỉ có a.py"           "[[ \$(git -C '$T/repo' diff --name-only \$(sed -n 's/^BASE=//p' '$AGY_JOBS'/carry-*/meta.env) \$(sed -n 's/^BRANCH=//p' <<<\"\$out\")) == a.py ]]"
  $CTL wt-merge carry >/dev/null 2>&1
  check "a.py đã sửa ở main"             "grep -q 'a + b' '$T/repo/a.py'"
  check "keep.txt vẫn là bản bẩn chưa commit" "grep -q 'x=2' '$T/repo/keep.txt' && git -C '$T/repo' status --porcelain | grep -q 'keep.txt'"
  check "không có commit mới ở main"     "[[ \$(git -C '$T/repo' rev-list --count HEAD) -eq 1 ]]"
  check "worktree/branch đã dọn"         "[[ ! -d '$wtd' ]] && ! git -C '$T/repo' branch | grep -q agy/"
fi

if run conflict; then echo "== merge conflict"
  mkrepo
  $SUB -W -n conf -d "$T/repo" -p "Sửa a.py: add phải cộng (a+b). Chỉ sửa a.py." >/dev/null 2>&1
  ( cd "$T/repo" && printf 'def add(a, b):\n    return b + a\n' > a.py && $G commit -qam "main sửa khác" )
  out=$($CTL wt-merge conf 2>&1); rc=$?
  check "exit 1 + báo CONFLICT" "[[ $rc -eq 1 ]] && grep -q CONFLICT <<<\"\$out\""
  git -C "$T/repo" merge --abort 2>/dev/null
  check "wt-drop dọn được"      "$CTL wt-drop conf >/dev/null 2>&1; ! git -C '$T/repo' branch | grep -q agy/"
fi

if run stop; then echo "== stall + stop"
  mkrepo
  $SUB -R -n slow -d "$T/repo" -p "Chạy đúng lệnh shell: sleep 300. Sau đó báo xong." >"$T/slow.out" 2>&1 &
  sleep 30
  pid=$(<"$(ls -d "$AGY_JOBS"/slow-*)/pid")
  check "list: RUNNING"            "$CTL list | grep -q '^RUNNING'"
  check "status: STALL khi idle"   "[[ \$(AGY_STALL_SEC=-1 $CTL status slow) == *STALL* ]]"
  $CTL stop slow >/dev/null 2>&1; sleep 2; wait
  check "state STOPPED"            "[[ \$($CTL status slow) == *STATE=STOPPED* ]]"
  sleep 2; check "tiến trình đã chết"       "! kill -0 $pid 2>/dev/null && ! pgrep -fx 'sleep 300' >/dev/null"
  check "stop all cần -y"          "! $CTL stop all >/dev/null 2>&1"
fi

if run timeout; then echo "== timeout"
  $SUB -R -t 12 -n tmo -d "$T" -p "Chạy đúng lệnh shell: sleep 300. Sau đó báo xong." >/dev/null 2>&1; rc=$?
  check "exit 124"        "[[ $rc -eq 124 ]]"
  check "state TIMEOUT"   "[[ \$($CTL status tmo) == *STATE=TIMEOUT* ]]"
  sleep 2; check "không sót tiến trình con" "! pgrep -fx 'sleep 300' >/dev/null"
fi

if run fan; then echo "== fan 5 task, -j 4 (xếp hàng), -W"
  mkrepo; mkdir -p "$T/tasks"; for i in 1 2 3 4 5; do
    echo "Tạo file f$i.txt chứa đúng chữ $i. Chỉ tạo f$i.txt." >"$T/tasks/t$i.md"; done
  $FAN -i "$T/tasks" -o "$T/res" -j 4 -d "$T/repo" -W >/dev/null 2>&1
  check "5 dòng SUMMARY"      "[[ \$(wc -l <'$T/res/SUMMARY.tsv') -eq 5 ]]"
  check "cả 5 SUCCESS"        "[[ \$(grep -c SUCCESS '$T/res/SUMMARY.tsv') -eq 5 ]]"
  for i in 1 2 3 4 5; do $CTL wt-merge "t$i" >/dev/null 2>&1; done
  check "5 file đã merge"     "[[ \$(cat '$T'/repo/f?.txt 2>/dev/null | tr -d '\n') == 12345 ]]"
fi

if run gc; then echo "== gc"
  n=$(ls "$AGY_JOBS" 2>/dev/null | wc -l)
  check "gc 0 không -y: chỉ liệt kê"  "$CTL gc 0 >/dev/null 2>&1; [[ \$(ls '$AGY_JOBS' | wc -l) -eq $n ]]"
  $CTL gc 0 -y >/dev/null 2>&1
  check "gc 0 -y: xóa job xong"       "[[ \$(ls '$AGY_JOBS' | wc -l) -lt $n || $n -eq 0 ]]"
fi

echo; echo "PASS=$pass FAIL=$fail"; [[ $fail -eq 0 ]]
