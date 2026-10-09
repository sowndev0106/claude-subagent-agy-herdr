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
  agy-ctl list                    mọi job (mới nhất cuối): state, tuổi, tên, branch
  agy-ctl status <job>            đang chạy hay xong; số step; bước/ chữ gần nhất
  agy-ctl tail <job> [n=15]       n event gần nhất, dạng rút gọn (theo dõi tiến độ)
  agy-ctl history <job|cid> [n]   transcript đầy đủ của agy (user/model/tool), cắt gọn
  agy-ctl summary <job>           kết quả cuối + token + (worktree) diffstat
  agy-ctl stop <job>|all [-y]     INTERRUPT: kill cả cây tiến trình, đánh dấu STOPPED
  agy-ctl wait <job> [sec=600]    chờ job xong (poll 3s), in state
  agy-ctl gc [days=3] [-y]        dọn job xong cũ hơn N ngày + worktree không có thay đổi
  agy-ctl wt-list                 worktree agy/* đang tồn tại
  agy-ctl wt-diff <job>           diff đầy đủ branch agy/<id> so với nơi tách ra
  agy-ctl wt-merge <job>          merge agy/<id> vào repo rồi dọn (job -C: áp diff vào cây làm việc)
  agy-ctl wt-drop <job>           bỏ worktree + branch (không merge)
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
            $branch = Read-Meta $jp "BRANCH"
            $phead = Read-Meta $jp "PROMPT_HEAD"
            if ($phead.Length -gt 50) { $phead = $phead.Substring(0, 50) }
            "{0,-9} {1,-7} {2}  {3}  {4}" -f $st, $ageStr, $d.Name, $branch, $phead
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
        $branch = Read-Meta $jp "BRANCH"

        Write-Output "JOB=$jobName  STATE=$st  AGE=$ageStr  CID=$cid"
        Write-Output "WORKDIR=$workdir  BRANCH=$branch"

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

        $branch = Read-Meta $jp "BRANCH"
        $repo = Read-Meta $jp "REPO"
        if (-not [string]::IsNullOrWhiteSpace($branch) -and -not [string]::IsNullOrWhiteSpace($repo)) {
            Write-Output "--- DIFFSTAT $branch"
            git -C $repo diff --stat "HEAD...$branch" 2>$null | Write-Output
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
            $b = Read-Meta $jp "BRANCH"
            if (-not [string]::IsNullOrWhiteSpace($w) -and (Test-Path $w)) {
                "{0}  {1}  {2}" -f (Get-JobState $jp), $b, $w
            }
        }
    }

    "wt-diff" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $repo = Read-Meta $jp "REPO"
        $base = Read-Meta $jp "BASE"
        $branch = Read-Meta $jp "BRANCH"
        if ([string]::IsNullOrWhiteSpace($branch)) {
            [Console]::Error.WriteLine("job này không chạy với -W")
            exit 2
        }
        git -C $repo diff $base $branch
    }

    "wt-merge" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $repo = Read-Meta $jp "REPO"
        $base = Read-Meta $jp "BASE"
        $branch = Read-Meta $jp "BRANCH"
        $wtdir = Read-Meta $jp "WORKTREE"
        $carry = Read-Meta $jp "CARRY"

        if ([string]::IsNullOrWhiteSpace($branch)) {
            [Console]::Error.WriteLine("job này không chạy với -W")
            exit 2
        }
        if ((Get-JobState $jp) -eq "RUNNING") {
            [Console]::Error.WriteLine("job còn đang chạy")
            exit 2
        }

        if ($carry -eq "1") {
            $diffBytes = git -C $repo diff --binary $base $branch 2>$null
            $diffText = ($diffBytes -join "`n")
            $diffText | git -C $repo apply --3way --whitespace=nowarn - 2>$null
            if ($LASTEXITCODE -ne 0) {
                [Console]::Error.WriteLine("CONFLICT khi áp diff vào cây làm việc của $repo (xem git status, marker). Worktree giữ nguyên: $wtdir")
                exit 1
            }
            Write-Output "đã áp thay đổi của agy vào cây làm việc (chưa commit)"
        } else {
            git -C $repo merge --no-ff -m "Merge $branch (agy subagent)" $branch
            if ($LASTEXITCODE -ne 0) {
                [Console]::Error.WriteLine("CONFLICT: giải quyết tay trong $repo rồi commit, hoặc git merge --abort")
                exit 1
            }
        }

        git -C $repo worktree remove --force $wtdir 2>$null | Out-Null
        git -C $repo branch -D $branch 2>$null | Out-Null
        Write-Output "đã dọn $branch"
    }

    "wt-drop" {
        $jobArg = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }
        $jp = Resolve-Job $jobArg
        $repo = Read-Meta $jp "REPO"
        $branch = Read-Meta $jp "BRANCH"
        $wtdir = Read-Meta $jp "WORKTREE"

        if ([string]::IsNullOrWhiteSpace($branch)) {
            [Console]::Error.WriteLine("job này không chạy với -W")
            exit 2
        }
        git -C $repo worktree remove --force $wtdir 2>$null | Out-Null
        git -C $repo branch -D $branch 2>$null | Out-Null
        Write-Output "đã bỏ $branch"
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

            if (-not [string]::IsNullOrWhiteSpace($b) -and (Test-Path $w)) {
                $headRev = (git -C $r rev-parse $b 2>$null)
                if ($headRev -and $headRev.Trim() -ne $base) {
                    Write-Output "GIỮ   $($d.Name)  ($b có thay đổi chưa merge: wt-merge hoặc wt-drop)"
                    $keep++
                    continue
                }
                Write-Output "DỌN   $($d.Name)  + worktree rỗng $w"
                if ($yes) {
                    git -C $r worktree remove --force $w 2>$null | Out-Null
                    git -C $r branch -D $b 2>$null | Out-Null
                }
            } else {
                Write-Output "DỌN   $($d.Name)  ($st)"
            }

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
