#Requires -Version 5.1
<#
.SYNOPSIS
    Chạy agy (Antigravity CLI) như một subagent trên Windows: 1 prompt vào, kết quả gọn ra.
    LUÔN bypass permission + gemini-3.8-flash-high.

.DESCRIPTION
    Bản Windows PowerShell của agy-sub.sh:
    Hỗ trợ git worktree cô lập (-W), mang thay đổi chưa commit (-C),
    chế độ chỉ đọc (-R), JSON schema structured output (-s), timeout watchdog với process tree kill,
    và lưu vết job tại $HOME/.cache/agy-jobs/<id>.

.EXAMPLE
    .\agy-sub.ps1 -p "Kiểm tra cú pháp file X"
    .\agy-sub.ps1 -n "fix-bug" -d "C:\repo" -W -f task.md
    .\agy-sub.ps1 -R -d "C:\repo" -s schema.json -p "Review code"
#>

[CmdletBinding()]
param(
    [Alias("p")]
    [string]$Prompt = "",

    [Alias("f")]
    [string]$File = "",

    [Alias("n")]
    [string]$Name = "job",

    [Alias("d")]
    [string]$WorkDir = (Get-Location).Path,

    [Alias("r")]
    [string]$ConversationId = "",

    [Alias("s")]
    [string]$Schema = "",

    [Alias("a")]
    [string[]]$AddDir = @(),

    [Alias("o")]
    [string]$OutFile = "",

    [Alias("t")]
    [int]$Timeout = 600,

    [Alias("R")]
    [switch]$ReadOnly,

    [Alias("W")]
    [switch]$Worktree,

    [Alias("C")]
    [switch]$Carry,

    [Alias("S")]
    [switch]$Sandbox
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$MODEL = "gemini-3.8-flash-high"
$jobsBase = if ($env:AGY_JOBS) { $env:AGY_JOBS } else { Join-Path $HOME ".cache\agy-jobs" }

# 1. Đọc Prompt từ file, param hoặc stdin
if ([string]::IsNullOrWhiteSpace($Prompt) -and -not [string]::IsNullOrWhiteSpace($File)) {
    if (-not (Test-Path $File)) {
        [Console]::Error.WriteLine("agy-sub: file prompt không tồn tại: $File")
        exit 2
    }
    $Prompt = [System.IO.File]::ReadAllText((Resolve-Path $File).Path, [System.Text.Encoding]::UTF8)
}

if ([string]::IsNullOrWhiteSpace($Prompt)) {
    # Kiểm tra stdin nếu được pipe vào
    if ([Console]::IsInputRedirected) {
        $stdinText = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($stdinText)) {
            $Prompt = $stdinText
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Prompt)) {
    [Console]::Error.WriteLine("agy-sub: thiếu prompt (-p, -f hoặc stdin)")
    exit 2
}

# 2. Kiểm tra công cụ và thư mục làm việc
# Chỉ chạy agy.exe. Một agy.cmd/.bat sẽ được Windows chạy qua cmd.exe, và cmd.exe đọc lại cả dòng lệnh:
# prompt chứa & | > ^ thành lệnh shell (chèn lệnh). Format-Arg bên dưới chỉ đúng cho file .exe.
$agyCmd = Get-Command "agy.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $agyCmd) {
    $other = Get-Command "agy" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($other) {
        [Console]::Error.WriteLine("agy-sub: chỉ chạy agy.exe; thấy '$($other.Source)' (.cmd/.bat/.ps1 sẽ để cmd.exe đọc lại prompt). Thêm thư mục chứa agy.exe vào PATH.")
    } else {
        [Console]::Error.WriteLine("agy-sub: không thấy agy.exe trong PATH. Cài: agy-setup\scripts\setup.ps1 fix")
    }
    exit 2
}
if ($agyCmd.Source -notmatch '\.exe$') {
    [Console]::Error.WriteLine("agy-sub: '$($agyCmd.Source)' không phải file .exe; từ chối chạy để tránh chèn lệnh qua cmd.exe")
    exit 2
}

if (-not (Test-Path $WorkDir)) {
    [Console]::Error.WriteLine("agy-sub: workdir không tồn tại: $WorkDir")
    exit 2
}
$WorkDir = (Resolve-Path $WorkDir).Path

# Chuẩn hoá tên job
$cleanName = ($Name -replace '[^A-Za-z0-9_.-]', '_')
if ([string]::IsNullOrWhiteSpace($cleanName)) { $cleanName = "job" }

$timestamp = Get-Date -Format "HHmmss"
$rand = Get-Random -Minimum 1000 -Maximum 9999
$id = "$cleanName-$timestamp-$rand"
$jobDir = Join-Path $jobsBase $id

if (-not (Test-Path $jobDir)) {
    [System.IO.Directory]::CreateDirectory($jobDir) | Out-Null
}

$branch = ""
$wtdir = ""
$repo = ""
$base = ""

if ($Carry -and -not $Worktree) {
    [Console]::Error.WriteLine("agy-sub: -C cần -W")
    exit 2
}

# 3. Xử lý Git Worktree (-W, -C)
if ($Worktree) {
    try {
        $repoOutput = git -C $WorkDir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $repoOutput) {
            $repo = $repoOutput.Trim()
        }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($repo)) {
        [Console]::Error.WriteLine("agy-sub: -W cần workdir là git repo")
        exit 2
    }

    $rel = ""
    try {
        $relOutput = git -C $WorkDir rev-parse --show-prefix 2>$null
        if ($LASTEXITCODE -eq 0 -and $relOutput) {
            $rel = $relOutput.Trim()
        }
    } catch {}

    $branch = "agy/$id"
    $repoName = Split-Path $repo -Leaf
    $repoParent = Split-Path $repo -Parent
    $wtdir = Join-Path (Join-Path $repoParent ".agy-wt") "$repoName-$id"

    $wtParent = Split-Path $wtdir -Parent
    if (-not (Test-Path $wtParent)) {
        [System.IO.Directory]::CreateDirectory($wtParent) | Out-Null
    }

    git -C $repo worktree add -q -b $branch $wtdir HEAD
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("agy-sub: tạo worktree thất bại")
        exit 2
    }

    $wtdir = (Resolve-Path $wtdir).Path
    $WorkDir = if ($rel) { Join-Path $wtdir $rel } else { $wtdir }
    $base = (git -C $wtdir rev-parse HEAD 2>$null).Trim()

    $statusPorcelain = git -C $repo status --porcelain 2>$null
    if ($statusPorcelain) {
        if ($Carry) {
            # Chuyển thay đổi tracked (kể cả binary) và untracked sang worktree
            $diffBytes = git -C $repo diff --binary HEAD 2>$null
            if ($diffBytes) {
                $diffText = ($diffBytes -join "`n")
                $diffText | git -C $wtdir apply --whitespace=nowarn - 2>$null
                if ($LASTEXITCODE -ne 0) {
                    [Console]::Error.WriteLine("agy-sub: carry diff thất bại")
                    exit 2
                }
            }

            $untracked = git -C $repo ls-files -z -o --exclude-standard 2>$null
            if ($untracked) {
                $files = ($untracked -join "`0") -split "`0"
                foreach ($f in $files) {
                    if ([string]::IsNullOrWhiteSpace($f)) { continue }
                    $src = Join-Path $repo $f
                    $dst = Join-Path $wtdir $f
                    $dstDir = Split-Path $dst -Parent
                    if (-not (Test-Path $dstDir)) {
                        [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null
                    }
                    if (Test-Path $src -PathType Leaf) {
                        Copy-Item -Path $src -Destination $dst -Force
                    }
                }
            }

            git -C $wtdir add -A 2>$null
            git -C $wtdir -c user.name=agy -c user.email=agy@local commit -q -m "carry: thay đổi chưa commit của repo trước job $id" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $base = (git -C $wtdir rev-parse HEAD 2>$null).Trim()
            }
        } else {
            [Console]::Error.WriteLine("WARN: repo có thay đổi chưa commit, worktree KHÔNG thấy chúng (chỉ thấy HEAD). Dùng -C để mang theo.")
        }
    }
}

# 4. Tính tree signature cho Read-Only (-R)
function Get-TreeSig([string]$dir) {
    $stat = git -C $dir status --porcelain 2>$null
    $diff = git -C $dir diff HEAD 2>$null
    $raw = (($stat -join "`n") + "`n" + ($diff -join "`n"))
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    return [BitConverter]::ToString($hash).Replace("-", "").ToLower()
}

$sigBefore = ""
if ($ReadOnly) {
    $Sandbox = $true
    $sigBefore = Get-TreeSig $WorkDir
}

# 5. Ràng buộc an toàn vào prompt
$guard = "Ràng buộc: không git push/commit/reset/checkout/branch, không xóa file ngoài phạm vi được giao, không truy cập mạng nội bộ 10.0.0.0/8, không bật process nền (nohup/setsid)."
if ($Worktree) {
    $guard += " Bạn đang ở git worktree riêng: chỉ sửa file trong thư mục hiện tại, đừng cd ra ngoài."
}
if ($ReadOnly) {
    $guard += " CHẾ ĐỘ CHỈ ĐỌC: tuyệt đối không tạo/sửa/xóa file, chỉ đọc và báo cáo."
}
$fullPrompt = "$Prompt`n`n$guard"

# 6. Ghi metadata
$startedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$promptHead = ($Prompt -replace "[\r\n`$`"'\\]", " ")
if ($promptHead.Length -gt 120) { $promptHead = $promptHead.Substring(0, 120) }

$metaContent = @"
ID=$id
NAME=$cleanName
WORKDIR=$WorkDir
REPO=$repo
WORKTREE=$wtdir
BRANCH=$branch
BASE=$base
CARRY=$(if ($Carry) { 1 } else { 0 })
STARTED=$startedEpoch
TIMEOUT=$Timeout
RO=$(if ($ReadOnly) { 1 } else { 0 })
PROMPT_HEAD=$promptHead
"@
[System.IO.File]::WriteAllText((Join-Path $jobDir "meta.env"), $metaContent, [System.Text.Encoding]::UTF8)
[Console]::Error.WriteLine("JOB=$id")

# 7. Xây dựng argument list cho agy
$agyArgsList = [System.Collections.Generic.List[string]]::new()
$agyArgsList.Add("-p")
$agyArgsList.Add($fullPrompt)
$agyArgsList.Add("--model")
$agyArgsList.Add($MODEL)
$agyArgsList.Add("--effort")
$agyArgsList.Add("high")
$agyArgsList.Add("--dangerously-skip-permissions")
$agyArgsList.Add("--output-format")
$agyArgsList.Add("stream-json")

if ($Sandbox) { $agyArgsList.Add("--sandbox") }
if (-not [string]::IsNullOrWhiteSpace($ConversationId)) {
    $agyArgsList.Add("--conversation")
    $agyArgsList.Add($ConversationId)
}
if (-not [string]::IsNullOrWhiteSpace($Schema)) {
    $agyArgsList.Add("--json-schema")
    $agyArgsList.Add($Schema)
}
foreach ($ad in $AddDir) {
    if (-not [string]::IsNullOrWhiteSpace($ad)) {
        $agyArgsList.Add("--add-dir")
        $agyArgsList.Add($ad)
    }
}

function Format-Arg([string]$arg) {
    if ([string]::IsNullOrEmpty($arg)) { return '""' }
    if ($arg -notmatch '[\s"]') { return $arg }
    $escaped = [regex]::Replace($arg, '(\\*)(")', {
        param($m)
        $m.Groups[1].Value + $m.Groups[1].Value + '\"'
    })
    $escaped = [regex]::Replace($escaped, '(\\+)$', {
        param($m)
        $m.Groups[1].Value + $m.Groups[1].Value
    })
    return '"' + $escaped + '"'
}

$eventsFile = Join-Path $jobDir "events.jsonl"
$errFile = Join-Path $jobDir "err"
$pidFile = Join-Path $jobDir "pid"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $agyCmd.Source
$formattedArgs = ($agyArgsList | ForEach-Object { Format-Arg $_ }) -join ' '
$psi.Arguments = $formattedArgs
$psi.WorkingDirectory = $WorkDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$pidNum = $proc.Id
[System.IO.File]::WriteAllText($pidFile, "$pidNum")

# Đóng stdin ngay (tương đương </dev/null) để tránh agy treo chờ input
$proc.StandardInput.Close()

# Đọc luồng async sang file song song
$outTask = [System.Threading.Tasks.Task]::Run([System.Action]{
    $fs = [System.IO.File]::Open($eventsFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($fs)
    } finally {
        $fs.Dispose()
    }
})

$errTask = [System.Threading.Tasks.Task]::Run([System.Action]{
    $fs = [System.IO.File]::Open($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $proc.StandardError.BaseStream.CopyTo($fs)
    } finally {
        $fs.Dispose()
    }
})

# 8. Vòng lặp giám sát timeout & stopped
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$timedOut = $false

while (-not $proc.WaitForExit(1000)) {
    if ($stopwatch.Elapsed.TotalSeconds -ge $Timeout) {
        $timedOut = $true
        [System.IO.File]::WriteAllText((Join-Path $jobDir "timedout"), "")
        try {
            & taskkill /PID $pidNum /T /F 2>$null | Out-Null
        } catch {}
        break
    }
    if (Test-Path (Join-Path $jobDir "stopped")) {
        try {
            & taskkill /PID $pidNum /T /F 2>$null | Out-Null
        } catch {}
        break
    }
}

# Đợi hoàn tất ghi file I/O (tối đa 3 giây)
[System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 3000) | Out-Null

if (Test-Path $pidFile) {
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# 9. Đọc kết quả từ events.jsonl
$resultObj = $null
$cid = ""

if (Test-Path $eventsFile) {
    $lines = [System.IO.File]::ReadAllLines($eventsFile)
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Contains('"event":"init"') -or $line.Contains('"event": "init"')) {
            try {
                $init = $line | ConvertFrom-Json
                if ($init.conversation_id) { $cid = $init.conversation_id }
            } catch {}
        }
        if ($line.Contains('"event":"result"') -or $line.Contains('"event": "result"')) {
            try {
                $ev = $line | ConvertFrom-Json
                if ($ev.result) { $resultObj = $ev.result }
            } catch {}
        }
    }
}

if ($resultObj) {
    $jsonFormatted = ($resultObj | ConvertTo-Json -Depth 20)
    [System.IO.File]::WriteAllText((Join-Path $jobDir "result.json"), $jsonFormatted, [System.Text.Encoding]::UTF8)
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        [System.IO.File]::WriteAllText($OutFile, $jsonFormatted, [System.Text.Encoding]::UTF8)
    }
}

# 10. Xác định state
$state = ""
$rc = 0

if (Test-Path (Join-Path $jobDir "stopped")) {
    $state = "STOPPED"
    $rc = 130
} elseif ($timedOut -or (Test-Path (Join-Path $jobDir "timedout"))) {
    $state = "TIMEOUT"
    $rc = 124
} elseif (-not $resultObj) {
    $state = "ERROR"
    $rc = 1
} else {
    $state = if ($resultObj.status) { $resultObj.status } else { "ERROR" }
}

$roViolation = $false
if ($ReadOnly) {
    $sigAfter = Get-TreeSig $WorkDir
    if ($sigAfter -ne $sigBefore) {
        $roViolation = $true
        $state = "RO_VIOLATION"
    }
}
[System.IO.File]::WriteAllText((Join-Path $jobDir "state"), $state, [System.Text.Encoding]::UTF8)

# 11. Worktree commit kết quả
$diffstat = ""
if ($wtdir) {
    $dirty = git -C $wtdir status --porcelain 2>$null
    if ($dirty) {
        git -C $wtdir add -A 2>$null
        git -C $wtdir -c user.name=agy -c user.email=agy@local commit -q -m "agy($cleanName): $id" 2>$null | Out-Null
    }
    $diffLines = git -C $repo diff --stat $base $branch 2>$null
    if ($diffLines) {
        $diffstat = ($diffLines | Select-Object -Last 20) -join "`n"
    }
}

# 12. In kết quả chuẩn ra stdout
Write-Output "JOB=$id"
Write-Output "CONVERSATION_ID=$(if ($cid) { $cid } else { '-' })"
Write-Output "STATUS=$state"

if ($resultObj -and $resultObj.usage) {
    $totalTokens = $resultObj.usage.total_tokens
    $durSec = if ($resultObj.duration_seconds) { [Math]::Floor($resultObj.duration_seconds) } else { 0 }
    Write-Output "TOKENS=$totalTokens DURATION=${durSec}s"
}

Write-Output "RAW=$(Join-Path $jobDir 'result.json')"

if ($wtdir) {
    Write-Output "BRANCH=$branch"
    Write-Output "WORKTREE=$wtdir"
    Write-Output "DIFFSTAT:"
    if ($diffstat) {
        Write-Output $diffstat
    } else {
        Write-Output "  (không có thay đổi)"
    }
}

Write-Output "---"

if ($resultObj) {
    if (-not [string]::IsNullOrWhiteSpace($Schema) -and $resultObj.PSObject.Properties['structured_output']) {
        Write-Output ($resultObj.structured_output | ConvertTo-Json -Depth 20)
    } elseif ($resultObj.response) {
        Write-Output $resultObj.response
    } else {
        Write-Output ($resultObj | ConvertTo-Json -Depth 20)
    }
} else {
    Write-Output "(không có kết quả; xem $(Join-Path $jobDir 'err') và $(Join-Path $jobDir 'events.jsonl'))"
    if (Test-Path $errFile) {
        $errTail = Get-Content $errFile -Tail 5 -ErrorAction SilentlyContinue
        if ($errTail) { Write-Output $errTail }
    }
}

if ($roViolation) {
    [Console]::Error.WriteLine("⚠ RO_VIOLATION: cây làm việc đổi trong lúc chạy -R. Xem: git -C $WorkDir status; hoàn tác trước khi tin kết quả.")
}

if ($state -eq "SUCCESS") { exit 0 }
if ($state -eq "TIMEOUT") { exit 124 }
if ($state -eq "STOPPED") { exit 130 }
exit 1
