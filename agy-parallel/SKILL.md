---
name: agy-parallel
description: Fan out several independent tasks to multiple agy subagents at once, each in its own herdr workspace and git worktree (max 4 concurrent), give the user access paths, then collect, verify and merge results. Use when a plan has 2+ independent pieces (per-file edits, per-module reviews, research questions) and the user wants them run in parallel ("chạy song song", "agy parallel", "chia việc cho agy", "mỗi task một workspace").
---

# Chạy agy song song trong herdr

Claude Code lên plan, chia việc, phát cho agy chạy cùng lúc (mỗi task một tab trong workspace `#số tên` của phiên, session herdr `cas`),
rồi gom, kiểm chứng, merge. Dùng chung `agy-subagent` (đọc nó trước: cách viết prompt, quy tắc ACCESS).

## Quy trình

1. **Chia việc độc lập.** Mỗi task có tập file **không giao nhau**. Hai task cùng sửa một file thì
   gộp thành một task hoặc chạy tuần tự. Task phụ thuộc kết quả task khác thì để đợt sau.
2. **Ghi mỗi task một file** `tasks/<id>.md` (template ở
   [../agy-subagent/REFERENCE.md](../agy-subagent/REFERENCE.md)), id ngắn, có nghĩa. Mô tả kết quả
   mong muốn thật chính xác (prompt mơ hồ làm agy suy diễn rất lâu).
3. **Chạy nền một lệnh duy nhất** (Bash `run_in_background: true`). Cả đợt nằm trong workspace `#số tên` của phiên (session `cas`),
   mỗi task một tab; người dùng vào xem bằng `herdr --session cas`. Nhớ `agy-id claim "<tên>"` trước (skill claude-task-id):

```bash
agy-hd fan -i $SCRATCH/tasks -o $SCRATCH/results -j 3 -d /path/to/repo -W   # sửa code: mỗi task 1 tab + 1 worktree
agy-hd fan -i $SCRATCH/tasks -o $SCRATCH/results -j 3 -d /path/to/repo -W -C     # + mang thay đổi chưa commit
agy-hd fan -i $SCRATCH/tasks -o $SCRATCH/results -j 3 -d /path/to/repo -R        # chỉ đọc
```

4. **Đưa đường dẫn cho người dùng NGAY**: sau vài giây đọc `$SCRATCH/results/ACCESS.txt` (mỗi task
   một khối: workspace, `herdr agent attach <id>`, lệnh xem log, transcript, worktree) và dán vào
   câu trả lời. Chưa có khối của task nào thì chờ rồi đọc lại, đừng đoán.
5. **Giám sát mỗi phút (bắt buộc):**
   - Ngay sau khi `fan` chạy, tạo lịch `CronCreate` `* * * * *` để phiên tự đánh thức mỗi phút và đọc `agy-hd tick --show`.
   - systemd timer `agy-hd-tick.timer` cũng chạy tick mỗi phút, độc lập với phiên. Nó tự restart job hết hạn mức.
   - Xử lý theo bảng trạng thái trong mục "Scheduler" của agy-subagent: RUNNING / DONE / QUOTA / STOPPED / STALL / BLOCKED.
   - Đừng chỉ chờ `fan` kết thúc: `fan` không nói gì khi một agent treo hoặc hết hạn mức giữa chừng.
   - Mỗi job DONE: kiểm chứng, rồi đóng tab (`wt-merge`/`wt-drop`, đều tự đóng tab, hoặc `agy-hd close <job>`).
   - Mọi job DONE thì `CronDelete` lịch.
   - Xem tay: `agy-hd ps`, `agy-hd status <job>`, `agy-hd logs <job>`, `tail ~/.cache/agy-hd/events.log`.
   - Job id = `a-<task>-xxxx`. Cột 3 của `results/SUMMARY.tsv` (task, trạng thái, job, workspace, branch) chỉ có khi job đã xong.
6. **Kiểm chứng và gộp (với `-W`):** mỗi task `agy-hd wt-diff <job>`, đối chiếu với phạm vi đã giao,
   rồi `wt-merge <job>` lần lượt từng task đạt (tự đóng workspace + dọn worktree); `wt-drop` task
   đi quá phạm vi. Chạy test toàn bộ **một lần** sau khi merge hết.
7. **Task sai/BLOCKED/TIMEOUT:** `agy-hd prompt <job> "Sửa: …"` (cùng ngữ cảnh), hoặc `interrupt` rồi `resume`.

## Cờ `agy-hd fan`

`-i` thư mục task, `-o` thư mục kết quả, `-j` số luồng (mặc định 3, trần 4), `-d` workdir, `-t` timeout
mỗi task (900 s), `-R` chỉ đọc, `-W` worktree riêng mỗi task, `-C` (với `-W`) mang thay đổi chưa commit.

## Chọn loại task

- **Chỉ đọc (`-R`)**: review từng module, tóm tắt, tìm usage. An toàn nhất.
- **Sửa code**: luôn `-W`. Worktree cô lập khi chạy, nhưng chia file tách bạch vẫn cần để merge sạch.
  Worktree tách từ HEAD: dùng `-C` nếu task cần thấy thay đổi chưa commit.

## Giới hạn

- Tối đa 4 agy cùng lúc (quota API); đợt >4 task tự xếp hàng.
- Mỗi task tốn tối thiểu ~17k token nền. Task vài dòng thì Claude Code tự làm.
- `fan` mặc định park từng agent khi xong (nhả ~280 MB RAM, tab + log còn); `-K` giữ sống. Dọn bằng `wt-merge`/`wt-drop`/`close`/`gc`.
- Bản headless không cần herdr: `agy-fan` (cờ tương tự) + `agy-ctl`.
- Cùng quy tắc cấm của agy-subagent: không secret, không migration/deploy/push/VPN.
