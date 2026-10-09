#!/usr/bin/env bash
# Chạy setup.sh + compat-test + agy-p (agy giả, profile giả) trong container của nhiều bản Linux.
#   agy-setup/tests/distro-test.sh [image...]    mặc định: debian:stable-slim fedora:latest alpine:latest archlinux:latest
# Cần docker. Mỗi container dùng một bản sao repo; herdr được cài thật bằng script chính thức, agy thì bỏ qua (~200 MB).
set -uo pipefail
here=$(cd -P "$(dirname "$0")" && pwd); repo=$(cd -P "$here/../.." && pwd)
imgs=("$@"); [[ ${#imgs[@]} -gt 0 ]] || imgs=(debian:stable-slim fedora:latest alpine:latest archlinux:latest)
W=$(mktemp -d "${TMPDIR:-/tmp}/agy-distro.XXXXXX"); trap 'rm -rf "$W"' EXIT
for s in agy-subagent agy-parallel agy-review claude-task-id agy-accounts agy-login agy-quota agy-switch agy-setup; do
  [[ -d $repo/$s ]] && { mkdir -p "$W/repo/$s"; cp -a "$repo/$s/." "$W/repo/$s/"; }; done
for img in "${imgs[@]}"; do n=${img%%:*}; n=${n##*/}
  ( timeout 900 docker run --rm --cpus 1 --memory 1g -v "$W/repo:/repo" -v "$here/in-container.sh:/t.sh:ro" "$img" sh /t.sh >"$W/$n.out" 2>&1 ) &
done; wait
bad=0
for img in "${imgs[@]}"; do n=${img%%:*}; n=${n##*/}
  p=$(grep -c '^RESULT [^ ]* PASS' "$W/$n.out"); f=$(grep -c '^RESULT [^ ]* FAIL' "$W/$n.out"); bad=$((bad + f))
  echo "== $img: $p PASS, $f FAIL"; grep '^RESULT [^ ]* FAIL' "$W/$n.out" | sed 's/^RESULT /   /' | cut -c1-170
done
(( bad == 0 ))
