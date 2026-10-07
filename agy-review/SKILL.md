---
name: agy-review
description: Get an independent read-only second opinion from agy (Gemini 3.8 Flash High) on a diff, file or design, returned as structured findings that Claude Code then verifies. Use when the user asks "cho agy review", "second opinion", "agy check giúp", or before finishing work that deserves a cross-model check.
---

# agy review (chỉ đọc, kết quả có cấu trúc)

agy là reviewer thứ hai, **không phải người quyết định**. Claude Code kiểm chứng từng
finding trước khi nói với người dùng. Cách chạy chung: [agy-subagent](../agy-subagent/SKILL.md).

## Cách chạy

Review dùng bản **headless** `agy-sub` (cần `-s` schema để nhận JSON đã validate; `agy-hd` chỉ trả text).
Muốn người dùng xem agy đọc code trực tiếp thì chạy `agy-hd start -R` thay thế và tự phân tích text.

```bash
git diff develop...HEAD -- <paths> > $SCRATCH/diff.patch
agy-sub -R -d /path/to/repo -s "$(cat ~/.claude/skills/agy-review/schema.json)" \
  -p "Review diff tại $SCRATCH/diff.patch (dùng -a nếu ngoài repo). Tìm bug đúng/sai logic, \
race, lỗi xử lý lỗi, thiếu test. Bỏ qua style. Mỗi finding phải có file:line và kịch bản gây lỗi cụ thể."
```

Diff nằm ngoài `-d` thì thêm `-a $SCRATCH`. Output sau `---` là JSON theo
[schema.json](schema.json): `findings[]` (file, line, severity, summary, scenario) và `verdict`.

## Xử lý kết quả (Claude Code làm)

1. Với mỗi finding: mở đúng file:line, xác nhận có thật. Gemini hay bịa dòng/hàm.
2. Phân loại: **thật** (sửa), **sai** (bỏ), **không chắc** (nêu cho người dùng).
3. Báo cáo: số finding agy đưa ra / số đã xác nhận, kèm danh sách xác nhận.
4. Tối đa 1 vòng review lại bằng `-r <conversation_id>` sau khi sửa.

## Lưu ý

- `-R` chỉ là lời dặn. Chạy `git status` sau, phải sạch như trước.
- Không đưa diff chứa secret/.env.
