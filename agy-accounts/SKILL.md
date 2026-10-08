---
name: agy-accounts
description: Manage several Google accounts for agy (Antigravity CLI) as agy-p profiles - log in without opening the agy UI (user only clicks a link and sends back the code), list accounts, check each account's Gemini/Claude quota, set the default account, remove accounts, and run agy or agy-hd jobs on a chosen or auto-picked account. Use when the user says "thêm account agy", "đăng nhập agy", "login account", "xem quota agy", "account nào còn quota", "đổi account mặc định", "xoá account agy", "agy hết quota", "chạy bằng account X", or mentions agy-p / profile.
---

# agy-accounts: nhiều account cho agy

Lệnh: `agy-p` (symlink trong PATH, nguồn `scripts/agy-p.sh`). Mỗi account là một **profile**:
`~/.agy-profiles/<tên>`; profile `main` là `~/.gemini`. Token riêng ở `<profile>/antigravity-cli/antigravity-oauth-token`,
agy tự refresh. Skills/plugins/MCP và **hội thoại dùng chung** mọi profile, nên resume sang account khác được.

## Quick start

```bash
agy-p ls                      # profile + email, * = mặc định
agy-p usage                   # quota Gemini/Claude tuần + 5 giờ của từng account (~6 s, chạy song song)
agy-p default work            # đổi account mặc định (chỉ áp cho lần chạy MỚI)
agy-p work -p "..."           # chạy agy bằng account đó
agy-hd start -u work …        # job agy-hd trên account đó; bỏ -u = tự chọn (skill agy-subagent)
```

## Đăng nhập account mới (workflow)

Không có lệnh login của agy; `agy-p add` chạy agy trong pty ẩn, không mở UI ở đâu cả.

1. Chạy nền (Bash `run_in_background: true`), mỗi account một lệnh, chạy song song được:
   `agy-p add`  → in `Phiên đăng nhập: <id>` và `URL: https://accounts.google.com/...`
2. Đợi dòng `Chờ mã:` trong output, đưa **link** cho người dùng, đánh nhãn A/B nếu nhiều link.
   Link luôn hiện bảng chọn account (`prompt=select_account`).
3. Người dùng gửi lại mã (dạng `4/0A...`). **Mỗi mã chỉ hợp với đúng link của nó.** Chạy:
   `agy-p code <id> <mã>` → `Profile '<tên>' đã đăng nhập: <email>`.
   Tên profile tự đặt theo email (phần trước @). Account đã có profile thì báo trùng và bỏ.
4. Phiên chờ mã tối đa 15 phút; hết giờ thì chạy lại `agy-p add`.

Người dùng tự làm trong terminal của họ: `agy-p add` (gõ mã vào khi được hỏi).
Dự phòng khi luồng ẩn hỏng: `agy-p add -i` mở UI agy.

## Chọn account tự động (`agy-p pick`)

Dùng bởi agy-hd và agy-sub khi không có `-u`:
- Ưu tiên profile mặc định nếu còn ≥ `AGY_DEFAULT_MIN` (20)% quota Gemini và đang chạy < `AGY_DEFAULT_MAXJOBS` (2) job.
- Không thì chọn account có điểm cao nhất: quota Gemini (min của tuần và 5 giờ) / (1 + số job đang mở).
- Account dưới `AGY_MIN_QUOTA` (5)% bị loại. Nhiều profile cùng email tính là một account.
- Quota lấy từ cache `~/.agy-profiles/.usage.tsv` (5 phút). `agy-p usage --tsv --max-age 0` để làm mới.

Hết quota giữa chừng: tick của agy-hd chuyển job sang account khác và resume đúng conversation (skill agy-subagent).

## Quy tắc

- Đổi account mặc định bằng `agy-p default`. **Không** `/logout` + `/login` trong `~/.gemini` khi còn phiên agy khác
  đang chạy trên `~/.gemini`: phiên cũ refresh token và **ghi đè lại account cũ** (đo 2026-10-08: đổi lúc 16:00, bị ghi lại 16:09).
- Không chép token từ Cockpit/keyring sang profile khi người dùng muốn login thật; mặc định đi luồng `agy-p add`.
- `agy-p rm` chỉ xoá token/settings/log của profile; hội thoại ở kho chung vẫn còn.
- Tab/workspace herdr cho agy luôn ở session `cas` (dùng agy-hd), không mở trong session của người dùng.

## Cơ chế (khi cần sửa)

- agy chọn chỗ lưu token: có biến `SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY` → file trong gemini dir; không có → gnome-keyring
  `service=gemini user=antigravity`, **một mục dùng chung cho mọi gemini dir**. agy-p luôn đặt `SSH_CONNECTION` để mỗi
  profile dùng file của nó.
- Cờ ẩn `--gemini_dir=<đường dẫn tuyệt đối>` (không có trong `agy --help`) dời toàn bộ dữ liệu agy. Có thể mất sau `agy update`:
  kiểm bằng `agy-p <profile mới> models` → phải báo "Please sign in" khi chưa đăng nhập.
- `agy-p env <tên>` in lệnh export (token + shim `scripts/shim/agy` đầu PATH) để shell / pane herdr chạy `agy` bằng profile đó.
  agy-hd dùng nó trước `herdr agent start`. Shim làm lệnh `agy` lồng bên trong cũng dùng đúng profile.
- Profile mới được chép cờ "đã setup" (`jetski_state.pbtxt`, `antigravity_state.pbtxt`, `cache/onboarding.json`) từ main,
  nên không phải qua màn hình chọn theme / điều khoản.
- Login: `scripts/login.py` lái TUI agy trong pty rộng 4000 cột, bấm "Google OAuth", lấy link, nhận mã qua FIFO
  `<profile>/.login-code`, chờ token rồi tắt agy.
