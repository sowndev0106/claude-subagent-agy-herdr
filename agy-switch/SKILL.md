---
name: agy-switch
description: Switch which Google account agy (Antigravity CLI) uses - the default account for new runs and agy-hd jobs, just the current terminal, a single running agy-hd job (keeps its conversation), or automatically the account with the most quota left. Use when the user says "switch default", "đổi account mặc định", "chuyển account", "dùng account X", "chuyển job sang account khác", "account này hết quota rồi", "chạy bằng account còn quota", or wants agy to stop using an exhausted account.
---

# agy-switch: đổi account agy

Lệnh nền: `agy-p` và `agy-hd` (skill agy-accounts, agy-subagent). Mỗi account là một profile, hội thoại dùng chung,
nên đổi account không mất ngữ cảnh.

## Đổi ở mức nào

| Phạm vi | Lệnh | Ghi chú |
|---|---|---|
| Mặc định (agy-p, agy-hd, agy-sub chạy MỚI) | `agy-p switch <profile>` | phiên đang chạy giữ account cũ |
| Mặc định = account còn nhiều quota nhất | `agy-p switch --auto` | bỏ qua account dưới 5% Gemini |
| Chỉ terminal hiện tại | `eval "$(agy-p use <profile>)"`; bỏ: `eval "$(agy-p use --unset)"` | đặt `AGY_PROFILE` |
| Một lần chạy | `agy-p <profile> ...` hoặc `agy-p best ...` | `best` = account nhiều quota nhất lúc này |
| Một job agy-hd đang có | `agy-hd switch <job> [profile]` | không ghi profile = account khác còn quota; job đang chạy thì thêm `-f` |
| Job agy-hd mới | `agy-hd start -u <profile> ...` | bỏ `-u` = tự chọn |

Kiểm sau khi đổi: `agy-p whoami` (terminal), `agy-p ls` (dấu * = mặc định), `agy-hd accounts` (job theo account).

## Tự động sẵn có (không cần làm tay)

- `agy-hd start/fan` không có `-u`: ưu tiên account mặc định khi nó còn ≥ 20% và đang chạy < 2 job; không thì
  chọn account có quota / (1 + số job) cao nhất.
- Job hết quota giữa chừng: tick (mỗi phút) chuyển job sang account khác và resume đúng conversation.

## Quy tắc

- Đổi mặc định bằng `agy-p switch` (chỉ đổi con trỏ `~/.agy-profiles/.default`). **Không** `/logout` + `/login`
  trong `~/.gemini`: phiên agy khác đang chạy trên đó sẽ refresh và ghi đè account cũ (đo được: bị ghi lại sau 9 phút).
- `agy` trần không đi qua agy-p: ở terminal có biến SSH nó dùng token trong `~/.gemini`, ở terminal local nó dùng
  gnome-keyring. Muốn `agy` theo account mặc định thì gõ `agy-p` thay cho `agy`.
- Đổi account cho một job chỉ khi job không đang chạy dở, hoặc dùng `-f` (interrupt trước, việc đang làm dở có thể mất).
