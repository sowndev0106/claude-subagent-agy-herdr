---
name: agy-quota
description: Show how much Antigravity quota (Gemini and Claude, weekly and 5-hour limits, reset times) is left on the current agy account and on every agy-p account, as a visual dashboard (Artifact), a live terminal view, or a table; also which account plain agy and agy-p use right now and which account new agy-hd jobs will pick. Use when the user says "xem limit", "xem quota", "còn bao nhiêu quota", "account nào còn quota", "dashboard quota", "account hiện tại là gì", "agy hết quota chưa", "khi nào hồi quota".
---

# agy-quota: xem limit các account agy

Lệnh nền: `agy-p` (skill agy-accounts). Quota lấy bằng `/usage` của từng profile, chạy song song (~6 s).

## Chọn cách hiện

| Người dùng muốn | Làm |
|---|---|
| Nhìn trực quan, đẹp | `agy-p dash --no-open --fragment <scratchpad>/agy-quota-board.html`, rồi đăng file đó bằng Artifact (cùng đường dẫn để giữ URL cũ) và đưa link |
| Mở trên máy họ | `agy-p dash` (mở trình duyệt; file ở `~/.agy-profiles/dashboard.html`) |
| Xem liên tục trong terminal | người dùng tự chạy `agy-p top` (`-i 60` làm mới mỗi 60 s, Ctrl+C thoát) |
| Bảng nhanh trong chat | `agy-p usage` |
| "Account hiện tại là gì" | `agy-p whoami`: account của agy-p ở terminal đó, account của `agy` trần, quota |
| Job agy-hd đang chạy trên account nào | `agy-hd accounts` |

Số liệu để script đọc: `agy-p usage --tsv [--max-age giây]`: profile, email, Gemini tuần, Gemini 5 giờ, Claude tuần,
Claude 5 giờ (%, `-1` = không đọc được, `-2` = không có gói), rồi 4 giờ hồi (UTC ISO).

## Đọc số cho đúng

- Có hai giới hạn: **tuần** và **5 giờ**. Job agy chỉ chạy được khi cả hai còn. agy-hd dùng min(tuần, 5 giờ) của Gemini.
- Cockpit Tools chỉ hiện giới hạn 5 giờ, nên có thể ghi 100% trong khi giới hạn tuần chỉ còn 39%.
- Nhiều profile cùng email là **một** account, dùng chung quota. Dashboard gộp chúng vào một thẻ.
- Dưới 5% Gemini: agy-hd không tự chọn account đó (`AGY_MIN_QUOTA`).
- Báo giờ hồi theo giờ máy; dashboard tự đếm ngược.

## Khi báo cho người dùng

Nêu account mặc định và account mà job mới sẽ chạy, account nào đã hết và giờ hồi gần nhất. Nếu account mặc định
đã hết quota 5 giờ, gợi ý `agy-p switch --auto` (skill agy-switch).
