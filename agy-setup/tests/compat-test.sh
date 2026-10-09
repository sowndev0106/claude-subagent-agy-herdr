#!/usr/bin/env bash
# Test các hàm của agy-subagent/scripts/compat.sh. Chạy 2 lần để phủ cả hai nhánh:
#   agy-setup/tests/compat-test.sh                    nhánh native (công cụ gốc của máy)
#   AGY_COMPAT_FORCE=1 agy-setup/tests/compat-test.sh  nhánh tương thích (perl/python: như trên macOS/busybox)
set -uo pipefail
here=$(cd -P "$(dirname "$0")" && pwd)
source "$here/../../agy-subagent/scripts/compat.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/agy-compat.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
eq()  { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (mong '$3', được '$2')"; fi; }
echo "== compat ($( [[ -n ${AGY_COMPAT_FORCE:-} ]] && echo 'nhánh tương thích: perl/python' || echo native), $AGY_OS, bash $BASH_VERSION)"

f=$T/a; printf 'x=1\ny=2\n' >"$f"; chmod 640 "$f"
eq "file_mtime" "$(file_mtime "$f")" "$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$f")"
eq "file_mode" "$(file_mode "$f")" "640"
sedi 's/^x=.*/x=9/' "$f"; eq "sedi" "$(tr '\n' ' ' <"$f")" "x=9 y=2 "
eq "fmt_hms" "$(fmt_hms 1700000000)" "$(python3 -c 'import time; print(time.strftime("%H:%M:%S", time.localtime(1700000000)))')"
eq "proc_cwd" "$(cd "$T" && sleep 3 & cd "$T" && sleep 0.3; proc_cwd $!)" "$(cd -P "$T" && pwd)"
sleep 4 & sp=$!; sleep 0.3
[[ $(proc_args $sp) == *"sleep 4"* ]] && ok "proc_args" || bad "proc_args ($(proc_args $sp))"
proc_has_arg $sp 4 && ! proc_has_arg $sp 44 && ok "proc_has_arg (khớp nguyên tham số)" || bad "proc_has_arg"
a=$(proc_age_s $$); [[ $a =~ ^[0-9]+$ ]] && ok "proc_age_s ($a s)" || bad "proc_age_s ($a)"
kill $sp 2>/dev/null
m=$(mem_avail_mb); [[ $m =~ ^[0-9]+$ && $m -gt 0 ]] && ok "mem_avail_mb ($m MB)" || bad "mem_avail_mb ($m)"
s=$(swap_used_pct); [[ $s =~ ^[0-9]+$ && $s -le 100 ]] && ok "swap_used_pct ($s%)" || bad "swap_used_pct ($s)"

# flock: giữ khoá fd 9; tiến trình khác -n phải thất bại, -w 1 hết giờ; nhả xong thì lấy được
L=$T/lock; exec 9>"$L"; flock 9
( exec 8>"$L"; flock -n 8 ) && bad "flock -n lẽ ra phải thất bại khi đang bị giữ" || ok "flock -n khi bị giữ → thất bại"
t0=$(date +%s); ( exec 8>"$L"; flock -w 1 8 ); r=$?; dt=$(( $(date +%s) - t0 ))
(( r != 0 && dt >= 1 && dt <= 3 )) && ok "flock -w 1 hết giờ sau ${dt}s" || bad "flock -w (rc=$r ${dt}s)"
flock -u 9; ( exec 8>"$L"; flock -n 8 ) && ok "flock -u nhả → lấy lại được" || bad "flock -u"
exec 9>&-

t0=$(date +%s); timeout 1 sleep 5; r=$?; dt=$(( $(date +%s) - t0 ))
(( r == 124 && dt <= 4 )) && ok "timeout → 124 sau ${dt}s" || bad "timeout (rc=$r ${dt}s)"
timeout 5 true && ok "timeout lệnh xong sớm → 0" || bad "timeout true"
setsid sh -c "ps -o sid= -p \$\$ >'$T/sid'" </dev/null >/dev/null 2>&1; sleep 1
[[ -s $T/sid && $(tr -d ' ' <"$T/sid") != "$(ps -o sid= -p $$ | tr -d ' ')" ]] && ok "setsid (phiên mới)" || bad "setsid ($(cat "$T/sid" 2>/dev/null))"
eq "tac" "$(printf 'a\nb\nc\n' | tac | tr '\n' ' ')" "c b a "
eq "md5sum" "$(printf abc | md5sum | cut -d' ' -f1)" "900150983cd24fb0d6963f7d28e17f72"
eq "sha256sum" "$(printf abc | sha256sum | cut -d' ' -f1)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
c=$(printf 'a\tbb\nccc\td\n' | column -t -s $'\t'); l1=$(sed -n 1p <<<"$c"); l2=$(sed -n 2p <<<"$c")
[[ ${l1%%bb*} == "a"*" " && ${#l1} -ge 4 && $(( ${#l1} - 2 )) -eq $(( ${#l2} - 1 )) ]] && ok "column -t (thẳng cột)" || bad "column ($(tr '\n' '|' <<<"$c"))"
ln -s "$f" "$T/l1"; ln -s "$T/l1" "$T/l2"; eq "readlink -f (2 tầng symlink)" "$(readlink -f "$T/l2")" "$(cd -P "$T" && pwd)/a"
( AGY_AUTO_REPAIR=0 agy_require sh khong-co-lenh-nay-xyz ) 2>"$T/err"; r=$?
(( r == 2 )) && grep -q 'khong-co-lenh-nay-xyz' "$T/err" && ! grep -q '\bsh\b.*thiếu' "$T/err" && ok "agy_require thiếu lệnh → báo cách sửa, exit 2" || bad "agy_require (rc=$r $(cat "$T/err"))"
( agy_require sh bash ) && ok "agy_require đủ lệnh → chạy tiếp" || bad "agy_require đủ lệnh"
echo "=== $pass PASS, $fail FAIL"; (( fail == 0 ))
