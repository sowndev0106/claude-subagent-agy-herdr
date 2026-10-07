# claude-subagent-agy-herdr

Bộ công cụ và skill tích hợp để **Claude Code** điều phối **Antigravity CLI (`agy`)** làm worker subagent, hiển thị và quản lý trực quan qua terminal multiplexer **`herdr`**.

---

## 💡 Triết lý hoạt động

> **Claude Code = Planner + Manager + Verifier**  
> **Antigravity (`agy`, Gemini 3.8 Flash High) = Cheap, fast Worker**

* Claude Code lập kế hoạch, chia việc, theo dõi tiến độ, kiểm chứng kết quả và merge code.
* `agy` chạy độc lập với tốc độ cao, luôn bypass permissions để hoàn thành nhanh các tác vụ được chỉ định rõ phạm vi.
* **Mỗi phiên Claude Code = Một workspace herdr** (ví dụ: `#132 Đánh giá engine gợi ý`).
* **Mỗi subagent = Một tab riêng biệt** trong workspace đó (nhãn tab = ID job `a-<task>-xxxx`).
* **Cách ly mã nguồn**: Tùy chọn `-W` tự động tạo Git worktree riêng biệt (nhánh `agy/<id>`), tránh xung đột với nhánh làm việc chính.

---

## 📦 Các thành phần trong bộ skill

| Skill / Công cụ | Mô tả | Lệnh chính |
|---|---|---|
| **`agy-subagent`** | Giao việc độc lập cho một subagent agy; quản lý qua herdr TUI hoặc headless. | `agy-hd start`, `agy-sub`, `agy-ctl` |
| **`agy-parallel`** | Chia nhỏ việc thành 2–4 task độc lập, chạy fan-out song song trên nhiều tab/worktree. | `agy-hd fan`, `agy-fan` |
| **`agy-review`** | Nhận ý kiến đánh giá độc lập (second opinion) từ agy đối với diff/code, trả về JSON có cấu trúc (`schema.json`). | `agy-sub -R -s schema.json` |
| **`claude-task-id`** | Cấp phát số và tên định danh 3 chữ số (`#132 ...`) dùng chung giữa Claude Code và nhãn workspace Herdr. | `agy-id claim`, `agy-id show` |

---

## ⏱️ Cơ chế Giám sát & Tự phục hồi Quota (Scheduler)

Khi giao việc cho subagent, phiên Claude Code có thể không nắm được nếu agy bị treo hoặc chạm giới hạn hạn mức (Quota Limit 429). Hệ thống giải quyết bằng cơ chế 2 lớp:

1. **Systemd User Timer (`agy-hd-tick.timer`)**:
   * Chạy `agy-hd tick` mỗi phút một lần độc lập với phiên Claude Code.
   * Ghi log trạng thái vào `~/.cache/agy-hd/STATUS.tsv` và `events.log`.
   * **Tự động khôi phục khi hết hạn mức (Quota 429)**: Khi agy gặp lỗi `RESOURCE_EXHAUSTED`, hệ thống tự động thoát tiến trình và mở lại (`agy-hd restart`), tiếp tục phiên hội thoại cũ từ checkpoint dở dang mà không làm lại từ đầu.
2. **Cron Check-in trong Claude Code**:
   * Khi khởi chạy subagent async (`start -A` hoặc `fan`), Claude Code đặt lịch đánh thức mỗi phút để đọc `agy-hd tick --show` và xử lý theo trạng thái:
     * `RUNNING`: Đang chạy bình thường.
     * `DONE`: Hoàn thành $\rightarrow$ kiểm chứng diff, test và đóng tab (`agy-hd close` hoặc `wt-merge`).
     * `QUOTA`: Đang được scheduler tự restart.
     * `STOPPED` / `STALL`: Treo $\rightarrow$ inspect log, interrupt hoặc resume.
     * `BLOCKED`: Cần người dùng tương tác.

---

## 🚀 Cài đặt

### 1. Clone repository
```bash
git clone git@github.com:sowndev0106/claude-subagent-agy-herdr.git
cd claude-subagent-agy-herdr
```

### 2. Chạy script cài đặt
Script sẽ tự động tạo symlink skills vào `~/.claude/skills/`, symlink các lệnh vào `~/.local/bin/`, và kích hoạt systemd timer:

```bash
./install.sh
```

### 3. Cấp quyền trong Claude Code
Thêm các lệnh bash vào allowlist trong `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(agy-hd:*)",
      "Bash(agy-sub:*)",
      "Bash(agy-fan:*)",
      "Bash(agy-ctl:*)",
      "Bash(agy-id:*)"
    ]
  }
}
```

---

## 🛠️ Hướng dẫn sử dụng nhanh

### 1. Định danh phiên làm việc (Task ID)
```bash
agy-id claim "Refactor parser module"
# Trả về: #133 Refactor parser module
```

### 2. Chạy 1 subagent qua herdr (có worktree riêng)
```bash
# Bắt đầu task trong worktree riêng, chạy bất đồng bộ
agy-hd start -n parser -d /path/to/repo -W -f task.md -A

# Xem trực tiếp trên giao diện TUI Herdr
herdr --session cas

# Hoặc attach thẳng vào tab của agent
agy-hd open <job-id>

# Xem diff khi xong việc
agy-hd wt-diff <job-id>

# Gộp thay đổi vào nhánh hiện tại và đóng tab
agy-hd wt-merge <job-id>
```

### 3. Chạy song song nhiều task (`fan-out`)
```bash
# Chuẩn bị thư mục tasks/ chứa các file <task_id>.md độc lập
agy-hd fan -i ./tasks -o ./results -j 3 -d /path/to/repo -W
```

### 4. Review code độc lập với JSON Schema
```bash
git diff main...HEAD > /tmp/diff.patch
agy-sub -R -d /path/to/repo -s "$(cat ~/.claude/skills/agy-review/schema.json)" \
  -p "Review diff tại /tmp/diff.patch. Tìm lỗi logic, race condition, thiếu test."
```

---

## 📂 Cấu trúc Repository

```
claude-subagent-agy-herdr/
├── README.md
├── install.sh
├── .gitignore
├── agy-subagent/
│   ├── SKILL.md
│   ├── REFERENCE.md
│   ├── scripts/
│   │   ├── agy-hd.sh          # Quản lý subagent qua herdr (TUI)
│   │   ├── agy-sub.sh         # Runner headless
│   │   ├── agy-fan.sh         # Chạy fan-out song song headless
│   │   ├── agy-ctl.sh         # CLI điều khiển job headless
│   │   ├── selftest.sh        # Test suite tự động cho runner headless
│   │   └── selftest-hd.sh     # Test suite tự động cho herdr runner
│   └── systemd/
│       ├── agy-hd-tick.service
│       └── agy-hd-tick.timer  # Timer giám sát trạng thái & quota mỗi phút
├── agy-parallel/
│   └── SKILL.md               # Hướng dẫn fan-out đa subagent
├── agy-review/
│   ├── SKILL.md               # Quy trình review độc lập
│   └── schema.json            # JSON schema cấu trúc kết quả review
└── claude-task-id/
    ├── SKILL.md               # Cấp phát nhãn và ID phiên
    └── scripts/
        └── agy-id.sh          # Quản lý bảng map ID và session
```
