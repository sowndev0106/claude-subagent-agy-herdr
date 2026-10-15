#!/usr/bin/env bash
# Test nhanh cho wt.sh (worktree của job -W). KHÔNG gọi agy, không cần herdr: giả lập phần agy sửa file.
# Bất biến chính: job không bao giờ để lại commit, branch hay chữ "agy" trong lịch sử repo; thay đổi về cây làm
# việc ở dạng CHƯA commit để agent quản lý tự commit theo chuẩn của repo.
# Usage: selftest-wt.sh [carry nocarry conflict config legacy selfcommit empty ...]
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$here/wt.sh" || { echo "không nạp được $here/wt.sh"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/agy-wt-selftest.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0 fail=0; ok() { echo "  PASS $*"; pass=$((pass+1)); }; bad() { echo "  FAIL $*"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
WANT=("$@"); run() { [[ ${#WANT[@]} -eq 0 ]] && return 0; local t; for t in "${WANT[@]}"; do [[ $t == "$1" ]] && return 0; done; return 1; }
G="git -c user.name=t -c user.email=t@t"
mkrepo() { rm -rf "$T/repo" "$T/wt"; mkdir -p "$T/repo"; ( cd "$T/repo" && git init -q -b main \
  && printf 'def add(a, b):\n    return a - b\n' > a.py && printf 'x=1\n' > keep.txt && printf 'old\n' > old.txt \
  && git add -A && $G commit -qm init ); }
# lịch sử sạch: đúng 1 commit (init), chỉ branch main, không ref/commit/tác giả nào mang chữ agy
clean_history() {
  [[ $(git -C "$T/repo" rev-list --all | wc -l) -eq ${1:-1} ]] \
    && [[ $(git -C "$T/repo" for-each-ref --format='%(refname)') == refs/heads/main ]] \
    && ! git -C "$T/repo" log --all --format='%an %ae %cn %ce %B' | grep -qi agy
}

if run carry; then echo "== carry (-C): thay đổi chưa commit + untracked sang worktree, áp lại không commit"
  mkrepo; ( cd "$T/repo" && printf 'x=2\n' > keep.txt && printf 'u\n' > u.txt )
  base=$(wt_create "$T/repo" "$T/wt" 1 2>"$T/err"); rc=$?
  check "tạo được, BASE là tree"         "[[ $rc -eq 0 && \$(git -C '$T/repo' cat-file -t '$base') == tree ]]"
  check "worktree detached, không branch" "! git -C '$T/wt' symbolic-ref -q HEAD && [[ \$(git -C '$T/repo' branch | wc -l) -eq 1 ]]"
  check "worktree thấy keep.txt bẩn"     "grep -q 'x=2' '$T/wt/keep.txt'"
  check "worktree thấy file untracked"   "[[ -f '$T/wt/u.txt' ]]"
  # "agy" làm việc: sửa, thêm, xoá, file binary
  printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"; printf 'n\n' > "$T/wt/new.txt"; rm "$T/wt/old.txt"
  mkdir -p "$T/wt/d"; printf 'bin\0x\377' > "$T/wt/d/b.bin"
  check "wt_changed thấy thay đổi"       "wt_changed '$T/wt' '$base'"
  check "diff chỉ gồm phần agy làm"      "[[ \$(wt_diff '$T/wt' '$base' --name-only | sort | tr '\n' ' ') == 'a.py d/b.bin new.txt old.txt ' ]]"
  out=$(wt_apply "$T/wt" "$base" "$T/repo" 2>&1); rc=$?
  check "wt_apply exit 0"                 "[[ $rc -eq 0 ]]"
  check "a.py đã sửa ở repo"              "grep -q 'a + b' '$T/repo/a.py'"
  check "file mới + binary đúng byte"     "[[ -f '$T/repo/new.txt' ]] && cmp -s '$T/wt/d/b.bin' '$T/repo/d/b.bin'"
  check "file xoá đã xoá"                 "[[ ! -e '$T/repo/old.txt' ]]"
  check "keep.txt + u.txt vẫn bản bẩn"    "grep -q 'x=2' '$T/repo/keep.txt' && [[ -f '$T/repo/u.txt' ]]"
  check "báo các file đã áp"              "grep -q 'a.py' <<<\"\$out\" && grep -q 'CHƯA commit' <<<\"\$out\""
  check "không commit/branch/agy nào"     "clean_history"
  wt_remove "$T/repo" "$T/wt" ""
  check "worktree đã dọn"                 "[[ ! -d '$T/wt' && \$(git -C '$T/repo' worktree list | wc -l) -eq 1 ]]"
  check "lịch sử vẫn sạch sau khi dọn"   "clean_history"
fi

if run nocarry; then echo "== không -C: repo bẩn thì cảnh báo, worktree chỉ thấy HEAD"
  mkrepo; ( cd "$T/repo" && printf 'x=2\n' > keep.txt )
  base=$(wt_create "$T/repo" "$T/wt" 0 2>"$T/err")
  check "có WARN"                         "grep -q WARN '$T/err'"
  check "worktree thấy keep.txt sạch"    "grep -q 'x=1' '$T/wt/keep.txt'"
  check "chưa sửa gì: wt_changed = không" "! wt_changed '$T/wt' '$base'"
  printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"
  wt_apply "$T/wt" "$base" "$T/repo" >/dev/null 2>&1
  check "áp a.py, keep.txt bẩn giữ nguyên" "grep -q 'a + b' '$T/repo/a.py' && grep -q 'x=2' '$T/repo/keep.txt'"
  check "không commit/branch/agy nào"     "clean_history"
  wt_remove "$T/repo" "$T/wt" ""
fi

if run conflict; then echo "== conflict: không ghi gì; --3way để lại marker"
  mkrepo; base=$(wt_create "$T/repo" "$T/wt" 0 2>/dev/null)
  printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"
  ( cd "$T/repo" && printf 'def add(a, b):\n    return b + a\n' > a.py && $G commit -qam "main sửa khác" )
  out=$(wt_apply "$T/wt" "$base" "$T/repo" 2>&1); rc=$?
  check "exit 1 + CONFLICT"               "[[ $rc -eq 1 ]] && grep -q CONFLICT <<<\"\$out\""
  check "cây làm việc không bị đụng"      "[[ -z \$(git -C '$T/repo' status --porcelain) ]]"
  out=$(wt_apply "$T/wt" "$base" "$T/repo" --3way 2>&1); rc=$?
  check "--3way: exit 2 + marker"         "[[ $rc -eq 2 ]] && grep -q '<<<<<<<' '$T/repo/a.py' && grep -q CONFLICT <<<\"\$out\""
  check "không commit/branch/agy nào"     "clean_history 2"
  git -C "$T/repo" checkout -q HEAD -- a.py; wt_remove "$T/repo" "$T/wt" ""
  check "worktree đã dọn"                 "[[ ! -d '$T/wt' ]]"
fi

if run config; then echo "== cấu hình git của người dùng không làm hỏng patch"
  mkrepo
  for kv in diff.noprefix=true diff.mnemonicPrefix=true color.diff=always color.ui=always diff.external=false \
            diff.relative=true apply.whitespace=error core.quotePath=true; do git -C "$T/repo" config "${kv%%=*}" "${kv#*=}"; done
  mkdir -p "$T/repo/sub"; ( cd "$T/repo" && printf 'z\n' > sub/z.txt && $G add -A && $G commit -qm sub )
  base=$(wt_create "$T/repo" "$T/wt" 0 2>/dev/null)
  printf 'def add(a, b):\n    return a + b   \n' > "$T/wt/a.py"; printf 'z2\n' > "$T/wt/sub/z.txt"; printf 'v\n' > "$T/wt/tên có dấu.txt"
  out=$(wt_apply "$T/wt" "$base" "$T/repo" 2>&1); rc=$?
  check "exit 0"                          "[[ $rc -eq 0 ]]"
  check "3 file đã áp (cả file tên có dấu)" "grep -q 'a + b' '$T/repo/a.py' && grep -q z2 '$T/repo/sub/z.txt' && [[ -f '$T/repo/tên có dấu.txt' ]]"
  check "không commit/branch/agy nào"     "clean_history 2"
  wt_remove "$T/repo" "$T/wt" ""
fi

if run legacy; then echo "== job kiểu cũ (branch agy/<id>, wrapper đã commit): vẫn áp được, dọn cả branch"
  mkrepo; git -C "$T/repo" worktree add -q -b agy/a-old-0001 "$T/wt" HEAD; base=$(git -C "$T/wt" rev-parse HEAD)
  printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"
  git -C "$T/wt" add -A; git -C "$T/wt" -c user.name=agy -c user.email=agy@local commit -qm "agy: a-old-0001"
  printf 'n\n' > "$T/wt/new.txt"   # còn dở, chưa commit
  check "diff gồm cả phần đã commit lẫn phần dở" "[[ \$(wt_diff '$T/wt' '$base' --name-only | sort | tr '\n' ' ') == 'a.py new.txt ' ]]"
  wt_apply "$T/wt" "$base" "$T/repo" >/dev/null 2>&1
  check "áp vào repo, HEAD không đổi"     "grep -q 'a + b' '$T/repo/a.py' && [[ -f '$T/repo/new.txt' && \$(git -C '$T/repo' rev-list --count HEAD) -eq 1 ]]"
  wt_remove "$T/repo" "$T/wt" agy/a-old-0001
  check "branch cũ đã xoá, lịch sử sạch"  "clean_history"
fi

if run selfcommit; then echo "== agy tự commit trong worktree (trái guard): commit đó không vào lịch sử"
  mkrepo; base=$(wt_create "$T/repo" "$T/wt" 0 2>/dev/null)
  printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"
  git -C "$T/wt" add -A; git -C "$T/wt" -c user.name=agy -c user.email=agy@local commit -qm "agy did it"
  wt_apply "$T/wt" "$base" "$T/repo" >/dev/null 2>&1
  check "thay đổi vẫn được áp"            "grep -q 'a + b' '$T/repo/a.py' && [[ \$(git -C '$T/repo' rev-list --count HEAD) -eq 1 ]]"
  wt_remove "$T/repo" "$T/wt" ""
  check "commit của agy không còn ref nào" "clean_history"
fi

if run commit; then echo "== wt_merge -m: một commit mang tên người dùng, chỉ gồm file của job"
  mkrepo; git -C "$T/repo" config user.name "Sown Test"; git -C "$T/repo" config user.email sown@test
  base=$(wt_create "$T/repo" "$T/wt" 0 2>/dev/null)
  printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"; printf 'n\n' > "$T/wt/new.txt"; rm "$T/wt/old.txt"
  ( cd "$T/repo" && printf 'x=9\n' > keep.txt && git add keep.txt )   # người dùng đang stage việc khác
  out=$(wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" -m "fix(math): make add return the sum" -m "Body line." 2>&1); rc=$?
  check "exit 0 + báo đã commit"          "[[ $rc -eq 0 ]] && grep -q 'đã commit' <<<\"\$out\""
  check "đúng 1 commit mới, tác giả = git config" "[[ \$(git -C '$T/repo' rev-list --count HEAD) -eq 2 && \$(git -C '$T/repo' log -1 --format='%an <%ae>|%cn <%ce>') == 'Sown Test <sown@test>|Sown Test <sown@test>' ]]"
  check "message đúng như -m"              "[[ \$(git -C '$T/repo' log -1 --format=%B | sed '/^\$/d' | tr '\n' '|') == 'fix(math): make add return the sum|Body line.|' ]]"
  check "commit chỉ gồm file của job"      "[[ \$(git -C '$T/repo' show --name-only --format= HEAD | sort | tr '\n' ' ') == 'a.py new.txt old.txt ' ]]"
  check "keep.txt vẫn đang stage, chưa commit" "[[ \$(git -C '$T/repo' diff --cached --name-only) == keep.txt ]]"
  check "không merge commit, không agy"    "[[ \$(git -C '$T/repo' rev-list --merges --count HEAD) -eq 0 ]] && clean_history 2"
  check "worktree đã dọn"                  "[[ ! -d '$T/wt' ]]"
fi

if run refuse; then echo "== wt_merge từ chối: thiếu -m, message sai chuẩn/mang dấu vết, file bẩn, không có identity"
  mkrepo; git -C "$T/repo" config user.name "Sown Test"; git -C "$T/repo" config user.email sown@test
  base=$(wt_create "$T/repo" "$T/wt" 0 2>/dev/null); printf 'def add(a, b):\n    return a + b\n' > "$T/wt/a.py"
  untouched() { [[ -z $(git -C "$T/repo" status --porcelain) && $(git -C "$T/repo" rev-list --count HEAD) -eq 1 && -d "$T/wt" ]]; }
  wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" >/dev/null 2>&1; rc=$?
  check "thiếu -m/--no-commit: exit 2, không đụng gì" "[[ $rc -eq 2 ]] && untouched"
  for m in "agy: a-job-1234" "Merge agy/a-job-1234 (agy subagent)" "update stuff" "feat: wip" "fix(x): done by agy" \
           "fix(math): sum for a-job-1234" "Fix the add function" "feat(math):no space"; do
    wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" -m "$m" >/dev/null 2>&1; rc=$?
    check "từ chối \"$m\""                 "[[ $rc -eq 2 ]] && untouched"
  done
  wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" -m "fix(math): sum" -m "Co-Authored-By: Claude <noreply@anthropic.com>" >/dev/null 2>&1; rc=$?
  check "từ chối trailer Co-Authored-By"   "[[ $rc -eq 2 ]] && untouched"
  check "cho phép scope agy-subagent"      "wt_check_msg a-job-1234 'feat(agy-subagent): drop internal commits' >/dev/null"
  check "cho phép 'update' có nội dung"   "wt_check_msg a-job-1234 'docs(readme): update install steps' >/dev/null"
  check "từ chối mô tả chỉ có 'update'"   "! wt_check_msg a-job-1234 'chore: update' >/dev/null && ! wt_check_msg a-job-1234 'fix(x): fixes' >/dev/null"
  check "AGY_COMMIT_PATTERN đổi chuẩn"    "AGY_COMMIT_PATTERN='^\[MART-[0-9]+\] ' wt_check_msg a-job-1234 '[MART-12] Fix add' >/dev/null"
  printf 'def add(a, b):\n    return 0\n' > "$T/repo/a.py"   # người dùng đang sửa dở đúng file job đụng
  out=$(wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" -m "fix(math): make add return the sum" 2>&1); rc=$?
  check "file job đụng đang bẩn: exit 2, giữ bản của người dùng" "[[ $rc -eq 2 ]] && grep -q 'return 0' '$T/repo/a.py' && grep -q -- '--no-commit' <<<\"\$out\""
  git -C "$T/repo" checkout -q -- a.py
  git -C "$T/repo" config --unset user.name; git -C "$T/repo" config --unset user.email
  out=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" -m "fix(math): make add return the sum" 2>&1); rc=$?
  check "không có git identity: exit 2, không fallback agy" "[[ $rc -eq 2 ]] && grep -q user.name <<<\"\$out\" && untouched"
  out=$(wt_merge "$T/wt" "$base" "$T/repo" a-job-1234 "" --no-commit 2>&1); rc=$?
  check "--no-commit: áp, không commit, có lời dặn" "[[ $rc -eq 0 ]] && grep -q 'a + b' '$T/repo/a.py' && [[ \$(git -C '$T/repo' rev-list --count HEAD) -eq 1 ]] && grep -q 'Conventional Commits' <<<\"\$out\""
  check "lịch sử sạch"                     "clean_history"
fi

if run empty; then echo "== không có thay đổi"
  mkrepo; base=$(wt_create "$T/repo" "$T/wt" 0 2>/dev/null)
  out=$(wt_apply "$T/wt" "$base" "$T/repo" 2>&1); rc=$?
  check "exit 0, báo không có thay đổi"   "[[ $rc -eq 0 ]] && grep -q 'không có thay đổi' <<<\"\$out\""
  check "repo sạch"                       "[[ -z \$(git -C '$T/repo' status --porcelain) ]] && clean_history"
  wt_remove "$T/repo" "$T/wt" ""
fi

echo; echo "PASS=$pass FAIL=$fail"; [[ $fail -eq 0 ]]
