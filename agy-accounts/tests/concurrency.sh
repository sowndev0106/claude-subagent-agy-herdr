#!/usr/bin/env bash
# Test herdr + agy-hd khi chạy đồng thời (session cas, gọi agy thật, ~8 phút): 4 start song song, khoá job
# (park chờ khoá, switch + park nối tiếp), resume đồng loạt trong lúc tick chạy, đóng hết.
set -uo pipefail
S=$(mktemp -d "${TMPDIR:-/tmp}/agy-conc.XXXXXX"); W=$S/work; mkdir -p "$W"; LOG=$S/concurrency.log; : >"$LOG"
pass=0; fail=0; JOBS=()
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
H()   { env -u HERDR_SOCKET_PATH HERDR_SESSION=cas herdr "$@"; }
st()  { local v; v=$(H agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null); echo "${v:-gone}"; }
P='Trả lời đúng 1 dòng: READY'

# H1: 4 start song song (không phải fan) → khoá chọn account + khoá đặt tab + 4 herdr agent start cùng lúc
echo "--- H1" >>"$LOG"
for k in 1 2 3 4; do ( agy-hd start -n hs$k -d "$W" -A -p "$P" >"$S/hs$k.out" 2>&1 ) & done; wait
cat "$S"/hs?.out >>"$LOG"
good=0; for k in 1 2 3 4; do j=$(sed -n 's/^JOB=//p' "$S/hs$k.out"); JOBS+=("$j")
  grep -q '^STATUS=RUNNING' "$S/hs$k.out" && [[ -n $(sed -n 's/^ACCOUNT=//p' "$S/hs$k.out") ]] && good=$((good+1)); done
tabs=$(for j in "${JOBS[@]}"; do sed -n 's/^TAB=//p' ~/.cache/agy-hd/$j/meta.env; done | sort -u | wc -l)
wss=$(for j in "${JOBS[@]}"; do sed -n 's/^WORKSPACE=//p' ~/.cache/agy-hd/$j/meta.env; done | sort -u | wc -l)
(( good == 4 && tabs == 4 && wss == 1 )) && ok "H1 4 start song song: 4/4 RUNNING có ACCOUNT, 4 tab riêng, chung 1 workspace" || bad "H1 (ok=$good tab=$tabs ws=$wss)"
for j in "${JOBS[@]}"; do agy-hd wait "$j" 180 >>"$LOG" 2>&1; done
d=0; for j in "${JOBS[@]}"; do agy-hd result "$j" 2>/dev/null | grep -q READY && d=$((d+1)); done
(( d == 4 )) && ok "H1b cả 4 job trả lời READY" || bad "H1b ($d/4 READY)"

# L1: khoá job đang bị giữ → park phải chờ
echo "--- L1" >>"$LOG"
J=${JOBS[0]}; ( exec 7>~/.cache/agy-hd/$J/.lock; flock 7; sleep 8 ) & holder=$!; sleep 0.5
t0=$(date +%s); agy-hd park "$J" >>"$LOG" 2>&1; dt=$(( $(date +%s) - t0 )); wait $holder
(( dt >= 7 )) && [[ $(st "$J") == gone ]] && ok "L1 park chờ khoá được nhả (${dt}s) rồi mới park" || bad "L1 (chờ ${dt}s, state $(st "$J"))"
agy-hd resume "$J" >>"$LOG" 2>&1

# L2: switch và park cùng lúc trên một job → chạy lần lượt, không lỗi
echo "--- L2" >>"$LOG"
J=${JOBS[1]}; TO=$(sed -n 's/^PROFILE=//p' ~/.cache/agy-hd/$J/meta.env | tail -1)   # switch về chính account của nó: chỉ kiểm khoá, không cần account thứ hai
( agy-hd switch "$J" "$TO" >"$S/l2a.out" 2>&1 ) & a=$!; sleep 0.3; ( agy-hd park "$J" >"$S/l2b.out" 2>&1 ) & b=$!; wait $a; ra=$?; wait $b; rb=$?
cat "$S/l2a.out" "$S/l2b.out" >>"$LOG"
(( ra == 0 && rb == 0 )) && grep -q 'đã chuyển' "$S/l2a.out" && grep -q 'đã park' "$S/l2b.out" && [[ $(st "$J") == gone ]] \
  && ok "L2 switch + park cùng lúc: chạy lần lượt (switch xong rồi park), không lỗi" || bad "L2 (rc switch=$ra park=$rb; $(tail -1 "$S/l2a.out"); $(tail -1 "$S/l2b.out"))"

# H2: park cả 4 rồi resume cả 4 CÙNG LÚC, trong khi tick chạy liên tục
echo "--- H2" >>"$LOG"
for j in "${JOBS[@]}"; do agy-hd park "$j" >>"$LOG" 2>&1; done
( for i in $(seq 6); do agy-hd tick >/dev/null 2>&1; sleep 2; done ) & ticker=$!
for j in "${JOBS[@]}"; do ( agy-hd resume "$j" >"$S/res-$j.out" 2>&1 ) & done; wait $(jobs -p | grep -v "^$ticker$") 2>/dev/null; sleep 1
good=0; for j in "${JOBS[@]}"; do cat "$S/res-$j.out" >>"$LOG"; grep -q 'đã mở lại' "$S/res-$j.out" && good=$((good+1)); done
wait $ticker 2>/dev/null
(( good == 4 )) && ok "H2 resume 4 job cùng lúc + tick chạy song song: 4/4 mở lại" || bad "H2 ($good/4; lỗi: $(grep -h 'thất bại\|lỗi\|bận' "$S"/res-*.out | head -2 | tr '\n' ' '))"
r=0; for j in "${JOBS[@]}"; do o=$(agy-hd prompt "$j" 'Trả lời đúng 1 dòng: AGAIN' -t 180 2>&1); grep -q AGAIN <<<"$(sed -n '/^---$/,$p' <<<"$o")" && r=$((r+1)); done
(( r == 4 )) && ok "H2b sau resume đồng loạt, cả 4 job vẫn nhận prompt và trả lời" || bad "H2b ($r/4 trả lời)"

# H3: đóng hết → tab/workspace/tiến trình
echo "--- H3" >>"$LOG"
ws=$(sed -n 's/^WORKSPACE=//p' ~/.cache/agy-hd/${JOBS[0]}/meta.env)
for j in "${JOBS[@]}"; do agy-hd close "$j" >>"$LOG" 2>&1; done; sleep 3
left=$(for p in $(pgrep -x agy); do [[ $(readlink /proc/$p/cwd) == "$W" ]] && echo "$p"; done)
wsalive=$(H workspace list 2>/dev/null | jq -r --arg w "$ws" '[.result.workspaces[] | select(.workspace_id==$w)] | length')
[[ -z $left ]] && ok "H3 đóng 4 job: không còn agy nào (workspace $ws còn ${wsalive:-?} tab khác của phiên)" || bad "H3 (còn agy: $left)"
echo "=== $pass PASS, $fail FAIL (log: $LOG)"
