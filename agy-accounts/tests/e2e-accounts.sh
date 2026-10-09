#!/usr/bin/env bash
# E2E nhiều account cho agy-hd + agy-p + agy-sub, chạy trong herdr session cas (gọi agy thật, ~15 phút).
# In PASS/FAIL từng mục (D1..D10), cuối cùng đóng mọi job đã tạo và kiểm không còn tiến trình sót.
#   E2E_ACCOUNT=<profile còn quota>      mặc định: agy-p pick
#   E2E_EXHAUSTED=<profile hết quota>     D4 dùng quota hết thật (tick tự restart); không có thì D4 gọi agy-hd restart như tick
set -uo pipefail
S=$(mktemp -d "${TMPDIR:-/tmp}/agy-e2e.XXXXXX"); W=$S/work; mkdir -p "$W"; LOG=$S/e2e.log; : >"$LOG"
A=${E2E_ACCOUNT:-$(agy-p pick)}; AE=$(agy-p email "$A"); EXH=${E2E_EXHAUSTED:-}
[[ -n $AE ]] || { echo "E2E_ACCOUNT '$A' chưa đăng nhập"; exit 2; }
echo "account chính: $A ($AE); account hết quota: ${EXH:-không có, D4 gọi agy-hd restart}; log: $LOG"
JOBS=(); pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
jobof() { sed -n 's/^JOB=//p' <<<"$1" | head -1; }
acct()  { sed -n 's/^ACCOUNT=\([^ ]*\).*/\1/p' <<<"$1" | head -1; }
meta()  { sed -n "s/^$2=//p" ~/.cache/agy-hd/$1/meta.env | tail -1; }
say()   { echo "--- $*" | tee -a "$LOG" >/dev/null; }

# D1: -u + subagent (sleep 15) → start chỉ trả về khi subagent xong
say D1; o=$(agy-hd start -n e2e-d1 -d "$W" -u $A -t 300 -p 'Dùng tool invoke_subagent tạo đúng 1 subagent. Subagent chạy lệnh shell (chờ xong, không chạy nền): sleep 15; echo SUB PROFILE=$AGY_PROFILE_ACTIVE  và trả về nguyên văn. Sau khi có kết quả subagent, trả lời đúng 1 dòng: D1 <output của subagent>' 2>&1); echo "$o" >>"$LOG"
J1=$(jobof "$o"); JOBS+=("$J1")
[[ $(acct "$o") == $A ]] && grep -q "D1 SUB PROFILE=$A" <<<"$o" && grep -q 'STATUS=DONE' <<<"$o" \
  && ok "D1 -u $A + subagent: start chờ subagent xong, đúng account" || bad "D1 ($(acct "$o"); $(grep -oE 'D1 .*' <<<"$o" | head -1))"

# D2: tự chọn → account báo về khớp ACCOUNT
say D2; pick=$(agy-p pick 2>/dev/null); o=$(agy-hd start -n e2e-d2 -d "$W" -t 240 -p 'Chạy lệnh shell echo $AGY_PROFILE_ACTIVE rồi trả lời đúng 1 dòng: D2 PROFILE=<output>' 2>&1); echo "$o" >>"$LOG"
J2=$(jobof "$o"); JOBS+=("$J2"); a=$(acct "$o")
[[ -n $a ]] && grep -q "D2 PROFILE=$a" <<<"$o" && ok "D2 tự chọn: $a (agy-p pick trước đó: $pick), agy báo đúng" || bad "D2 (ACCOUNT=$a, $(grep -oE 'D2 .*' <<<"$o"))"

# D3: fan 4 task không -u → chia account, mỗi task tự báo đúng account của nó
say D3; F=$S/e2e-fan3; rm -rf "$F"; mkdir -p "$F/tasks"
for k in 1 2 3 4; do echo "Chạy lệnh shell echo \$AGY_PROFILE_ACTIVE rồi trả lời đúng 1 dòng: D3 task$k PROFILE=<output>" >"$F/tasks/t$k.md"; done
agy-hd fan -i "$F/tasks" -o "$F/res" -j 4 -d "$W" -t 240 >>"$LOG" 2>&1
good=0; accts=""
for k in 1 2 3 4; do a=$(sed -n 's/^ACCOUNT=\([^ ]*\).*/\1/p' "$F/res/t$k.out" | head -1); accts="$accts $a"
  grep -q "D3 task$k PROFILE=$a" "$F/res/t$k.out" && good=$((good+1)); JOBS+=("$(jobof "$(cat "$F/res/t$k.out")")"); done
# kỳ vọng: account thứ hai đủ quota (≥ 1/4 account tốt nhất) thì phải chia ≥ 2 account; không thì dồn 1 account là đúng
read -r best second < <(agy-p usage --tsv --max-age 600 | awk -F'\t' '$2!="-"{q=($3<$4?$3:$4); if(!(($2) in s) || q>s[$2]) s[$2]=q} END{for(e in s) if(s[e]>=5) print s[e]}' | sort -rn | head -2 | tr '\n' ' ')
nacc=$(tr ' ' '\n' <<<"$accts" | grep -v '^$' | sort -u | wc -l); want=1; [[ -n ${second:-} ]] && (( second * 4 >= best )) && want=2
(( good == 4 && nacc >= want )) && ok "D3 fan 4 task: chia cho${accts} (quota tốt nhất ${best}%, kế tiếp $([[ -n ${second:-} ]] && echo "${second}%" || echo không có): cần ≥ $want account); 4/4 tự báo đúng" \
  || bad "D3 ($good/4 đúng; account:$accts; cần ≥ $want account)"

# D4: hết quota → đổi account, cùng conversation.
#  - E2E_EXHAUSTED đặt và account đó thật sự hết quota (< 5%): job chạy trên nó, tick tự phát hiện và restart.
#  - Không thì gọi thẳng `agy-hd restart` (đúng hàm tick gọi khi thấy QUOTA) cho một job đang chạy trên $A.
say D4
q_of() { agy-p usage --tsv --max-age 0 | awk -F'\t' -v p="$1" '$1==p { print ($3<$4?$3:$4) }'; }
OTH=$(agy-p pick --exclude-email "$AE" 2>/dev/null) || OTH=""
P4='Lần đầu: trả lời đúng 1 dòng: D4 START. Khi được bảo làm tiếp: chạy lệnh shell echo $AGY_PROFILE_ACTIVE rồi trả lời đúng 1 dòng: D4 PROFILE=<output>'
if [[ -n $EXH && $(q_of "$EXH") -lt 5 ]]; then MODE="quota hết thật, tick tự restart"; SRC=$EXH
elif [[ -n $OTH ]]; then MODE="agy-hd restart như tick"; SRC=$A
else MODE=""; fi
if [[ -z $MODE ]]; then echo "SKIP  D4 (cần một account khác còn quota để chuyển sang)"
else
  o=$(agy-hd start -n e2e-d4 -d "$W" -u "$SRC" -t 180 -p "$P4" 2>&1); echo "$o" >>"$LOG"
  J4=$(jobof "$o"); JOBS+=("$J4"); c0=$(agy-hd access "$J4" 2>/dev/null | grep -oE 'brain/[0-9a-f-]{36}' | head -1)
  [[ $SRC == "$A" ]] && agy-hd restart "$J4" >>"$LOG" 2>&1
  for i in $(seq 72); do agy-hd result "$J4" 2>/dev/null | grep -q 'D4 PROFILE=' && break; sleep 5; done
  r=$(agy-hd result "$J4" 2>/dev/null | grep -oE 'D4 PROFILE=[^ ]*' | head -1); p4=$(meta "$J4" PROFILE); rs=$(meta "$J4" RESTARTS)
  c1=$(agy-hd access "$J4" 2>/dev/null | grep -oE 'brain/[0-9a-f-]{36}' | head -1)
  [[ -n $r && ${r#D4 PROFILE=} == "$p4" && $p4 != "$SRC" && ${rs:-0} -ge 1 && -n $c0 && $c0 == "$c1" && -z $(meta "$J4" RESTARTING) ]] \
    && ok "D4 hết quota ($MODE): $SRC → $p4 sau $rs lần restart, cùng conversation ${c1#brain/}" \
    || bad "D4 ($MODE: result=$r, PROFILE=$p4, RESTARTS=$rs, conv $c0 → $c1)"
fi

# D5: agy-hd switch D1 sang account khác còn quota (không có thì cùng account), vẫn nhớ câu trả lời cũ
say D5; OTHER=$(agy-p pick --exclude-email $AE 2>/dev/null) || OTHER=$A
agy-hd switch "$J1" "$OTHER" >>"$LOG" 2>&1
o=$(agy-hd prompt "$J1" 'Chạy lại lệnh shell echo $AGY_PROFILE_ACTIVE rồi trả lời đúng 2 dòng: dòng 1 "D5 PROFILE=<output>", dòng 2 nhắc lại nguyên văn dòng D1 bạn đã trả lời trước đó' -t 240 2>&1); echo "$o" >>"$LOG"
grep -q "D5 PROFILE=$OTHER" <<<"$o" && grep -q "D1 SUB PROFILE=$A" <<<"$o" \
  && ok "D5 agy-hd switch $A → $OTHER$([[ $OTHER == $A ]] && echo ' (không còn account khác có quota: kiểm cơ chế trên cùng account)'), conversation giữ nguyên" || bad "D5 ($(grep -oE 'D[15] .*' <<<"$o" | tr '\n' ' '))"

# D6: park + resume giữ account
say D6; agy-hd park "$J1" >>"$LOG" 2>&1; agy-hd resume "$J1" >>"$LOG" 2>&1
o=$(agy-hd prompt "$J1" 'Chạy lệnh shell echo $AGY_PROFILE_ACTIVE rồi trả lời đúng 1 dòng: D6 PROFILE=<output>' -t 180 2>&1); echo "$o" >>"$LOG"
grep -q "D6 PROFILE=$OTHER" <<<"$o" && ok "D6 park + resume ngay lập tức, giữ account $OTHER" || bad "D6 ($(grep -oE 'D6 .*' <<<"$o"))"

# D7: agy lồng trong job chạy cùng account (log mới ở profile của job, không ở ~/.gemini)
say D7; PD=$( [[ $OTHER == main ]] && echo ~/.gemini || echo ~/.agy-profiles/$OTHER ); L0=$(ls $PD/antigravity-cli/log | wc -l); M0=$(ls ~/.gemini/antigravity-cli/log)
o=$(agy-hd prompt "$J1" "Chạy đúng lệnh shell này (chờ xong) rồi trả lời đúng 1 dòng 'D7 OK' kèm output: agy -p 'Reply with exactly: NESTED' --output-format json --print-timeout 90s" -t 240 2>&1); echo "$o" >>"$LOG"
L1=$(ls $PD/antigravity-cli/log | wc -l)
leak=$(comm -13 <(echo "$M0") <(ls ~/.gemini/antigravity-cli/log) | while read -r f; do grep -lq "$W" ~/.gemini/antigravity-cli/log/"$f" 2>/dev/null && echo "$f"; done)
[[ $OTHER == main ]] && leak=""   # job đang ở profile main (= ~/.gemini): log của agy lồng nằm ở đó là đúng
grep -q 'NESTED' <<<"$o" && (( L1 > L0 )) && [[ -z $leak ]] && ok "D7 agy lồng chạy bằng profile của job (log mới: $((L1-L0)) ở $OTHER, 0 ở ~/.gemini)" || bad "D7 (NESTED? $(grep -c NESTED <<<"$o"); log mới profile=$((L1-L0)); rò sang main: ${leak:-0})"

# D8: agy-sub -u và tự chọn
say D8; o=$(agy-sub -n e2e-d8a -u $A -d "$W" -t 180 -p 'Chạy lệnh shell echo $AGY_PROFILE_ACTIVE rồi trả lời đúng 1 dòng: D8 PROFILE=<output>' 2>&1); echo "$o" >>"$LOG"
o2=$(agy-sub -n e2e-d8b -d "$W" -t 180 -p 'Chạy lệnh shell echo $AGY_PROFILE_ACTIVE rồi trả lời đúng 1 dòng: D8 PROFILE=<output>' 2>&1); echo "$o2" >>"$LOG"; a2=$(acct "$o2")
grep -q "D8 PROFILE=$A" <<<"$o" && grep -q "D8 PROFILE=$a2" <<<"$o2" && ok "D8 agy-sub -u $A đúng; tự chọn → $a2 đúng" || bad "D8 ($(grep -oE 'D8 .*' <<<"$o$o2" | tr '\n' ' '))"

# D9: agy-hd accounts liệt kê job đang mở theo account
say D9; o=$(agy-hd accounts 2>&1); echo "$o" >>"$LOG"
grep -q "$J1" <<<"$o" && ok "D9 agy-hd accounts thấy job $J1 (kể cả khi đã xong) dưới account của nó" || bad "D9 (không thấy $J1)"

# D10: đóng hết, không còn tiến trình
say D10; for j in "${JOBS[@]}"; do [[ -n $j ]] && agy-hd close "$j" >>"$LOG" 2>&1; done; sleep 3
left=$(for p in $(pgrep -x agy); do [[ $(readlink /proc/$p/cwd) == "$W" ]] && echo "$p"; done)
[[ -z $left ]] && ok "D10 đóng ${#JOBS[@]} job, không còn agy nào trong thư mục test" || bad "D10 (còn: $left)"
echo "=== $pass PASS, $fail FAIL (log: $LOG)"
