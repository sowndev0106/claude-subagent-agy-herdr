#!/usr/bin/env bash
# agy-id: mỗi phiên Claude Code mang một số 3 chữ số + tên, vd "#132 Đánh giá engine gợi ý".
# Số cấp tuần tự 100..999 (quay vòng, bỏ qua số đang được phiên khác dùng trong 14 ngày). Dùng chung giữa mọi phiên Claude Code
# trên máy (flock chống cấp trùng). Phiên = $CLAUDE_CODE_SESSION_ID (không có thì khóa "manual").
#
#   agy-id claim ["tên nhiệm vụ"]   nhận số (lần đầu) hoặc đổi tên (nếu có tên); in "#132 tên"
#   agy-id show                      in "#132 tên" của phiên này; chưa có -> exit 1, không cấp số
#   agy-id label [tên mặc định]      nhãn cho workspace herdr; chưa có số thì cấp luôn, tên rỗng thì dùng tên mặc định
#   agy-id num                       chỉ in số (rỗng nếu chưa có)
#   agy-id rename "tên mới"          đổi tên (giữ số)
#   agy-id list                      mọi số đã cấp: số, tên, phiên, tuổi
#   agy-id release                   trả số của phiên này
# Dữ liệu: $AGY_ID_DIR (mặc định ~/.cache/agy-ids).
# Nạp lớp tương thích (macOS/BSD/busybox, bash >= 4.4): tìm thư mục thật của script qua symlink mà không cần readlink -f
_s=$0; while [[ -L $_s ]]; do _d=$(cd -P "$(dirname "$_s")" && pwd); _s=$(readlink "$_s"); [[ $_s == /* ]] || _s=$_d/$_s; done
_HERE=$(cd -P "$(dirname "$_s")" && pwd)
for _c in "$_HERE/compat.sh" "$_HERE/../../agy-subagent/scripts/compat.sh"; do [[ -f $_c ]] && { source "$_c"; break; }; done
set -uo pipefail
DIR="${AGY_ID_DIR:-$HOME/.cache/agy-ids}"; MAP="$DIR/map.tsv"; CNT="$DIR/counter"; DAYS="${AGY_ID_ACTIVE_DAYS:-14}"
mkdir -p "$DIR"; touch "$MAP"
key()   { local id=${CLAUDE_CODE_SESSION_ID:-}; [[ -n $id ]] && echo "$id" || echo manual; }
clean() { printf '%s' "$*" | tr '\t\n\r' '   ' | sed -E 's/^ +| +$//g; s/ +/ /g' | cut -c1-60; }
lock()  { exec 8>"$DIR/.lock"; flock 8; }
row()   { awk -F'\t' -v k="$1" '$1==k{print; exit}' "$MAP"; }
fmt()   { if [[ -n $2 ]]; then echo "#$1 $2"; else echo "#$1"; fi; }
alloc() {
  local cutoff c used i; cutoff=$(( $(date +%s) - DAYS*86400 )); c=$(cat "$CNT" 2>/dev/null || echo 99)
  used=$(awk -F'\t' -v t="$cutoff" '$4>=t{print $2}' "$MAP")
  for i in $(seq 900); do c=$((c+1)); (( c > 999 )) && c=100; grep -qx "$c" <<<"$used" || break; done
  echo "$c" >"$CNT"; echo "$c"
}
write_row() {  # $1=key $2=num $3=title
  awk -F'\t' -v k="$1" '$1!=k' "$MAP" >"$MAP.tmp"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%s)" >>"$MAP.tmp"; mv "$MAP.tmp" "$MAP"
}
cmd=${1:-}; shift || true
case $cmd in
  claim|rename|label)
    lock; k=$(key); r=$(row "$k"); t=$(clean "$*")
    if [[ -n $r ]]; then
      num=$(cut -f2 <<<"$r"); title=$(cut -f3 <<<"$r")
      if [[ $cmd == label ]]; then [[ -z $title ]] && title=$t; else [[ -n $t ]] && title=$t; fi
    else num=$(alloc); title=$t; fi
    [[ $cmd == rename && -z $t ]] && { echo "agy-id: rename cần tên mới" >&2; exit 2; }
    write_row "$k" "$num" "$title"; fmt "$num" "$title" ;;
  show)  r=$(row "$(key)"); [[ -n $r ]] || { echo "agy-id: phiên này chưa có số (agy-id claim \"tên\")" >&2; exit 1; }
         fmt "$(cut -f2 <<<"$r")" "$(cut -f3 <<<"$r")" ;;
  num)   r=$(row "$(key)"); [[ -n $r ]] && cut -f2 <<<"$r" || true ;;
  list)  now=$(date +%s); printf '%-5s %-44s %-10s %s\n' SỐ TÊN PHIÊN TUỔI
         sort -t$'\t' -k2,2n "$MAP" | while IFS=$'\t' read -r k n t e; do
           printf '%-5s %-44s %-10s %s\n' "#$n" "$t" "${k:0:8}" "$(( (now-e)/3600 ))h"; done ;;
  release) lock; k=$(key); awk -F'\t' -v k="$k" '$1!=k' "$MAP" >"$MAP.tmp"; mv "$MAP.tmp" "$MAP"; echo "đã trả số của phiên $(key | cut -c1-8)" ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
