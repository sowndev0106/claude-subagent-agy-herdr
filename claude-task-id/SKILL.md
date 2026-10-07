---
name: claude-task-id
description: Give every Claude Code session a 3-digit task number plus a short name, like "#132 Đánh giá engine gợi ý", and carry it into herdr so the session's workspace is labelled exactly that. Use at the START of any Claude Code task, and always before spawning agy subagents (agy-hd), or when the user mentions "đánh số", "ID phiên", "#132", "đặt tên workspace/space", "rename space", or wants sessions easy to tell apart in herdr.
---

# Số + tên cho mỗi phiên Claude Code

Mỗi phiên Claude Code mang một nhãn dạng **`#132 Đánh giá engine gợi ý`** (số 3 chữ số, cấp tuần tự 100..999,
dùng chung giữa mọi phiên trên máy, không cấp trùng kể cả khi nhiều phiên khởi động cùng lúc). Nhãn này là tên
workspace của phiên đó trong herdr (session `cas`), nên bạn nhìn herdr là biết workspace nào của nhiệm vụ nào.

Lệnh: `agy-id` (symlink trong PATH, nguồn `scripts/agy-id.sh`).

## Việc Claude Code phải làm

1. **Ngay khi hiểu nhiệm vụ** (trước khi chạy subagent, trước khi báo cáo đầu tiên), đặt tên ngắn tiếng Việt
   (3 đến 7 từ, nêu đối tượng + việc đang làm) và nhận số:

   ```bash
   agy-id claim "Đánh giá engine gợi ý"      # in: #132 Đánh giá engine gợi ý
   ```

2. **Nêu nhãn ở dòng đầu của câu trả lời đầu tiên** và ở tiêu đề báo cáo cuối: `#132 Đánh giá engine gợi ý`.
   Người dùng dựa vào đó để khớp phiên với workspace herdr.
3. **Nhiệm vụ đổi hướng thì đổi tên, giữ số:** `agy-id rename "Tên mới"` (nếu đã có workspace herdr,
   dùng `agy-hd rename-space "Tên mới"` để đổi luôn nhãn workspace).
4. Đã có số rồi thì **không claim lại với tên khác** trừ khi nhiệm vụ thật sự đổi. `agy-id show` để xem nhãn hiện tại.

## Nối với herdr

`agy-hd` tự lấy nhãn từ `agy-id` khi tạo workspace cho phiên: workspace = `#132 Đánh giá engine gợi ý`,
mỗi subagent là một tab trong đó (xem skill `agy-subagent`). Chưa claim mà đã chạy `agy-hd` thì workspace tạm lấy
tên dự án (`#132 ai-hub`) và Claude Code đổi lại bằng `agy-hd rename-space "..."`.

## Các lệnh

| Cần | Lệnh |
|---|---|
| Nhận số / đặt tên lần đầu | `agy-id claim "tên"` |
| Xem nhãn của phiên này | `agy-id show` (chưa có thì exit 1, không cấp số) |
| Đổi tên (giữ số) | `agy-id rename "tên mới"` |
| Chỉ số | `agy-id num` |
| Mọi số đã cấp | `agy-id list` |
| Trả số khi xong hẳn | `agy-id release` |

## Chi tiết

- Phiên được nhận diện bằng `$CLAUDE_CODE_SESSION_ID`; chạy tay ngoài Claude Code dùng khóa chung `manual`.
- Số quay vòng 999 → 100, bỏ qua số của phiên đã hoạt động trong 14 ngày (`AGY_ID_ACTIVE_DAYS`).
- Dữ liệu ở `~/.cache/agy-ids/` (`AGY_ID_DIR`). Tên dài tối đa 60 ký tự.

## Tự động cho MỌI phiên (người dùng tự thêm, Claude Code không tự sửa settings)

Thêm vào `~/.claude/CLAUDE.md` một dòng:

```
Đầu mỗi nhiệm vụ: chạy `agy-id claim "<tên ngắn>"` và ghi nhãn "#số tên" ở dòng đầu câu trả lời (skill claude-task-id).
```

hoặc hook `SessionStart` trong `~/.claude/settings.json` in nhắc nhở để mọi phiên làm đúng việc đó.
