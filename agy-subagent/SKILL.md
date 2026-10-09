---
name: agy-subagent
description: Delegate a well-scoped task to agy (Antigravity CLI, Gemini 3.8 Flash High, always bypass-permissions) as a subagent that runs in its own herdr workspace (optionally its own git worktree), which Claude Code plans, dispatches, monitors, interrupts and verifies, and for which the user gets attach/log paths. Use when the user says "dùng agy", "giao cho agy", "agy subagent", "chạy agy trong herdr", "check agy chạy tới đâu", "dừng agy", or wants a cheap second agent while Claude Code keeps managing.
---

# agy as a subagent (herdr-first)

**Claude Code = plan + manage + verify. agy = worker.** agy luôn chạy
`gemini-3.8-flash-high --effort high --dangerously-skip-permissions`, không có cờ đổi.
**Mỗi phiên Claude Code = một workspace, mỗi subagent = một tab** (trong session herdr `cas`) (+ `-W` worktree riêng) nên các task không đụng nhau,
và người dùng mở herdr là thấy agy đang làm gì. Lệnh: `agy-hd` (symlink trong PATH,
nguồn `scripts/agy-hd.sh`). Không gọi `agy` trần.

Phiên Claude Code **không cần** chạy trong herdr; chỉ cần herdr server đang chạy
(`herdr status server`). Chọn session bằng `HERDR_SESSION` (mặc định `default`).
Herdr không chạy / môi trường Windows / cần structured output (`-s` schema) → dùng bản headless
`agy-sub`/`agy-ctl`/`agy-fan` (PowerShell `.ps1` + wrapper `.cmd` trên Windows, xem [REFERENCE.md](REFERENCE.md)).

## Mô hình herdr: MỘT session `cas`, workspace = phiên Claude Code, tab = subagent

```
session  cas  (Claude Agy Subagent, dùng chung, tự tạo nếu chưa có; KHÔNG BAO GIỜ dùng session "default" của người dùng)
 ├─ workspace  "#132 Đánh giá engine gợi ý"   ← 1 phiên Claude Code (số + tên từ skill claude-task-id)
 │     tabs:  [a-probe-3c85] [a-code-2e14] [a-docs-7939]     ← mỗi subagent = 1 TAB (nhãn tab = id job), không chia màn hình
 └─ workspace  "#133 Sửa spell"               ← phiên Claude Code khác
       tabs:  [a-fix-1c2d]
```

**Trước khi chạy subagent đầu tiên của phiên, nhận số + tên:** `agy-id claim "Đánh giá engine gợi ý"`
(skill [claude-task-id](../claude-task-id/SKILL.md)); workspace sẽ mang đúng nhãn `#132 Đánh giá engine gợi ý`.
Đổi tên nhiệm vụ: `agy-hd rename-space "Tên mới"`. Không cần truyền `-S`: mặc định là `cas`
(`AGY_HD_SESSION` hoặc `-S` chỉ để ghi đè, vd khi test). Nhiều subagent chạy song song của cùng phiên được đặt vào
**cùng một workspace** (có khóa chống tạo trùng).

Người dùng vào xem:

```bash
herdr --session cas              # TUI: thấy mọi workspace "#số tên" (mỗi cái là một phiên Claude); mở workspace thì mỗi tab là một subagent
agy-hd ps                        # bảng workspace -> tab -> agent/trạng thái/job (★ = của agy-hd)
agy-hd ps -w                     # tự làm mới 2 s
agy-hd open <job>                # attach thẳng vào tab của subagent
agy-hd init                      # tạo sẵn session cas nếu chưa có
```

`agy-hd close <job>` chỉ đóng **tab** của job (đóng tab cuối thì herdr đóng luôn workspace; lần chạy sau tự tạo lại cùng nhãn). `agy-hd session-stop <tên>` chỉ dừng
session do agy-hd tạo, từ chối `default`. Các lệnh sau (`status`, `logs`, `prompt`...) tự biết session của job.

**Phiên Claude Code chạy trong một pane herdr** có sẵn `HERDR_SOCKET_PATH` của session chứa pane đó (thường là
`default`), và herdr ưu tiên biến này hơn `HERDR_SESSION`. `agy-hd` tự bỏ biến đó khi nhắm một session khác
`default`; trước bản sửa 2026-10-05, mọi agent từ phiên như vậy rơi vào `default`. Lệnh xem tay cũng phải dùng
dạng cờ: `herdr --session cas ...`. Dạng `HERDR_SESSION=cas herdr ...` bị bỏ qua trong một pane herdr.

## Quy tắc cứng: LUÔN đưa đường dẫn truy cập cho người dùng

`agy-hd start` in khối `ACCESS:` **trước khi chờ** (workspace, lệnh attach, lệnh xem log, đường
dẫn transcript, worktree). Với việc >30 s chạy `start` bằng Bash `run_in_background: true`,
**đọc ngay output file** lấy khối ACCESS và dán cho người dùng trong cùng lượt, rồi mới chờ.
Với `fan`, đọc `<results>/ACCESS.txt` (có sớm, từng task một).

## Chạy

```bash
agy-hd start -n tên -d /repo -f task.md            # tab mới trong workspace của phiên, sửa thẳng /repo
agy-hd start -n tên -d /repo -W -f task.md         # + worktree riêng branch agy/<id> (nên dùng khi SỬA code)
agy-hd start -n tên -d /repo -W -C -f task.md      # + mang thay đổi CHƯA commit của repo vào worktree
agy-hd start -n tên -d /repo -R -p "review X"      # chỉ đọc
agy-hd start -A ...                                # async: không chờ xong, in ACCESS rồi thoát
agy-hd watch <job> [<job>...]                      # phụ: chạy nền, báo ngay khi xong/treo/hết hạn mức
agy-hd tick --show                                 # bảng trạng thái mọi job (systemd timer chạy mỗi phút)
agy-hd restart <job>                               # hết hạn mức: tắt agy rồi mở lại cùng hội thoại + "làm tiếp"
```

`-t giây` timeout chờ (900). Cuối lệnh in `STATUS=DONE|BLOCKED|TIMEOUT|ERROR`, diffstat (nếu `-W`),
rồi `---` và câu trả lời cuối của agy. `<job>` = id (`a-<tên>-xxxx`, cũng là tên agent herdr).

## Scheduler: kiểm mỗi phút (bắt buộc)

Người dùng yêu cầu ngày 2026-10-05:
- "cứ 1 phút là phải check lại subagent một lần đối với agy, vì nó có thể treo giữa chừng";
- sau đó, khi cả 4 agent dừng vì hết hạn mức mà phiên Claude không biết: "tôi thấy subagent đã bị dừng nhưng bạn không biết… hãy viết scheduler… biết được subagent đang chạy, đã từng, đã hết limit, đã done… mỗi phút một lần".

Hôm đó một `agy-hd watch` chạy nền trong phiên đã bị Claude Code dừng vì máy thiếu RAM. Nên **không được chỉ dựa vào watch**. Giám sát có hai lớp:

**1. systemd timer, chạy mọi lúc, độc lập với phiên Claude.**
- `agy-hd-tick.timer` (user unit, `~/.config/systemd/user/`) chạy `agy-hd tick` mỗi phút.
- Mỗi lượt, tick xét mọi job còn tab (bỏ qua job đã đóng và job bắt đầu quá 24 giờ trước):
  - ghi bảng hiện tại vào `~/.cache/agy-hd/STATUS.tsv`;
  - nối mỗi lần đổi trạng thái vào `~/.cache/agy-hd/events.log`;
  - **tự restart job hết hạn mức** (xem mục dưới).
- Kiểm timer còn chạy: `systemctl --user is-active agy-hd-tick.timer`. Tắt: `systemctl --user disable --now agy-hd-tick.timer`.

**2. Phiên Claude tự đánh thức mỗi phút, trong lúc còn job agy đang chạy.**
- Ngay sau `start -A` hoặc `fan`, tạo một lịch bằng `CronCreate`, `cron: "* * * * *"`, với prompt kiểu:
  `agy check-in (#<số> <tên>): chạy agy-hd tick --show, xem các job của nhiệm vụ này và xử lý theo bảng trạng thái của skill agy-subagent. Không có gì đổi thì trả lời một dòng. Khi mọi job DONE thì kiểm chứng kết quả rồi CronDelete lịch này.`
- Lịch chỉ chạy khi phiên rảnh, và tự hết hạn sau 7 ngày.
- **Xoá lịch (`CronDelete`) khi mọi job của nhiệm vụ đã DONE**, để không đánh thức phiên vô ích.

**Bảng trạng thái** (`agy-hd tick --show`):

| Trạng thái | Nghĩa | Việc phải làm |
|---|---|---|
| `RUNNING` | agy đang làm: working, hoặc còn lệnh đang chạy | không làm gì; nếu muốn thì xem tiến độ (số bước, file đầu ra) |
| `DONE` | xong: không còn lệnh chạy, transcript kết thúc bằng câu trả lời cuối (kể cả đã park) | kiểm chứng (đọc diff, chạy lại test), rồi **đóng tab ngay**: `agy-hd close <job>` (hoặc `wt-merge`/`wt-drop`) |
| `QUOTA` | hết hạn mức Antigravity | tick tự `restart`; theo dõi xem lần tick sau có về `RUNNING` không |
| `STOPPED` | dừng giữa chừng: agy thoát hoặc đứng im mà không có câu trả lời cuối | `agy-hd logs <job> 40`, rồi `agy-hd resume <job>` / `restart <job>` |
| `STALL` | treo: lệnh chạy quá `AGY_CMD_STALL_SEC` (900 s), hoặc working mà transcript đứng yên quá `AGY_STALL_SEC` (180 s) | xem log; treo thật thì `interrupt` rồi `prompt` tiếp |
| `BLOCKED` | agy đang hỏi hoặc chờ duyệt | báo người dùng kèm lệnh attach, đừng trả lời thay |

`agy-hd watch <job>...` vẫn dùng được, chạy nền: nó kiểm mỗi `-i` giây và thoát ngay khi DONE (0), STALL (2), BLOCKED (3), GONE (4) hoặc QUOTA (6). Nhưng watch chỉ là lớp phụ, vì nó có thể bị dừng khi máy thiếu RAM.

## Xong việc thì đóng tab (bắt buộc)

Người dùng dặn ngày 2026-10-05: "khi done task subagent thì đóng tab lại".
- Kiểm chứng xong một job DONE thì đóng tab của nó ngay:
  - `agy-hd close <job>`;
  - với job `-W`: `wt-merge <job>` hoặc `wt-drop <job>`, vì hai lệnh này tự đóng tab.
  - Đóng tab cuối thì herdr đóng luôn workspace của phiên. Lần start sau sẽ tạo lại cùng nhãn.
- Đóng tab không mất gì:
  - transcript vẫn còn (`agy-hd result <job>`, `agy-hd logs <job> --transcript`);
  - worktree vẫn còn (`wt-diff`). `close` commit những thay đổi còn dở trong worktree trước khi đóng.
- **Lưới an toàn:** `tick` (systemd timer, mỗi phút) tự đóng tab của job đã DONE quá `AGY_AUTOCLOSE_MIN` phút (mặc định 15; đặt 0 để tắt), và ghi vào `events.log`. Đừng dựa vào nó: đóng tab ngay sau khi kiểm chứng.

## Cài đặt, hệ điều hành, tự sửa (skill `agy-setup`)

- Các script nạp `scripts/compat.sh`: chạy được trên Linux, macOS, WSL (bash < 4.4 thì tự chạy lại bằng bash Homebrew;
  thiếu flock/timeout/setsid/... thì giả lập). Thiếu công cụ (jq, herdr, agy...) thì tự chạy `setup.sh fix -y` một lần.
- Lệnh agy-* lỗi môi trường: làm theo skill agy-setup (`agy-setup check` → `agy-setup fix -y` → chạy lại).

## Nhiều account (skill `agy-accounts`)

- Mỗi job chạy bằng một **profile agy-p** (một Google account, token riêng). `agy-hd start/fan -u <profile>` để chỉ định;
  không có `-u` thì `agy-p pick` tự chọn: ưu tiên profile mặc định (`agy-p default`) khi nó còn ≥ 20% quota Gemini và
  đang chạy < 2 job, không thì account còn nhiều quota nhất chia cho số job đang mở trên nó (fan được chia đều).
- Dòng `ACCOUNT=<profile> (<email>)` khi start, dòng `account :` trong ACCESS, cột `account` trong `STATUS.tsv` / `agy-hd list`.
- Hội thoại dùng chung mọi profile, nên **resume / restart sang account khác giữ nguyên conversation**.
  Subagent dùng sẵn của agy (`invoke_subagent`) và lệnh `agy` lồng trong job đều chạy cùng account đó.
- Xem quota: `agy-p usage`. Thêm account: `agy-p add` (xem skill agy-accounts). Chuyển một job: `agy-hd switch <job> [profile]`;
  bảng account + job: `agy-hd accounts`.
- **Khoá theo job**: `park`/`resume`/`restart`/`switch`/`interrupt`/`close` và tick không đổi trạng thái cùng một job một lúc
  (lệnh tay chờ tối đa 120 s; tick thấy job bận thì để vòng sau). `prompt` đợi restart/switch đang chạy xong rồi mới gửi,
  và không giữ khoá trong lúc chờ agy trả lời.

## Hết hạn mức Antigravity (quota)

- **Dấu hiệu:** màn hình agent hiện `⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 3h16m…`. Log `~/.gemini/antigravity-cli/log/cli-*.log` ghi `RESOURCE_EXHAUSTED (code 429)`. agy đứng im ở idle/done trong khi việc chưa xong. Gặp lần đầu 2026-10-05, trên cả 4 agent chấm điểm cùng lúc.
- **Cách xử lý:** người dùng dặn "lâu lâu nó sẽ hết hạn mức gói antigravity thì cứ tắt session đó đi và mở lại là được". Cụ thể là `agy-hd restart <job> ["prompt"]`:
  1. thoát agy trong tab (ctrl+c, lần 2 nếu cần);
  2. mở lại đúng hội thoại cũ (`resume`);
  3. gửi prompt "làm tiếp việc dở, xem lại file đã ghi, không làm lại từ đầu".
  Ngày 2026-10-05 cách này cứu được cả 4 agent: chúng chấm tiếp đúng chỗ dở (125 → 249 nhãn) rồi xong.
- **tick tự làm việc này** cho job ở trạng thái QUOTA: tối đa 5 lần mỗi job, cách nhau ít nhất 3 phút (1 phút nếu job chạy qua agy-p), mỗi lần ghi vào `events.log`.
  Job chạy qua agy-p thì restart **chuyển sang account khác còn quota** (loại account vừa hết, `QUOTA_EMAILS` trong meta ghi account đó; account khác chỉ bị
  loại khi quota lấy mới dưới 5%, nên account đã hồi quota được chọn lại), rồi
  resume đúng conversation; không còn account nào thì mở lại trên account cũ. Đã e2e 2026-10-08: account hết quota 5 giờ (0%) → account khác, cùng conversation, xong việc. Sau 5 lần vẫn hết hạn mức thì tick ghi `QUOTA_GAVE_UP`. Lúc đó **báo người dùng**, kèm thời gian "Resets in" trên màn hình, đừng restart vòng vòng.
- Việc có file đầu ra ghi dần (ví dụ labels.jsonl) nên được thiết kế để làm tiếp được: ghi theo lô, có script kiểm tra. Sau khi job DONE, kiểm lại số dòng hoặc chạy script kiểm tra.

## Viết prompt

agy không thấy hội thoại. Prompt tự đủ: mục tiêu, **file được sửa**, bối cảnh dán thẳng, tiêu chí
xong (lệnh test), format báo cáo (template: REFERENCE.md). Mô tả **chính xác** kết quả mong muốn
(ví dụ nội dung file có xuống dòng cuối không): prompt mơ hồ làm agy mất hàng phút suy diễn.
Script tự nối ràng buộc cứng (không push/commit/reset, không mạng 10.x, không process nền).

## Tương tác, theo dõi, interrupt

| Cần | Lệnh |
|---|---|
| Gửi prompt tiếp (cùng agent, nhớ ngữ cảnh) | `agy-hd prompt <job> "..."` (`-f file`, `-A` không chờ) |
| Trạng thái + màn hình cuối | `agy-hd status <job>` (idle/working/blocked/done/gone, STALL) |
| **Giám sát mỗi phút, báo khi xong/treo** | `agy-hd watch <job>...` (chạy nền; xem mục Giám sát) |
| Chờ xong lượt hiện tại | `agy-hd wait <job> 600` |
| Log live / lịch sử đầy đủ | `agy-hd logs <job> 80` / `agy-hd logs <job> 50 --transcript` |
| Câu trả lời cuối / + diffstat | `agy-hd result <job>` / `agy-hd summary <job>` |
| In lại link truy cập | `agy-hd access <job>` |
| **Interrupt** | `agy-hd interrupt <job>` (huỷ lượt đang chạy; nếu agy vẫn chạy thì Ctrl+C lần 2 thoát hẳn; lệnh con bị dọn; workspace giữ) |
| Mở lại, tiếp hội thoại cũ | `agy-hd resume <job>` |
| Nhả RAM (thoát agy đang idle, giữ tab + log) | `agy-hd park <job>` (`start -P` tự park khi xong; `fan` mặc định park, `-K` để giữ sống) |
| Đóng tab của job | `agy-hd close <job>` |
| **Xem tất cả cho dễ** | `agy-hd ps` (bảng mọi workspace herdr + agent + job, ★ = của agy-hd), `agy-hd ps -w` tự làm mới 2 s |
| Vào xem trực tiếp | `agy-hd open <job>` (attach vào agent) hoặc `agy-hd open wX` (nhảy tới workspace) |
| Chỉ các job agy-hd | `agy-hd list` |

- `BLOCKED` nghĩa là agy đang hỏi/chờ duyệt: đừng trả lời thay, báo người dùng kèm lệnh attach.
- **agy có thể chạy lệnh nền rồi kết thúc lượt** ("launched ... as a background task and am waiting"), sau đó tự
  chạy tiếp khi lệnh xong. Lúc đó herdr báo idle. `agy-hd` coi job còn **bận** khi tiến trình agy còn một tiến
  trình con không phải MCP server: chưa báo DONE, và `park` từ chối. Câu trả lời cuối kiểu "đang chờ kết quả"
  nghĩa là chưa xong: kiểm `agy-hd status <job>` trước khi đọc diff.
- Kết quả interrupt có 2 dạng: agy còn sống ở `idle` (giữ ngữ cảnh, dùng `prompt` tiếp) hoặc agy đã thoát (dùng `resume`).
  Tác vụ nền của agy cần Ctrl+C lần 2 mới dừng (đã đo); `esc` không dừng được.
- Hộp thoại "Do you trust this folder?" của agy ở thư mục mới được script tự xác nhận, **chỉ cho
  workdir bạn truyền vào `-d` (hoặc worktree của nó)**, và in dòng `TRUST:` để bạn biết.
- Agent giữ nguyên workspace sau khi xong để xem log. Dọn bằng `close`, `wt-merge/wt-drop`, hoặc `agy-hd gc`.

## Worktree (`-W`)

Worktree ở `<repo>/../.agy-wt/<repo>-<id>`, branch `agy/<id>`; wrapper (không phải agy) commit kết quả.

```bash
agy-hd wt-diff <job>      # xem diff trước khi nhận
agy-hd wt-merge <job>     # merge vào branch hiện tại (job -C: áp diff vào cây làm việc, không commit) + đóng workspace + dọn
agy-hd wt-drop <job>      # bỏ, không merge
```

Worktree tách từ **HEAD**: thay đổi chưa commit KHÔNG vào worktree trừ khi dùng `-C`. Conflict khi
merge: script dừng và báo, Claude Code giải tay. Dọn job cũ: `agy-hd gc [ngày=3] [-y]`.

Song song nhiều task: [agy-parallel](../agy-parallel/SKILL.md).

## Quy trình bắt buộc

1. Plan, chia việc. Việc mơ hồ/rủi ro cao thì tự làm.
2. `start -A`, rồi:
   - **đưa ACCESS cho người dùng ngay**;
   - **tạo lịch `CronCreate` mỗi phút** để phiên tự đánh thức và đọc `agy-hd tick --show` (mục Scheduler);
   - kiểm `systemctl --user is-active agy-hd-tick.timer`.
   Làm việc khác trong lúc chờ. Mỗi lần được đánh thức thì xử lý theo bảng trạng thái, không đoán. Mỗi job DONE
   thì kiểm chứng rồi **đóng tab** (`agy-hd close <job>`). Mọi job DONE thì `CronDelete`.
3. **Không tin báo cáo của agy.** Đọc `wt-diff`/`git diff`, chạy lại test, đối chiếu file bị sửa với phạm vi
   đã giao; ngoài phạm vi thì không merge. agy bypass quyền nên có thể đọc/sửa ngoài phạm vi.
4. Sai: `agy-hd prompt <job> "Sửa: …"` (cùng ngữ cảnh), tối đa 2 vòng, rồi tự sửa.
5. Báo người dùng: agy làm gì, đã kiểm chứng gì, đã merge gì, workspace nào còn mở.

## Cấm

Không secret/`.env` trong prompt (đi ra Google). Không giao migration DB, deploy, push, VPN/dev.

**Giới hạn thật của các "ràng buộc":** agy luôn chạy `--dangerously-skip-permissions`, nên câu "không git push / không chạm 10.0.0.0/8 / không nohup" chỉ là chỉ dẫn trong prompt, KHÔNG có gì chặn cứng. Chỉ `-R` có kiểm tra thật: ngầm bật `--sandbox` và so sánh `git status` + `git diff HEAD` trước/sau; khác nhau thì báo `RO_VIOLATION` (exit 1) và phải hoàn tác. Chặn mạng bằng systemd `IPAddressDeny` không hoạt động trong user manager trên máy này (đã thử 10-05). Vì vậy: không giao việc cần chạm mạng nội bộ cho agy, và đọc diff trước khi tin kết quả.
Không đóng workspace/session herdr không do `agy-hd` tạo (`session-stop` đã từ chối sẵn). Không `herdr server stop`.
