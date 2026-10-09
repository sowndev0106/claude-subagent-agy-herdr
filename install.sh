#!/bin/sh
# install.sh: giữ cho tương thích, gọi bộ cài mới (kiểm + cài + tự sửa): agy-setup/scripts/setup.sh fix
#   ./install.sh [-y]      = agy-setup/scripts/setup.sh fix [-y]
#   ./install.sh check     = agy-setup/scripts/setup.sh check
d=$(cd -P "$(dirname "$0")" && pwd)
case ${1:-} in check) exec sh "$d/agy-setup/scripts/setup.sh" check ;; *) exec sh "$d/agy-setup/scripts/setup.sh" fix "$@" ;; esac
