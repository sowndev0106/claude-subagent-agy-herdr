#!/bin/sh
# Chạy trong container (root). /repo = bản sao bộ skill. In "RESULT <bước> PASS|FAIL".
R=/repo; S=$R/agy-setup/scripts/setup.sh
res() { echo "RESULT $1 $2${3:+ ($3)}"; }

# 1. check bằng sh (máy chưa có bash: setup tự cài bash)
sh $S check >/tmp/check.out 2>&1; rc=$?
grep -q '== Linux' /tmp/check.out && command -v bash >/dev/null && res check-bằng-sh PASS "rc=$rc, có bash $(bash -c 'echo $BASH_VERSION' | cut -d. -f1-2)" || res check-bằng-sh FAIL "$(tail -3 /tmp/check.out | tr '\n' ' ')"

# 2. fix: gói hệ thống + herdr (script chính thức); agy bỏ qua (tải ~200 MB)
AGY_SETUP_SKIP="agy" sh $S fix -y >/tmp/fix.out 2>&1
export PATH="$HOME/.local/bin:$PATH"
for c in git jq python3 perl curl pgrep; do command -v $c >/dev/null || miss="$miss $c"; done
[ -z "$miss" ] && res fix-gói PASS || res fix-gói FAIL "thiếu:$miss"
if command -v herdr >/dev/null && herdr --version >/dev/null 2>&1; then res fix-herdr PASS "$(herdr --version)"
elif command -v herdr >/dev/null; then res fix-herdr FAIL "đã tải nhưng không chạy được: $(herdr --version 2>&1 | head -1)"
else res fix-herdr FAIL "$(grep -i herdr /tmp/fix.out | tail -2 | tr '\n' ' ')"; fi
[ -L $HOME/.claude/skills/agy-setup ] && [ -L $HOME/.local/bin/agy-p ] && res fix-symlink PASS || res fix-symlink FAIL
curl -fsSIL https://antigravity.google/cli/install.sh -o /dev/null && res agy-installer-url PASS || res agy-installer-url FAIL

# 3. compat: nhánh native và nhánh tương thích
bash $R/agy-setup/tests/compat-test.sh >/tmp/c1.out 2>&1 && res compat-native PASS "$(tail -1 /tmp/c1.out)" || res compat-native FAIL "$(grep FAIL /tmp/c1.out | head -3 | tr '\n' ' ')"
AGY_COMPAT_FORCE=1 bash $R/agy-setup/tests/compat-test.sh >/tmp/c2.out 2>&1 && res compat-tương-thích PASS "$(tail -1 /tmp/c2.out)" || res compat-tương-thích FAIL "$(grep FAIL /tmp/c2.out | head -3 | tr '\n' ' ')"

# 4. agy-p với agy giả + profile giả (không mạng, không token thật)
cat >$HOME/.local/bin/agy <<'EOF'
#!/bin/sh
case "$*" in
  *--version*) echo "1.3.2-stub" ;;
  *"-p /usage"*) for a in "$@"; do case $a in --gemini_dir=*) d=${a#--gemini_dir=} ;; esac; done
    if [ -f "$d/antigravity-cli/antigravity-oauth-token" ]; then
      printf 'Gemini Models\tWeekly Limit Remaining\t70%%\t2026-10-12T10:00:00Z\nGemini Models\tFive Hour Limit Remaining\t90%%\t2026-10-09T13:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t40%%\t2026-10-13T03:00:00Z\nClaude and GPT models\tFive Hour Limit Remaining\tdisabled\t\n'
    else echo "Error: Please sign in to view available models."; fi ;;
  *models*) echo "Error: Please sign in to view available models." ;;
  *) echo "agy stub" ;;
esac
EOF
chmod +x $HOME/.local/bin/agy
P=$HOME/.agy-profiles/work/antigravity-cli; mkdir -p $P
python3 - "$P/antigravity-oauth-token" <<'EOF'
import base64, json, sys
b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
tok = {"token": {"access_token": "x", "token_type": "Bearer", "refresh_token": "y", "expiry": "2030-01-01T00:00:00Z"},
       "auth_method": "consumer", "id_token": b({"alg": "none"}) + "." + b({"email": "work@example.com"}) + ".sig"}
open(sys.argv[1], "w").write(json.dumps(tok))
EOF
chmod 600 $P/antigravity-oauth-token; mkdir -p $HOME/.gemini/config $HOME/.gemini/antigravity-cli
agy-p ls >/tmp/p.out 2>&1 && grep -q 'work@example.com' /tmp/p.out && res agy-p-ls PASS || res agy-p-ls FAIL "$(tail -2 /tmp/p.out | tr '\n' ' ')"
agy-p usage --tsv --max-age 0 >/tmp/u.out 2>&1 && grep -qP '^work\twork@example.com\t70\t90' /tmp/u.out 2>/dev/null || grep -q "^work	work@example.com	70	90" /tmp/u.out && res agy-p-usage PASS || res agy-p-usage FAIL "$(cat /tmp/u.out | tr '\n' ' ')"
[ "$(agy-p pick 2>/dev/null)" = work ] && res agy-p-pick PASS || res agy-p-pick FAIL "$(agy-p pick 2>&1)"
eval "$(agy-p env work)" && [ "$AGY_GEMINI_DIR" = "$HOME/.agy-profiles/work" ] && res agy-p-env PASS || res agy-p-env FAIL
agy-p dash --no-open >/tmp/d.out 2>&1 && grep -q 'work@example.com' $HOME/.agy-profiles/dashboard.html && res agy-p-dash PASS || res agy-p-dash FAIL "$(tail -1 /tmp/d.out)"
agy-p completion bash | bash -n && res agy-p-completion PASS || res agy-p-completion FAIL
agy-p doctor --fix >/tmp/doc.out 2>&1; grep -qE '^[0-9]+ lỗi, [0-9]+ cảnh báo' /tmp/doc.out && res agy-p-doctor-fix PASS "$(grep -E '^[0-9]+ lỗi' /tmp/doc.out)" || res agy-p-doctor-fix FAIL "$(tail -3 /tmp/doc.out | tr '\n' ' ')"
agy-hd khong-co-lenh 2>&1 | grep -q 'agy-hd start' && res agy-hd-help PASS || res agy-hd-help FAIL "$(agy-hd khong-co-lenh 2>&1 | tail -2 | tr '\n' ' ')"
