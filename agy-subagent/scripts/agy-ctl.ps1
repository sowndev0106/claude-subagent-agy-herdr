#Requires -Version 5.1
<#
.SYNOPSIS
    Điều khiển các job agy trên Windows: xem trạng thái, interrupt, đọc history/summary, quản lý worktree.

.DESCRIPTION
    Bản Windows PowerShell của agy-ctl.sh:
    Hỗ trợ list, status, tail, history, summary, stop, wait, gc, wt-list, wt-diff, wt-merge, wt-drop.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList = @()
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$jobsBase = if ($env:AGY_JOBS) { $env:AGY_JOBS } else { Join-Path $HOME ".cache\agy-jobs" }
$brainBase = Join-Path $HOME ".gemini\antigravity-cli\brain"
$STALL = if ($env:AGY_STALL_SEC) { [int]$env:AGY_STALL_SEC } else { 180 }

if (-not (Test-Path $jobsBase)) {
    [System.IO.Directory]::CreateDirectory($jobsBase) | Out-Null
}

function Show-Usage {
    @"
Cách dùng:
  agy-ctl list                    mọi job (mới nhất cuối): state, tuổi, tên, worktree
  agy-ctl status <job>            đang chạy hay xong; số step; bước/ chữ gần nhất
  agy-ctl tail <job> [n=15]       n event gần nhất, dạng rút gọn (theo dõi tiến độ)
  agy-ctl history <job|cid> [n]   transcript đầy đủ của agy (user/model/tool), cắt gọn
  agy-ctl summary <job>           kết quả cuối + token + (worktree) diffstat
  agy-ctl stop <job>|all [-y]     INTERRUPT: kill cả cây tiến trình, đánh dấu STOPPED
  agy-ctl wait <job> [sec=600]    chờ job xong (poll 3s), in state
  agy-ctl gc [days=3] [-y]        dọn job xong cũ hơn N ngày + worktree không có thay đổi
  agy-ctl wt-list                 worktree của các job -W đang tồn tại
  agy-ctl wt-diff <job> [--stat]  thay đổi job đã làm (so với lúc giao việc)
  agy-ctl wt-merge <job> -m "type(scope): ..." [-m thân] | --no-commit   [--3way]
                                  áp thay đổi vào cây làm việc; -m: commit đúng các file đó, một commit mang git
                                  identity của repo, message Conventional Commits không dấu vết agy/công cụ;
                                  --no-commit: để agent quản lý tự commit. Job không tạo commit/branch nào
  agy-ctl wt-drop <job>           bỏ thay đổi, dọn worktree
"@
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Show-Usage
    exit 2
}

function Read-Meta([string]$jobPath, [string]$key) {
    $metaFile = Join-Path $jobPath "meta.env"
    if (-not (Test-Path $metaFile)) { return "" }
    $lines = [System.IO.File]::ReadAllLines($metaFile)
    foreach ($line in $lines) {
        if ($line.StartsWith("$key=")) {
            return $line.Substring($key.Length + 1).Trim()
        }
    }
    return ""
}

function Test-Alive([string]$jobPath) {
    $pidFile = Join-Path $jobPath "pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $pidText = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($pidText)) { return $false }
    $procId = 0
    if ([int]::TryParse($pidText.Trim(), [ref]$procId)) {
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            return ($null -ne $proc -and -not $proc.HasExited)
        } catch {
            return $false
        }
    }
    return $false
}

function Get-JobState([string]$jobPath) {
    if (Test-Alive $jobPath) {
        return "RUNNING"
    }
    $stateFile = Join-Path $jobPath "state"
    if (Test-Path $stateFile) {
        return (Get-Content $stateFile -Raw -ErrorAction SilentlyContinue).Trim()
    }
    return "DEAD"
}

function Get-JobAge([string]$jobPath) {
    $startedStr = Read-Meta $jobPath "STARTED"
    $startedSec = 0
    if ([int64]::TryParse($startedStr, [ref]$startedSec)) {
        $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $diff = [Math]::Max(0, ($nowSec - $startedSec))
        $m = [Math]::Floor($diff / 60)
        $s = $diff % 60
        return ("{0}m{1:D2}s" -f $m, $s)
    }
    return "-m--s"
}

function Get-IdleSec([string]$jobPath) {
    $evFile = Join-Path $jobPath "events.jsonl"
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (Test-Path $evFile) {
        $mtime = [DateTimeOffset](Get-Item $evFile).LastWriteTimeUtc
        return [Math]::Max(0, ($nowSec - $mtime.ToUnixTimeSeconds()))
    }
    $startedStr = Read-Meta $jobPath "STARTED"
    $startedSec = 0
    if ([int64]::TryParse($startedStr, [ref]$startedSec)) {
        return [Math]::Max(0, ($nowSec - $startedSec))
    }
    return 0
}

function Get-CidOf([string]$jobPath) {
    $evFile = Join-Path $jobPath "events.jsonl"
    if (-not (Test-Path $evFile)) { return "-" }
    $lines = [System.IO.File]::ReadAllLines($evFile)
    foreach ($line in $lines) {
        if ($line.Contains('"event":"init"') -or $line.Contains('"event": "init"')) {
            try {
                $init = $line | ConvertFrom-Json
                if ($init.conversation_id) { return $init.conversation_id }
            } catch {}
        }
    }
    return "-"
}

function Resolve-Job([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) {
        [Console]::Error.WriteLine("agy-ctl: thiếu tên hoặc id job")
        exit 2
    }
    $dirs = Get-ChildItem -Path $jobsBase -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending
    # 1. Match prefix
    $match = $dirs | Where-Object { $_.Name.StartsWith($target) } | Select-Object -First 1
    if (-not $match) {
        # 2. Match substring
        $match = $dirs | Where-Object { $_.Name.Contains($target) } | Select-Object -First 1
    }
    if (-not $match) {
        [Console]::Error.WriteLine("agy-ctl: không tìm thấy job '$target' (chạy 'agy-ctl list')")
        exit 2
    }
    return $match.FullName
}

function Stop-JobProcess([string]$jobPath) {
    $pidFile = Join-Path $jobPath "pid"
    [System.IO.File]::WriteAllText((Join-Path $jobPath "stopped"), "")
    if (Test-Path $pidFile) {
        $pidText = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($pidText)) {
            $procId = 0
            if ([int]::TryParse($pidText.Trim(), [ref]$procId)) {
                try {
                    & taskkill /PID $procId /T /F 2>$null | Out-Null
                } catch {}
            }
        }
    }
}

# Worktree của job -W: không commit, không branch (giống wt.sh). BASE = tree id lúc giao việc; thay đổi của agy được chụp
# vào index riêng của worktree (git add -A). wt-merge áp đúng phần đó vào cây làm việc, -m thì commit đúng các file đó
# bằng git identity của repo. Job tạo trước thay đổi này (branch agy/<id>) vẫn dùng được; dọn thì xoá luôn branch cũ.
$WtMsgPattern = '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^()]+\))?!?: [^ ]'

function Wt-Snap([string]$w) {
    $ErrorActionPreference = "Continue"
    git -C $w add -A 2>$null | Out-Null
}

function Wt-Changed([string]$w, [string]$base) {
    $ErrorActionPreference = "Continue"
    Wt-Snap $w
    git -C $w diff --cached --quiet --no-ext-diff $base 2>$null
    return ($LASTEXITCODE -ne 0)
}

function Wt-Files([string]$w, [string]$base) {
    $ErrorActionPreference = "Continue"
    Wt-Snap $w
    return @(git -C $w -c core.quotePath=false diff --cached --name-only --no-renames $base 2>$null | Where-Object { $_ })
}

function Wt-Diff([string]$w, [string]$base, [string[]]$extra) {
    $ErrorActionPreference = "Continue"
    Wt-Snap $w
    git -C $w -c diff.relative=false diff --cached --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ @extra $base
}

function Wt-Remove([string]$repo, [string]$w, [string]$branch) {
    $ErrorActionPreference = "Continue"
    if ($w -and (Test-Path $w)) { git -C $repo worktree remove --force $w 2>$null | Out-Null }
    git -C $repo worktree prune 2>$null | Out-Null
    if ($branch) { git -C $repo branch -D $branch 2>$null | Out-Null }
}

# Message commit: dòng đầu theo Conventional Commits (AGY_COMMIT_PATTERN để đổi chuẩn), không dấu vết agy/công cụ.
# Trả "" nếu hợp lệ, không thì lý do.
function Test-CommitMsg([string]$id, [string[]]$msgs) {
    if ($msgs.Count -eq 0 -or [string]::IsNullOrWhiteSpace($msgs[0])) { return "thiếu message" }
    $subj = $msgs[0]; $all = $msgs -join "`n"
    $pat = if ($env:AGY_COMMIT_PATTERN) { $env:AGY_COMMIT_PATTERN } else { $WtMsgPattern }
    if ($subj -cnotmatch $pat) { return "dòng đầu không theo chuẩn commit (<type>(<scope>): <mô tả>): `"$subj`"" }
    if ($subj -imatch '^[a-z]+(\([^()]*\))?!?: *((wip|tmp|temp|fixup!|squash!)( |$)|(update|updates|changes?|misc|stuff|fix|fixes) *$)') { return "mô tả quá chung chung: `"$subj`". Ghi rõ đã đổi gì" }
    foreach ($bad in @($id, 'agy@local', '(agy subagent)', 'co-authored-by:', 'generated with', 'claude.ai/', 'claude-session', [char]::ConvertFromUtf32(0x1F916))) {
        if ($bad -and $all.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return "message mang dấu vết công cụ (`"$bad`"); chỉ mô tả thay đổi" }
    }
    if ($all -imatch '(?m)(^|[^a-z0-9-])(agy|antigravity)([^a-z0-9-]|$)') { return "message nhắc tới agy/antigravity; chỉ mô tả thay đổi" }
    return ""
}

# wt-merge: trả 0 xong (worktree đã dọn), 1 xung đột/commit hỏng (worktree giữ nguyên), 2 tham số/điều kiện sai (chưa đụng gì)
function Invoke-WtMerge([string]$jp, [string[]]$opts) {
    $ErrorActionPreference = "Continue"
    $repo = Read-Meta $jp "REPO"; $base = Read-Meta $jp "BASE"; $w = Read-Meta $jp "WORKTREE"; $b = Read-Meta $jp "BRANCH"
    $id = Split-Path $jp -Leaf
    $msgs = @(); $noCommit = $false; $three = $false
    for ($i = 0; $i -lt $opts.Count; $i++) {
        if ($opts[$i] -eq "-m") {
            if ($i + 1 -ge $opts.Count -or [string]::IsNullOrWhiteSpace($opts[$i + 1])) { Write-Output "-m cần message"; return 2 }
            $msgs += $opts[$i + 1]; $i++
        } elseif ($opts[$i] -eq "--no-commit") { $noCommit = $true }
        elseif ($opts[$i] -eq "--3way") { $three = $true }
        else { Write-Output "tham số lạ: $($opts[$i])"; return 2 }
    }
    if ($noCommit -and $msgs.Count -gt 0) { Write-Output "-m và --no-commit không đi cùng nhau"; return 2 }
    if (-not $noCommit -and $msgs.Count -eq 0) {
        Write-Output 'wt-merge cần message commit: agy-ctl wt-merge <job> -m "type(scope): việc đã làm" [-m "thân"]  (hoặc --no-commit rồi tự commit)'
        return 2
    }
    if (-not $w -or -not (Test-Path $w)) { Write-Output "worktree không còn: $w"; return 2 }
    if (-not (Wt-Changed $w $base)) { Write-Output "job không có thay đổi nào"; Wt-Remove $repo $w $b; return 0 }
    $files = @(Wt-Files $w $base)
    if (-not $noCommit) {
        $why = Test-CommitMsg $id $msgs
        if ($why) { Write-Output "từ chối message: $why"; return 2 }
        if (-not (git -C $repo config user.name) -or -not (git -C $repo config user.email)) {
            Write-Output "repo $repo chưa cấu hình git user.name/user.email: commit phải mang tên người dùng"; return 2
        }
        $dirty = @(git -C $repo -c core.quotePath=false --literal-pathspecs status --porcelain -- @files 2>$null)
        if ($dirty.Count -gt 0) {
            Write-Output "các file sau đang có thay đổi chưa commit của bạn, commit tự động sẽ trộn vào:"
            $dirty | ForEach-Object { Write-Output "  $_" }
            Write-Output "→ chạy lại với --no-commit, rồi tự commit đúng phần cần commit"
            return 2
        }
    }
    # patch ghi thẳng ra file (--output): không đi qua pipeline PowerShell, giữ nguyên byte của file binary
    $patch = [System.IO.Path]::GetTempFileName()
    git -C $w -c diff.relative=false diff --cached --binary --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "--output=$patch" $base 2>$null
    if ($three) {
        $err = git -C $repo apply --3way --whitespace=nowarn $patch 2>&1; $rc = $LASTEXITCODE
        if ($rc -ne 0 -and (git -C $repo diff --name-only --diff-filter=U)) { $rc = 2 }
    } else {
        $err = git -C $repo apply --check --whitespace=nowarn $patch 2>&1
        if ($LASTEXITCODE -eq 0) { $err = git -C $repo apply --whitespace=nowarn $patch 2>&1; $rc = $LASTEXITCODE } else { $rc = 1 }
    }
    Remove-Item $patch -Force -ErrorAction SilentlyContinue
    if ($rc -eq 2) {
        Write-Output "CONFLICT: đã gộp 3 chiều vào $repo, các file sau còn marker xung đột (sửa tay rồi git add):"
        git -C $repo diff --name-only --diff-filter=U | ForEach-Object { Write-Output "  $_" }
    } elseif ($rc -ne 0) {
        Write-Output "CONFLICT: không áp gọn được thay đổi của job vào $repo, chưa ghi gì:"
        @($err) | Select-Object -First 5 | ForEach-Object { Write-Output "  $_" }
    }
    if ($rc -ne 0) { Write-Output "worktree giữ nguyên: $w (xem: wt-diff; gộp 3 chiều: thêm --3way; bỏ: wt-drop)"; return 1 }
    Write-Output "đã áp thay đổi vào cây làm việc của $repo (CHƯA commit):"
    git -C $repo -c core.quotePath=false --literal-pathspecs status --short -- @files | ForEach-Object { Write-Output "  $_" }
    if ($noCommit) {
        Write-Output "COMMIT: chưa có commit nào. Agent quản lý review diff, chạy test, rồi tự commit bằng git identity của người dùng,"
        Write-Output "        message theo chuẩn commit của repo (Conventional Commits: <type>(<scope>): <mô tả>), không nhắc agy/Claude/AI/id job."
    } else {
        # message qua file (-F): tránh lỗi quoting tham số của PowerShell 5.1 với dấu ngoặc kép
        $msgFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($msgFile, (($msgs -join "`n`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        git -C $repo --literal-pathspecs add -A -- @files 2>$null | Out-Null
        git -C $repo --literal-pathspecs commit -q -F $msgFile -- @files
        $crc = $LASTEXITCODE
        Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
        if ($crc -ne 0) { Write-Output "commit thất bại (hook?): thay đổi vẫn nằm trong cây làm việc, chưa commit. Worktree giữ nguyên: $w"; return 1 }
        Write-Output ("đã commit: " + (git -C $repo log -1 --format='%h %an <%ae>: %s'))
    }
    Wt-Remove $repo $w $b
    Write-Output "đã dọn worktree $w"
    return 0
}

switch ($Command.ToLower()) {
    "list" {
        $dirs = Get-ChildItem -Path $jobsBase -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc
        foreach ($d in $dirs) {
            $jp = $d.FullName
            $st = Get-JobState $jp
            if ($st -eq "RUNNING" -and (Get-IdleSec $jp) -gt $STALL) {
                $st = "STALL?"
            }
            $ageStr = Get-JobAge $jp
            $wtCol = if (Read-Meta $jp "WORKTREE") { "worktree" } else { "-" }
            $phead = Read-Meta $jp "PROMPT_HEAD"
            if ($phead.Length -gt 50) { $phead = $phead.Substring(0, 50) }
            "{0,-9} {1,-7} {2}  {3}  {4}" -f $st, $ageStr, $d.Name, $wtCol, $phead
        }
    }

    "status" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $jobName = Split-Path $jp -Leaf
        $st = Get-JobState $jp
        $ageStr = Get-JobAge $jp
        $cid = Get-CidOf $jp
        $workdir = Read-Meta $jp "WORKDIR"
        $wtdir = Read-Meta $jp "WORKTREE"

        Write-Output "JOB=$jobName  STATE=$st  AGE=$ageStr  CID=$cid"
        Write-Output "WORKDIR=$workdir  WORKTREE=$wtdir"

        if (Test-Alive $jp) {
            $idle = Get-IdleSec $jp
            $warn = if ($idle -gt $STALL) { "  ⚠ STALL: không có event mới > $($STALL)s (xem history, cân nhắc stop)" } else { "" }
            Write-Output "IDLE=${idle}s$warn"
        }

        $evFile = Join-Path $jp "events.jsonl"
        if (Test-Path $evFile -and (Get-Item $evFile).Length -gt 0) {
            $lines = [System.IO.File]::ReadAllLines($evFile)
            $lastStepIdx = 0
            $lastStepStr = ""
            $lastText = ""
            foreach ($line in $lines) {
                if ($line.Contains('"event":"step_update"') -or $line.Contains('"event": "step_update"')) {
                    try {
                        $obj = $line | ConvertFrom-Json
                        if ($obj.step_update) {
                            $su = $obj.step_update
                            if ($su.step_index -ge $lastStepIdx) {
                                $lastStepIdx = $su.step_index
                                $lastStepStr = "#$($su.step_index) $($su.step_type) $($su.state)"
                            }
                            if ($su.text_delta) {
                                $lastText += ($su.text_delta -replace "[\r\n]", " ")
                            }
                        }
                    } catch {}
                }
            }
            Write-Output "STEPS=$lastStepIdx"
            Write-Output "LAST_STEP: $lastStepStr"
            if ($lastText.Length -gt 300) { $lastText = $lastText.Substring($lastText.Length - 300) }
            Write-Output "LAST_TEXT: $lastText"
        } else {
            Write-Output "(chưa có event; agy đang khởi động)"
        }

        $errFile = Join-Path $jp "err"
        if (Test-Path $errFile -and (Get-Item $errFile).Length -gt 0) {
            Write-Output "STDERR:"
            Get-Content $errFile -Tail 3 -ErrorAction SilentlyContinue | Write-Output
        }
    }

    "tail" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $n = if ($ArgsList.Count -gt 1) { [int]$ArgsList[1] } else { 15 }
        $jp = Resolve-Job $jobArg
        $evFile = Join-Path $jp "events.jsonl"
        if (-not (Test-Path $evFile)) { exit 0 }

        $updates = [System.Collections.Generic.List[string]]::new()
        $lines = [System.IO.File]::ReadAllLines($evFile)
        foreach ($line in $lines) {
            if ($line.Contains('"event":"step_update"') -or $line.Contains('"event": "step_update"')) {
                try {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.step_update) {
                        $su = $obj.step_update
                        $delta = if ($su.text_delta) {
                            $t = ($su.text_delta -replace "[\r\n]", " ")
                            if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
                            "  $t"
                        } else { "" }
                        $updates.Add("#$($su.step_index) $($su.step_type) $($su.state)$delta")
                    }
                } catch {}
            }
        }
        $start = [Math]::Max(0, $updates.Count - $n)
        for ($i = $start; $i -lt $updates.Count; $i++) {
            Write-Output $updates[$i]
        }
    }

    "history" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $n = if ($ArgsList.Count -gt 1) { [int]$ArgsList[1] } else { 40 }
        if ([string]::IsNullOrWhiteSpace($jobArg)) {
            [Console]::Error.WriteLine("agy-ctl: thiếu job hoặc conversation_id")
            exit 2
        }

        $cid = $jobArg
        # Thử xem có phải tên job không
        $matchDir = Get-ChildItem -Path $jobsBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($jobArg) -or $_.Name.Contains($jobArg) } | Select-Object -First 1
        if ($matchDir) {
            $extractedCid = Get-CidOf $matchDir.FullName
            if ($extractedCid -ne "-") { $cid = $extractedCid }
        }

        $tFile = Join-Path $brainBase "$cid\.system_generated\logs\transcript.jsonl"
        if (-not (Test-Path $tFile)) {
            [Console]::Error.WriteLine("agy-ctl: không có transcript cho conversation '$cid'")
            exit 2
        }

        $tLines = [System.IO.File]::ReadAllLines($tFile)
        $historyList = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $tLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                $src = if ($obj.source) { $obj.source } else { "" }
                $type = if ($obj.type) { $obj.type } else { "" }
                $status = if ($obj.status) { $obj.status } else { "" }
                $rawContent = if ($obj.content) { $obj.content } elseif ($obj.tool_calls) { ($obj.tool_calls | ConvertTo-Json -Compress) } else { "" }
                $snippet = ($rawContent -replace "[\r\n]", " ")
                if ($snippet.Length -gt 220) { $snippet = $snippet.Substring(0, 220) }
                $historyList.Add("#$($obj.step_index) [$src/$type] $status  $snippet")
            } catch {}
        }
        $start = [Math]::Max(0, $historyList.Count - $n)
        for ($i = $start; $i -lt $historyList.Count; $i++) {
            Write-Output $historyList[$i]
        }
    }

    "summary" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $jobName = Split-Path $jp -Leaf
        $st = Get-JobState $jp
        Write-Output "JOB=$jobName  STATE=$st"

        $resFile = Join-Path $jp "result.json"
        if (Test-Path $resFile) {
            try {
                $resObj = Get-Content $resFile -Raw | ConvertFrom-Json
                $tokens = if ($resObj.usage) { $resObj.usage.total_tokens } else { 0 }
                $turns = if ($resObj.num_turns) { $resObj.num_turns } else { 0 }
                $dur = if ($resObj.duration_seconds) { [Math]::Floor($resObj.duration_seconds) } else { 0 }
                Write-Output "TOKENS=$tokens TURNS=$turns DURATION=${dur}s"
                Write-Output "---"
                if ($resObj.response) { Write-Output $resObj.response }
            } catch {}
        } else {
            Write-Output "(chưa có result — job $jobArg chưa xong hoặc lỗi; dùng status/tail/history)"
        }

        $wtdir = Read-Meta $jp "WORKTREE"
        if (-not [string]::IsNullOrWhiteSpace($wtdir) -and (Test-Path $wtdir)) {
            Write-Output "--- DIFFSTAT $wtdir"
            Wt-Diff $wtdir (Read-Meta $jp "BASE") @("--stat") | Write-Output
        }
    }

    "stop" {
        $target = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        if ([string]::IsNullOrWhiteSpace($target)) {
            [Console]::Error.WriteLine("agy-ctl: thiếu job hoặc 'all'")
            exit 2
        }

        $targets = [System.Collections.Generic.List[string]]::new()
        if ($target.ToLower() -eq "all") {
            $dirs = Get-ChildItem -Path $jobsBase -Directory -ErrorAction SilentlyContinue
            foreach ($d in $dirs) {
                if (Test-Alive $d.FullName) {
                    $targets.Add($d.FullName)
                }
            }
            $yes = ($ArgsList | Where-Object { $_ -eq "-y" })
            if (-not $yes) {
                Write-Output "Sẽ kill $($targets.Count) job:"
                foreach ($t in $targets) {
                    Write-Output "  $(Split-Path $t -Leaf)  $(Read-Meta $t 'WORKDIR')"
                }
                Write-Output "Chạy lại: agy-ctl stop all -y"
                exit 1
            }
        } else {
            $targets.Add((Resolve-Job $target))
        }

        if ($targets.Count -eq 0) {
            Write-Output "không có job nào đang chạy"
            exit 0
        }

        foreach ($jp in $targets) {
            $name = Split-Path $jp -Leaf
            if (-not (Test-Alive $jp)) {
                Write-Output "${name}: không chạy"
                continue
            }
            Stop-JobProcess $jp
            $cid = Get-CidOf $jp
            Write-Output "${name}: đã interrupt (resume được bằng agy-sub -r $cid)"
        }
    }

    "wait" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $lim = if ($ArgsList.Count -gt 1) { [int]$ArgsList[1] } else { 600 }
        $jp = Resolve-Job $jobArg
        $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        while (Test-Alive $jp) {
            $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $t0
            if ($elapsed -gt $lim) {
                Write-Output "RUNNING (hết ${lim}s chờ)"
                exit 1
            }
            Start-Sleep -Seconds 3
        }
        Write-Output (Get-JobState $jp)
    }

    "wt-list" {
        $dirs = Get-ChildItem -Path $jobsBase -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $jp = $d.FullName
            $w = Read-Meta $jp "WORKTREE"
            if (-not [string]::IsNullOrWhiteSpace($w) -and (Test-Path $w)) {
                "{0}  {1}  {2}" -f (Get-JobState $jp), $d.Name, $w
            }
        }
    }

    "wt-diff" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $wtdir = Read-Meta $jp "WORKTREE"
        if ([string]::IsNullOrWhiteSpace($wtdir)) {
            [Console]::Error.WriteLine("job này không chạy với -W")
            exit 2
        }
        if (-not (Test-Path $wtdir)) { [Console]::Error.WriteLine("worktree không còn: $wtdir"); exit 2 }
        $extra = if ($ArgsList.Count -gt 1) { @($ArgsList[1..($ArgsList.Count - 1)]) } else { @() }
        Wt-Diff $wtdir (Read-Meta $jp "BASE") $extra
    }

    "wt-merge" {
        # Không merge branch nào, không commit hộ agy. Sự cố 2026-10-15: merge --no-ff kéo commit "agy: ..." + "Merge agy/..." vào 3 MR.
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        if ([string]::IsNullOrWhiteSpace((Read-Meta $jp "WORKTREE"))) {
            [Console]::Error.WriteLine("job này không chạy với -W")
            exit 2
        }
        if ((Get-JobState $jp) -eq "RUNNING") {
            [Console]::Error.WriteLine("job còn đang chạy")
            exit 2
        }
        $opts = if ($ArgsList.Count -gt 1) { @($ArgsList[1..($ArgsList.Count - 1)]) } else { @() }
        $out = @(Invoke-WtMerge $jp $opts)
        $rc = $out[-1]
        if ($out.Count -gt 1) { $out[0..($out.Count - 2)] | ForEach-Object { Write-Output $_ } }
        exit $rc
    }

    "wt-drop" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $wtdir = Read-Meta $jp "WORKTREE"
        if ([string]::IsNullOrWhiteSpace($wtdir)) {
            [Console]::Error.WriteLine("job này không chạy với -W")
            exit 2
        }
        Wt-Remove (Read-Meta $jp "REPO") $wtdir (Read-Meta $jp "BRANCH")
        Write-Output "đã bỏ thay đổi của $(Split-Path $jp -Leaf), dọn worktree $wtdir"
    }

    "gc" {
        $days = 3
        $yes = $false
        foreach ($a in $ArgsList) {
            if ($a -eq "-y") { $yes = $true }
            else {
                $parsedDays = 0
                if ([int]::TryParse($a, [ref]$parsedDays)) { $days = $parsedDays }
            }
        }

        $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $keep = 0
        $del = 0
        $dirs = Get-ChildItem -Path $jobsBase -Directory -ErrorAction SilentlyContinue

        foreach ($d in $dirs) {
            $jp = $d.FullName
            if (Test-Alive $jp) { continue }

            $st = Get-JobState $jp
            $startedStr = Read-Meta $jp "STARTED"
            $startedSec = 0
            if ([int64]::TryParse($startedStr, [ref]$startedSec)) {
                if (($nowSec - $startedSec) -lt ($days * 86400)) { continue }
            }

            $b = Read-Meta $jp "BRANCH"
            $w = Read-Meta $jp "WORKTREE"
            $r = Read-Meta $jp "REPO"
            $base = Read-Meta $jp "BASE"

            $hasWt = -not [string]::IsNullOrWhiteSpace($w) -and (Test-Path $w)
            if ($hasWt -and (Wt-Changed $w $base)) {
                Write-Output "GIỮ   $($d.Name)  (worktree còn thay đổi chưa áp: wt-merge hoặc wt-drop)"
                $keep++
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($b)) {
                $ErrorActionPreference = "Continue"
                $headRev = (git -C $r rev-parse -q --verify $b 2>$null)
                $ErrorActionPreference = "Stop"
                if ($headRev -and $headRev.Trim() -ne $base) {
                    Write-Output "GIỮ   $($d.Name)  (branch kiểu cũ $b còn commit chưa gộp: git -C $r diff $base $b; bỏ: git -C $r branch -D $b)"
                    $keep++
                    continue
                }
            }
            if ($hasWt) { Write-Output "DỌN   $($d.Name)  + worktree rỗng $w" } else { Write-Output "DỌN   $($d.Name)  ($st)" }
            if ($yes -and $r -and (Test-Path $r)) { Wt-Remove $r $w $b }

            $del++
            if ($yes) {
                Remove-Item -Path $jp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Output "$del job dọn$(if (-not $yes) { ' (chưa xóa, thêm -y)' } else { '' }), $keep job giữ lại"
    }

    default {
        Show-Usage
        exit 2
    }
}
