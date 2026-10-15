# wt.sh: git worktree riêng cho job agy (-W) mà KHÔNG tạo commit hay branch nào. Nạp bởi agy-hd, agy-sub, agy-ctl.
#
# Người dùng dặn 2026-10-15: agy không được commit bằng tên của nó, lịch sử repo không được có commit nào mang
# chữ agy (trước đây wrapper commit "agy: <job>" với tác giả agy@local rồi wt-merge tạo "Merge agy/<id>").
# Nên ở đây không có commit nào cả:
#   - worktree tách từ HEAD ở trạng thái detached, không branch;
#   - BASE = tree id lúc giao việc (HEAD, cộng thay đổi chưa commit của repo khi -C), không phải commit;
#   - thay đổi của agy được chụp vào index RIÊNG của worktree (git add -A) rồi so với BASE;
#   - wt_apply áp đúng phần đó vào cây làm việc của repo, CHƯA commit.
# Commit là việc của agent quản lý (Claude Code): review diff, chạy test, rồi commit bằng git identity của người
# dùng, message theo chuẩn commit của repo.
# Job tạo trước thay đổi này (branch agy/<id>, BASE là commit) vẫn dùng được: index của worktree chứa cả các commit
# cũ nên diff so với BASE vẫn đúng; wt_remove xoá luôn branch cũ.

# git diff để máy đọc: cấu hình của người dùng (noprefix, màu, diff ngoài, textconv, relative) không được làm hỏng patch
wt_git_diff() { git -C "$1" -c diff.relative=false diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "${@:2}"; }

wt_create() {  # $1=repo $2=thư mục worktree $3=carry(0/1) -> in BASE (tree id)
  local repo=$1 w=$2 carry=$3 f
  mkdir -p "$(dirname "$w")"
  git -C "$repo" worktree add -q --detach "$w" HEAD >&2 || return 1
  if [[ -n $(git -C "$repo" status --porcelain) ]]; then
    if [[ $carry -eq 1 ]]; then
      # thay đổi tracked (kể cả binary, file xoá) + file untracked không bị ignore
      wt_git_diff "$repo" --binary HEAD | git -C "$w" apply --whitespace=nowarn - || return 1
      git -C "$repo" ls-files -z -o --exclude-standard | while IFS= read -r -d '' f; do
        mkdir -p "$w/$(dirname "$f")"; cp -a "$repo/$f" "$w/$f"; done
    else echo "WARN: repo có thay đổi chưa commit, worktree KHÔNG thấy chúng (chỉ thấy HEAD). Dùng -C để mang theo." >&2; fi
  fi
  git -C "$w" add -A && git -C "$w" write-tree
}

wt_snap() { git -C "$1" add -A >/dev/null 2>&1; }   # chụp những gì agy đã sửa vào index của worktree (không commit)

wt_diff() {  # $1=worktree $2=BASE [tuỳ chọn git diff: --stat, --name-only, --binary...] -> phần agy đã làm
  wt_snap "$1"; wt_git_diff "$1" --cached "${@:3}" "$2"
}

wt_changed() { wt_snap "$1"; ! git -C "$1" diff --cached --quiet --no-ext-diff "$2"; }   # $1=worktree $2=BASE

wt_files() { mapfile -d '' -t WT_FILES < <(wt_diff "$1" "$2" --name-only --no-renames -z); }   # -> WT_FILES: mọi path job đụng tới

# Áp thay đổi của job vào cây làm việc của repo, CHƯA commit. $1=worktree $2=BASE $3=repo [$4=--3way]
#   mặc định: chỉ ghi khi áp trọn vẹn được; không thì không đụng gì, trả 1 (CONFLICT).
#   --3way : gộp 3 chiều như git merge; file xung đột giữ marker để sửa tay, trả 2. File bị đụng phải chưa sửa
#            so với index (git từ chối và không ghi gì, trả 1).
wt_apply() {
  local w=$1 base=$2 r=$3 mode=${4:-} p rc files=()
  wt_changed "$w" "$base" || { echo "không có thay đổi nào để áp"; return 0; }
  p=$(mktemp "${TMPDIR:-/tmp}/agy-wt.XXXXXX") || return 1
  wt_diff "$w" "$base" --binary >"$p"
  wt_files "$w" "$base"; files=("${WT_FILES[@]}")
  if [[ $mode == --3way ]]; then
    git -C "$r" apply --3way --whitespace=nowarn "$p" >"$p.err" 2>&1; rc=$?
    if (( rc )) && [[ -n $(git -C "$r" diff --name-only --diff-filter=U) ]]; then rc=2; fi
  elif git -C "$r" apply --check --whitespace=nowarn "$p" >"$p.err" 2>&1; then
    git -C "$r" apply --whitespace=nowarn "$p" >"$p.err" 2>&1; rc=$?
  else rc=1; fi
  case $rc in
  0) echo "đã áp thay đổi vào cây làm việc của $r (CHƯA commit):"
     git -C "$r" -c core.quotePath=false --literal-pathspecs status --short -- "${files[@]}" | sed 's/^/  /' ;;
  2) echo "CONFLICT: đã gộp 3 chiều vào $r, các file sau còn marker xung đột (sửa tay rồi git add):"
     git -C "$r" -c core.quotePath=false diff --name-only --diff-filter=U | sed 's/^/  /' ;;
  *) rc=1; echo "CONFLICT: không áp gọn được thay đổi của job vào $r, chưa ghi gì:"; head -5 "$p.err" | sed 's/^/  /' ;;
  esac
  rm -f "$p" "$p.err"; return $rc
}

# Lời dặn in sau khi áp: lịch sử repo chỉ có commit do agent quản lý tạo, không có dấu vết subagent.
wt_commit_hint() {
  echo "COMMIT: chưa có commit nào. Agent quản lý review diff, chạy test, rồi tự commit bằng git identity của người dùng,"
  echo "        message theo chuẩn commit của repo (Conventional Commits: <type>(<scope>): <mô tả>), không nhắc agy/Claude/AI/id job."
}

# Message commit: dòng đầu theo Conventional Commits (repo dùng chuẩn khác thì đặt AGY_COMMIT_PATTERN, regex ERE),
# và không mang dấu vết subagent hay công cụ. "agy" đứng riêng (agy:, agy job, agy/<id>) bị từ chối; tên thành phần
# như agy-subagent, agy-hd thì được (repo của chính bộ agy).
WT_MSG_PATTERN='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^()]+\))?!?: [^ ]'
wt_check_msg() {  # $1=id job, $2..=các đoạn message theo thứ tự -m -> 0 hợp lệ, 1 kèm lý do
  local id=$1 subj=${2:-} all; shift; all=$(printf '%s\n' "$@")
  [[ -n $subj ]] || { echo "thiếu message"; return 1; }
  grep -qE "${AGY_COMMIT_PATTERN:-$WT_MSG_PATTERN}" <<<"$subj" \
    || { echo "dòng đầu không theo chuẩn commit (<type>(<scope>): <mô tả>): \"$subj\""; return 1; }
  # mô tả không nói gì: bắt đầu bằng wip/tmp/fixup!, hoặc chỉ có một chữ chung chung (update, changes, misc...)
  grep -qiE '^[a-z]+(\([^()]*\))?!?: *((wip|tmp|temp|fixup!|squash!)( |$)|(update|updates|changes?|misc|stuff|fix|fixes) *$)' <<<"$subj" \
    && { echo "mô tả quá chung chung: \"$subj\". Ghi rõ đã đổi gì"; return 1; }
  local bad
  for bad in "$id" 'agy@local' '(agy subagent)' 'co-authored-by:' 'generated with' 'claude.ai/' 'claude-session' '🤖'; do
    [[ -n $bad ]] && grep -qiF -- "$bad" <<<"$all" && { echo "message mang dấu vết công cụ (\"$bad\"); chỉ mô tả thay đổi"; return 1; }
  done
  grep -qiE '(^|[^a-z0-9-])(agy|antigravity)([^a-z0-9-]|$)' <<<"$all" \
    && { echo "message nhắc tới agy/antigravity; chỉ mô tả thay đổi"; return 1; }
  return 0
}

# Kiểm trước khi áp: commit tự động chỉ an toàn khi mọi file job đụng tới đang sạch trong repo (không sửa, không stage,
# không untracked). Nếu không, commit sẽ trộn cả thay đổi dở của người dùng. $1=repo, path trong WT_FILES.
wt_commit_ready() {
  local r=$1 dirty
  git -C "$r" config user.name >/dev/null && git -C "$r" config user.email >/dev/null \
    || { echo "repo $r chưa cấu hình git user.name/user.email: commit phải mang tên người dùng"; return 1; }
  dirty=$(git -C "$r" -c core.quotePath=false --literal-pathspecs status --porcelain -- "${WT_FILES[@]}")
  [[ -z $dirty ]] || { echo "các file sau đang có thay đổi chưa commit của bạn, commit tự động sẽ trộn vào:"; sed 's/^/  /' <<<"$dirty"; return 1; }
}

# Commit đúng các file job đã đổi (WT_FILES), bằng git identity của repo; phần người dùng đã stage ở file khác giữ nguyên
# (git commit -- <path> chỉ lấy các path đó). Hook của repo (pre-commit, commit-msg) vẫn chạy. $1=repo, $2..= -m ...
wt_commit() {
  local r=$1; shift
  git -C "$r" --literal-pathspecs add -A -- "${WT_FILES[@]}" || return 1
  git -C "$r" --literal-pathspecs commit -q "$@" -- "${WT_FILES[@]}" || { echo "commit thất bại (hook?): thay đổi vẫn nằm trong cây làm việc, chưa commit"; return 1; }
  echo "đã commit: $(git -C "$r" log -1 --format='%h %an <%ae>: %s')"
}

# wt-merge dùng chung cho agy-hd và agy-ctl. $1=worktree $2=BASE $3=repo $4=id job $5=branch kiểu cũ (rỗng với job mới),
# rồi tham số của người gọi: -m "type(scope): mô tả" [-m "thân"]... | --no-commit, và [--3way].
# Trả 0 = xong (đã áp, đã commit nếu có -m, worktree đã dọn); 1 = xung đột/commit hỏng (worktree giữ nguyên);
# 2 = tham số hoặc điều kiện sai (chưa đụng gì).
wt_merge() {
  local w=$1 base=$2 r=$3 id=$4 b=$5 nocommit=0 three="" msgs=() margs=() why rc; shift 5
  while (( $# )); do case $1 in
    -m) [[ -n ${2:-} ]] || { echo "-m cần message"; return 2; }; msgs+=("$2"); margs+=(-m "$2"); shift 2;;
    --no-commit) nocommit=1; shift;;
    --3way) three=--3way; shift;;
    *) echo "tham số lạ: $1"; return 2;; esac; done
  (( nocommit && ${#msgs[@]} )) && { echo "-m và --no-commit không đi cùng nhau"; return 2; }
  (( nocommit || ${#msgs[@]} )) || { echo 'wt-merge cần message commit: wt-merge <job> -m "type(scope): việc đã làm" [-m "thân"]  (hoặc --no-commit rồi tự commit)'; return 2; }
  [[ -n $w && -d $w ]] || { echo "worktree không còn: ${w:-?}"; return 2; }
  if ! wt_changed "$w" "$base"; then echo "job không có thay đổi nào"; wt_remove "$r" "$w" "$b"; return 0; fi
  wt_files "$w" "$base"
  if (( ! nocommit )); then
    why=$(wt_check_msg "$id" "${msgs[@]}") || { echo "từ chối message: $why"; return 2; }
    why=$(wt_commit_ready "$r") || { echo "$why"; echo "→ chạy lại với --no-commit, rồi tự commit đúng phần cần commit"; return 2; }
  fi
  wt_apply "$w" "$base" "$r" $three; rc=$?
  (( rc )) && { echo "worktree giữ nguyên: $w (xem: wt-diff; gộp 3 chiều: thêm --3way; bỏ: wt-drop)"; return 1; }
  if (( nocommit )); then wt_commit_hint
  else wt_commit "$r" "${margs[@]}" || { echo "worktree giữ nguyên: $w"; return 1; }; fi
  wt_remove "$r" "$w" "$b"; echo "đã dọn worktree $w"
}

wt_remove() {  # $1=repo $2=worktree $3=branch của job kiểu cũ (agy/<id>; rỗng với job mới)
  [[ -n $2 && -d $2 ]] && git -C "$1" worktree remove --force "$2"
  git -C "$1" worktree prune 2>/dev/null
  [[ -n ${3:-} ]] && git -C "$1" branch -D "$3" >/dev/null 2>&1
  return 0
}
