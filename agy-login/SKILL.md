---
name: agy-login
description: Log a Google account into agy (Antigravity CLI) as an agy-p profile without opening the agy UI - on this machine or on a remote machine over ssh - plus re-login of a broken profile and moving a logged-in account between machines (export/import, remote push/pull). Use when the user says "login agy", "đăng nhập account", "thêm account", "login remote", "đăng nhập trên máy khác/server", "relogin", "token hết hạn / bị thu hồi", "chuyển account sang máy khác", or pastes an agy auth code like 4/0A....
---

# agy-login: đăng nhập account cho agy

Lệnh nền: `agy-p` (skill agy-accounts). agy không có lệnh login; `agy-p add` lái giao diện agy trong pty ẩn,
in **link** đăng nhập (luôn hiện bảng chọn account), nhận **mã** người dùng dán lại. Tên profile tự đặt theo email.

## Máy này (mặc định)

1. Chạy nền (Bash `run_in_background: true`), mỗi account một lệnh, song song được: `agy-p add`
2. Đợi output có `Phiên đăng nhập: <id>`, `URL: ...`, `Chờ mã:`. Đưa link cho người dùng, nhiều link thì đánh nhãn A/B.
3. Người dùng gửi mã `4/0A...`: `agy-p code <id> <mã>` → `Profile '<tên>' đã đăng nhập: <email>`.
   **Mỗi mã chỉ hợp với đúng link của nó.** Phiên chờ tối đa 15 phút.
4. Xác nhận: `agy-p ls`. Account trùng với profile đã có thì agy-p từ chối và bỏ lần đăng nhập đó.

Người dùng tự làm trong terminal: `agy-p add` rồi dán mã khi được hỏi. Luồng ẩn hỏng: `agy-p add -i` mở UI agy.

## Máy khác qua ssh ("login remote")

Cần agy và agy-p ở máy kia (cài repo claude-subagent-agy-herdr, chạy `install.sh`). Tuỳ chọn ssh: `AGY_SSH_OPTS="-p 2222"`.

- **Đăng nhập thẳng trên máy kia:** chạy nền `agy-p remote <host> add` → link in ra ở đây. Sau đó
  `agy-p remote <host> code <id> <mã>`. Token nằm trên máy kia, không đi qua máy này.
- **Đã đăng nhập ở máy này, mang sang:** `agy-p remote <host> push <profile>`. Lấy về: `agy-p remote <host> pull <profile>`.
- **Không có ssh:** `agy-p export <profile> file.tgz` → chép file sang → `agy-p import file.tgz`.
  File **chứa token đăng nhập**: quyền 600, xoá sau khi import, không gửi qua chat/kênh công khai.

## Token hỏng hoặc bị thu hồi

Dấu hiệu: `agy-p doctor` báo "không đọc được quota", hoặc agy báo chưa đăng nhập. Chạy `agy-p relogin <profile>`
(chạy nền như bước 1, mã đưa vào bằng `agy-p code <profile> <mã>`). Đăng nhập lại không xong thì token cũ được trả lại.
Profile đang có agy chạy thì relogin từ chối: tắt hoặc park các phiên đó trước.

## Quy tắc

- Không chép token từ Cockpit/gnome-keyring khi người dùng muốn đăng nhập thật.
- Không `/logout` + `/login` trong `~/.gemini` (profile `main`) khi còn phiên agy khác chạy trên nó:
  phiên cũ refresh token và ghi đè account cũ trở lại.
- Mã xác thực dùng một lần, gắn với đúng phiên; đừng thử lại mã cũ cho phiên mới.
