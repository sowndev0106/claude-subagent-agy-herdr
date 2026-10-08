# Tham khảo agy-subagent

Mục lục: Prompt template · herdr (agy-hd) · Bản headless (agy-sub/ctl/fan) · Sự thật đã đo · Allowlist

# Prompt template cho agy

```markdown
# Mục tiêu
<một câu>

# Phạm vi
Được sửa: <path1>, <path2>
Chỉ đọc: <path3>
Không đụng gì khác.

# Bối cảnh
<đoạn code/quy ước liên quan, dán thẳng vào>

# Việc cần làm
1. ...
2. ...

# Xong khi
`<lệnh test>` pass. Nếu không chạy được lệnh, nói rõ lý do, đừng bịa kết quả.

# Báo cáo (dòng cuối, đúng format)
FILES_CHANGED: <danh sách>
TEST_RESULT: <PASS|FAIL + tóm tắt>
ISSUES: <điều chưa chắc, hoặc "none">
```

## herdr (agy-hd): cách nó hoạt động

Mỗi `agy-hd start` làm: `workspace create --cwd <dir> --label <id> --no-focus` → `agent start <id> --kind agy --pane <pane> -- --model gemini-3.8-flash-high --effort high --dangerously-skip-permissions`
→ xác nhận "trust folder" nếu agy hỏi → `agent prompt <id> "[agy-hd:<id>] <prompt>"` → chờ ổn định → đọc transcript.
Dùng tay (trong session đang chạy): `herdr agent read <id> --source recent-unwrapped --lines 120`,
`herdr agent prompt <id> "..." --wait`, `herdr agent send-keys <id> ctrl+c`, `herdr agent attach <id>`,
`herdr workspace close <w>`. Cú pháp đầy đủ: `herdr --skill`; `herdr agent|pane|workspace|tab|worktree` (không kèm lệnh con).

- Marker `[agy-hd:<id>]` ở đầu prompt để tìm `transcript.jsonl` của agy bằng `grep -l`; transcript là log bền vững
  (TUI của agy chạy alternate screen nên `agent read` không giữ được lịch sử dài).
- `herdr worktree create` cũng tạo thêm một workspace cho nhánh chính của repo; script không dùng nó mà tự
  `git worktree add` rồi `workspace create` để mỗi task đúng một workspace.
- Test cô lập: `herdr --session <tên> server &` rồi `HERDR_SESSION=<tên> ...`; xong `herdr session stop|delete <tên>`.
  `selftest-hd.sh` làm đúng như vậy.

## Bản headless (khi herdr không chạy, hoặc cần `-s` structured output, hoặc chạy trên Windows)

`agy-sub` (1 task, `-W -C -R -s -r -a -t -n`), `agy-fan` (nhiều task), `agy-ctl` (list/status/tail/history/summary/stop/wait/gc/wt-*).
Job lưu ở `~/.cache/agy-jobs/<id>/` (trên Windows: `$HOME/.cache/agy-jobs/<id>/`). Không có workspace/attach: xem log bằng `agy-ctl tail|history`.

### Hỗ trợ Windows Native (PowerShell + CMD wrappers)

Bộ script headless có sẵn bản chạy trực tiếp trên Windows trong `scripts/`:
- `agy-sub.ps1` & `agy-sub.cmd`: Runner 1 subagent trên Windows, hỗ trợ đóng stdin chống treo, timeout watchdog kill cả cây tiến trình (`taskkill /PID <pid> /T /F`), git worktree cô lập (`-W`), mang thay đổi uncommitted (`-C`), chỉ đọc (`-R`), JSON schema (`-s`).
- `agy-ctl.ps1` & `agy-ctl.cmd`: Quản lý, kiểm tra trạng thái (`status`, `tail`, `history`, `summary`), interrupt (`stop`), diff/merge/drop worktree, dọn dẹp (`gc`).
- `agy-fan.ps1` & `agy-fan.cmd`: Chạy song song nhiều task (worker pool tối đa 4 subagents đồng thời), xuất bảng `SUMMARY.tsv`.
- `agy-id.ps1` & `agy-id.cmd`: Cấp số phiên và nhãn nhiệm vụ cho Claude Code trên Windows.
- **Không yêu cầu cài `jq` hay `bash`**: Sử dụng hoàn toàn bộ xử lý JSON (`ConvertFrom-Json`) và MD5 checksum của PowerShell / .NET 5.1+.
- **An toàn khi truyền prompt**: `agy-sub.ps1` chỉ chạy `agy.exe` (không chạy `agy.cmd`/`.bat`, vì cmd.exe đọc lại dòng lệnh và prompt chứa `& | > ^` thành lệnh). Các wrapper `.cmd` vẫn đi qua cmd.exe, nên prompt không do bạn viết thì truyền bằng file (`-f prompt.md`), hoặc gọi thẳng `agy-sub.ps1` từ PowerShell.
- **Cách dùng trên Windows**: Thêm đường dẫn thư mục `scripts/` vào biến môi trường `PATH` (User hoặc System PATH). Sau đó trong PowerShell hoặc CMD / Claude Code, chỉ cần gõ `agy-sub`, `agy-ctl`, `agy-fan` như bình thường.

## Cờ agy-sub.sh / agy-sub.ps1

| Cờ | Ý nghĩa |
|----|---------|
| `-p` / `-f` / stdin | prompt |
| `-d dir` | cwd của agy (mặc định `$PWD`) |
| `-a dir` | thêm thư mục vào workspace (lặp được) |
| `-r id` | resume hội thoại |
| `-s schema` | JSON schema (chuỗi hoặc file) → `structured_output` |
| `-R` | chỉ đọc (lệnh trong prompt, không phải sandbox thật) |
| `-n name` | tên job (id = name-HHMMSS-rand) |
| `-W` | worktree riêng, branch `agy/<id>`, wrapper tự commit |
| `-o file` | copy `result.json` ra file này |
| `-t sec` | timeout, mặc định 600 |

`-R` là lời dặn, không phải rào cản kỹ thuật (agy bypass quyền). Vẫn phải `git status` sau đó.

## Sự thật đã đo (agy 1.2.16, herdr 0.8.2)

- `agy --sandbox` đi cùng bypass **không chặn gì quan sát được** (ghi ngoài thư mục, gọi mạng đều qua): đừng coi `-S` là rào cản.
- agy interactive hỏi "Do you trust this folder?" ở thư mục mới; bypass không bỏ qua; herdr báo `idle` sai lúc đó.
- herdr `agent prompt --wait` trả về ở lần idle đầu tiên, có thể giữa các bước của agy (báo DONE khi agy vẫn working).
  `agy-hd` tự chờ idle ổn định + transcript có câu trả lời cuối.
- Interrupt: lệnh foreground → 1 Ctrl+C huỷ lượt, agy về idle (còn sống). Tác vụ nền → 1 Ctrl+C chỉ hiện "press ctrl+c again to exit", Ctrl+C lần 2 thoát agy và dọn lệnh con. `esc` không dừng được.
- GNU `timeout` chỉ kill agy, lệnh con (vd `sleep`) sống sót thành mồ côi: `agy-sub` dùng watchdog + kill cả cây.
- Agent tự đọc cả ngoài worktree (xem thư mục task, worktree khác): bypass nên không có rào cản thật.

- `gemini-3.8-flash-high` là id có sẵn mức effort; script vẫn thêm `--effort high`.
- Một lượt tối thiểu ~17k token (system prompt của agy), ~5 s.
- Resume bằng `--conversation` giữ ngữ cảnh. Lượt resume chậm hơn (~38 s trong lần thử).
- `--json-schema` trả `structured_output` đã parse.
- Phải đóng stdin (`</dev/null`), script đã làm; nếu gọi tay mà thiếu thì agy có thể treo.
- Review nhỏ có `-s` schema: ~60 s, ~67k token (agy tự đọc file nhiều bước). Đặt `-t` đủ lớn.
- Đợt song song 2 task trivial: 13 s tổng, chạy thật đồng thời.
- Mỗi job lưu ở `~/.cache/agy-jobs/<id>/` (meta.env, events.jsonl, result.json, pid). Transcript đầy đủ của agy: `~/.gemini/antigravity-cli/brain/<cid>/.system_generated/logs/transcript.jsonl`.
- `stop` đã thử: kill sạch cây tiến trình (agy + lệnh nó chạy), job thành STOPPED, resume được.
- agy tự chạy `git status`/`rm -rf __pycache__` trong worktree: chấp nhận được, nhưng đó là lý do cần `-W`.

## Allowlist quyền cho Claude Code (người dùng tự thêm vào `~/.claude/settings.json`, `permissions.allow`)

```json
"Bash(agy-hd:*)", "Bash(agy-sub:*)", "Bash(agy-fan:*)", "Bash(agy-ctl:*)",
"PowerShell(agy-sub:*)", "PowerShell(agy-ctl:*)", "PowerShell(agy-fan:*)"
```
