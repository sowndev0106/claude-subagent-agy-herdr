---
name: agy-setup
description: Install, check and auto-repair the agy subagent suite (agy-hd, agy-sub, agy-fan, agy-ctl, agy-id, agy-p) and its dependencies - bash >= 4.4, git, jq, python3, perl, herdr, agy, skill/command links, the per-minute agy-hd tick scheduler - on Linux (apt/dnf/pacman/zypper/apk), macOS (Homebrew), WSL and Windows (PowerShell). Use when the user says "setup agy", "cài đặt bộ agy", "cài herdr", "cài agy", "máy mới", "chạy trên mac/windows/wsl", or WHENEVER an agy-* command fails with an environment error (command not found, illegal option, bash version, herdr not running, missing token dir, tick not running) - then repair and retry instead of giving up.
---

# agy-setup: cài đặt và tự sửa bộ agy

Script: `scripts/setup.sh` (Linux, macOS, WSL; chạy được cả bằng `sh` trên máy chưa có bash) và `scripts/setup.ps1`
(Windows; `setup.cmd` để bấm đúp). Sau lần cài đầu có lệnh `agy-setup` trong `~/.local/bin`.

## Quick start

```bash
agy-setup check          # hoặc: <repo>/agy-setup/scripts/setup.sh check
agy-setup fix -y         # cài cái thiếu: gói hệ thống, herdr, agy, symlink, lịch tick, PATH
agy-p doctor --fix       # sửa mức account: quyền token, symlink profile, cờ setup, đăng nhập dở, mặc định hỏng
```
Windows: `powershell -ExecutionPolicy Bypass -File agy-setup\scripts\setup.ps1 fix -Yes` (có WSL thì cài luôn bản đầy đủ
trong WSL). Windows thuần chỉ chạy được runner không giao diện (agy-sub/agy-ctl/agy-fan/agy-id .ps1/.cmd).

## Tự sửa lỗi (bắt buộc làm, không chỉ báo lỗi)

Ba tầng, tầng dưới không xong thì lên tầng trên:

1. **Script tự sửa**: các lệnh agy gọi `agy_require` (trong `agy-subagent/scripts/compat.sh`). Thiếu công cụ thì tự chạy
   `setup.sh fix -y` một lần (tối đa 1 lần/giờ, log `~/.cache/agy-setup/repair.log`), rồi chạy tiếp. Tắt: `AGY_AUTO_REPAIR=0`.
2. **Claude sửa** khi một lệnh agy-* lỗi (đọc dòng lỗi trước):
   | Dấu hiệu | Làm |
   |---|---|
   | `command not found`, `thiếu <lệnh>`, `cần bash >= 4.4` | `agy-setup check` → `agy-setup fix -y` → chạy lại lệnh |
   | in `sudo apt-get install ...` / cần sudo | đưa đúng lệnh đó cho người dùng chạy bằng `! sudo ...`, rồi `agy-setup fix -y` lại |
   | `herdr server không chạy` | `agy-hd init` (dựng session cas) rồi chạy lại |
   | profile/token/symlink/`AGY_PROFILE` hỏng | `agy-p doctor --fix` → `agy-p doctor` |
   | `cờ ẩn --gemini_dir không còn tác dụng` (sau `agy update`) | dừng dùng nhiều account, báo người dùng: agy đổi cơ chế, cần sửa agy-p |
   | lỗi khác trong script (`illegal option`, `stat:`, `sed:`, `/proc`...) trên OS mới | sang bước 3 |
3. **Sửa script** khi lỗi do khác biệt hệ điều hành: thêm/sửa hàm trong `compat.sh` (luôn có nhánh native + nhánh perl/python),
   thay call site bằng hàm đó, chạy `AGY_COMPAT_FORCE=1 agy-setup/tests/compat-test.sh` (ép nhánh tương thích) và
   `agy-setup/tests/compat-test.sh`, rồi các bộ test hồi quy (`agy-accounts/tests/*.sh`, `agy-subagent/scripts/selftest.sh`).
   Ghi lại lỗi + cách sửa trong commit.

Sau khi sửa: luôn chạy lại đúng lệnh ban đầu để chứng minh đã hết lỗi.

## Hỗ trợ hệ điều hành

| Nền | Cài gói | Lịch tick | Ghi chú |
|---|---|---|---|
| Ubuntu/Debian, Fedora/RHEL, Arch, openSUSE, Alpine | apt / dnf, yum / pacman / zypper / apk | systemd user timer, không có thì cron | Alpine: setup tự cài bash; agy cần glibc |
| macOS (Intel, Apple silicon) | Homebrew (`bash`, `jq`, `herdr`, `flock`, `coreutils`) | launchd `dev.agy.hd-tick` | bash 3.2 mặc định: script tự chạy lại bằng bash của Homebrew |
| WSL | như Linux | systemd nếu bật, không thì cron | setup.ps1 gọi setup.sh trong WSL |
| Windows thuần | winget (git, jq, python) + script chính thức (agy, herdr) | không có (agy-hd cần WSL) | runner `.ps1` không giao diện |

`compat.sh` thay các công cụ chỉ có trên GNU/Linux: `/proc`, `stat -c`, `sed -i`, `date -d`, `free`, `ps etimes`,
`readlink -f`, `find -printf`; giả lập `flock`, `timeout`, `setsid`, `tac`, `md5sum`, `sha256sum`, `column` khi máy thiếu.

## Quy tắc

- Cài gói hệ thống cần sudo: chỉ tự cài khi là root hoặc sudo không cần mật khẩu; không thì đưa lệnh cho người dùng.
- herdr và agy cài vào thư mục user (`~/.local/bin`) bằng script chính thức: được tự cài khi người dùng đã nhờ setup/sửa.
- Không chép token hay đăng nhập thay người dùng: đăng nhập vẫn qua `agy-p add` (skill agy-login).
- Tab herdr cho agy luôn ở session `cas`.
