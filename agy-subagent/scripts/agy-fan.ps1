#Requires -Version 5.1
<#
.SYNOPSIS
    Chạy NHIỀU agy song song trên Windows. Mỗi task = 1 file prompt trong thư mục tasks/.

.DESCRIPTION
    Bản Windows PowerShell của agy-fan.sh:
    Chạy song song tối đa 4 task (mặc định 3). Mỗi task gọi agy-sub.ps1.
    Xuất kết quả từng task và bảng tổng hợp SUMMARY.tsv.

.EXAMPLE
    .\agy-fan.ps1 -i .\tasks -o .\results -j 3 -d C:\repo -W
#>

[CmdletBinding()]
param(
    [Alias("i")]
    [Parameter(Mandatory = $true)]
    [string]$TasksDir,

    [Alias("o")]
    [Parameter(Mandatory = $true)]
    [string]$ResultsDir,

    [Alias("j")]
    [int]$Jobs = 3,

    [Alias("d")]
    [string]$WorkDir = (Get-Location).Path,

    [Alias("t")]
    [int]$Timeout = 900,

    [Alias("R")]
    [switch]$ReadOnly,

    [Alias("W")]
    [switch]$Worktree,

    [Alias("C")]
    [switch]$Carry
)


function Format-Arg([string]$arg) {
    # Quy tắc trích dẫn của CommandLineToArgvW (đúng cho powershell.exe / file .exe); không dùng cho .cmd/.bat
    if ([string]::IsNullOrEmpty($arg)) { return '""' }
    if ($arg -notmatch '[\s"]') { return $arg }
    $escaped = [regex]::Replace($arg, '(\\*)(")', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value + $m.Groups[1].Value })
    return '"' + $escaped + '"'
}

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

if (-not (Test-Path $TasksDir)) {
    [Console]::Error.WriteLine("agy-fan: thư mục tasks không tồn tại: $TasksDir")
    exit 2
}

if (-not (Test-Path $WorkDir)) {
    [Console]::Error.WriteLine("agy-fan: workdir không tồn tại: $WorkDir")
    exit 2
}

$TasksDir = (Resolve-Path $TasksDir).Path
$WorkDir = (Resolve-Path $WorkDir).Path

if ($Jobs -gt 4) { $Jobs = 4 }
if ($Jobs -lt 1) { $Jobs = 1 }

if (-not (Test-Path $ResultsDir)) {
    [System.IO.Directory]::CreateDirectory($ResultsDir) | Out-Null
}
$ResultsDir = (Resolve-Path $ResultsDir).Path

$taskFiles = Get-ChildItem -Path $TasksDir -Filter "*.md" | Sort-Object Name
if ($taskFiles.Count -eq 0) {
    [Console]::Error.WriteLine("agy-fan: không tìm thấy file *.md nào trong $TasksDir")
    exit 2
}

$scriptDir = $PSScriptRoot
$subScript = Join-Path $scriptDir "agy-sub.ps1"
if (-not (Test-Path $subScript)) {
    [Console]::Error.WriteLine("agy-fan: không tìm thấy agy-sub.ps1 tại $scriptDir")
    exit 2
}

$summaryFile = Join-Path $ResultsDir "SUMMARY.tsv"
[System.IO.File]::WriteAllText($summaryFile, "")

$pendingQueue = [System.Collections.Generic.Queue[System.IO.FileInfo]]::new()
foreach ($tf in $taskFiles) {
    $pendingQueue.Enqueue($tf)
}

$runningSlots = [System.Collections.Generic.List[hashtable]]::new()
$completedResults = [System.Collections.Generic.List[hashtable]]::new()

function Start-TaskProcess($taskFile) {
    $taskId = [System.IO.Path]::GetFileNameWithoutExtension($taskFile.Name)
    $outFile = Join-Path $ResultsDir "$taskId.out"
    $jsonFile = Join-Path $ResultsDir "$taskId.json"
    $errFile = Join-Path $ResultsDir "$taskId.err"

    $argsList = [System.Collections.Generic.List[string]]::new()
    $argsList.Add("-NoProfile")
    $argsList.Add("-ExecutionPolicy")
    $argsList.Add("Bypass")
    $argsList.Add("-File")
    $argsList.Add($subScript)
    $argsList.Add("-n")
    $argsList.Add($taskId)
    $argsList.Add("-f")
    $argsList.Add(($taskFile.FullName))
    $argsList.Add("-d")
    $argsList.Add($WorkDir)
    $argsList.Add("-t")
    $argsList.Add("$Timeout")
    $argsList.Add("-o")
    $argsList.Add($jsonFile)

    if ($ReadOnly) { $argsList.Add("-R") }
    if ($Worktree) { $argsList.Add("-W") }
    if ($Carry)    { $argsList.Add("-C") }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = ($argsList | ForEach-Object { Format-Arg $_ }) -join " "
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)

    $outStream = [System.IO.File]::Open($outFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $errStream = [System.IO.File]::Open($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)

    $outTask = [System.Threading.Tasks.Task]::Run([System.Action]{
        try { $proc.StandardOutput.BaseStream.CopyTo($outStream) } finally { $outStream.Dispose() }
    })
    $errTask = [System.Threading.Tasks.Task]::Run([System.Action]{
        try { $proc.StandardError.BaseStream.CopyTo($errStream) } finally { $errStream.Dispose() }
    })

    return @{
        Id = $taskId
        Process = $proc
        OutFile = $outFile
        JsonFile = $jsonFile
        ErrFile = $errFile
        OutTask = $outTask
        ErrTask = $errTask
    }
}

# Vòng lặp điều phối worker pool
while ($pendingQueue.Count -gt 0 -or $runningSlots.Count -gt 0) {
    while ($runningSlots.Count -lt $Jobs -and $pendingQueue.Count -gt 0) {
        $nextFile = $pendingQueue.Dequeue()
        $slot = Start-TaskProcess $nextFile
        $runningSlots.Add($slot)
    }

    Start-Sleep -Milliseconds 500

    for ($i = $runningSlots.Count - 1; $i -ge 0; $i--) {
        $slot = $runningSlots[$i]
        $proc = $slot.Process
        if ($proc.HasExited) {
            [System.Threading.Tasks.Task]::WaitAll(@($slot.OutTask, $slot.ErrTask), 2000) | Out-Null
            $rc = $proc.ExitCode

            $taskId = $slot.Id
            $jsonFile = $slot.JsonFile
            $outFile = $slot.OutFile

            $status = "FAILED(rc=$rc)"
            $jobId = "-"
            $tokens = "-"
            $seconds = "-"
            $branch = "-"

            if (Test-Path $outFile) {
                $outLines = [System.IO.File]::ReadAllLines($outFile)
                foreach ($ol in $outLines) {
                    if ($ol.StartsWith("JOB=")) { $jobId = $ol.Substring(4).Trim() }
                    if ($ol.StartsWith("BRANCH=")) { $branch = $ol.Substring(7).Trim() }
                }
            }

            if (Test-Path $jsonFile) {
                try {
                    $jObj = Get-Content $jsonFile -Raw | ConvertFrom-Json
                    if ($jObj.status) { $status = $jObj.status }
                    if ($jObj.usage -and $jObj.usage.total_tokens) { $tokens = "$($jObj.usage.total_tokens)" }
                    if ($jObj.duration_seconds) { $seconds = "$([Math]::Floor($jObj.duration_seconds))" }
                } catch {}
            }

            $completedResults.Add(@{
                Id = $taskId
                Status = $status
                Job = $jobId
                Tokens = $tokens
                Seconds = $seconds
                Branch = $branch
            })

            $runningSlots.RemoveAt($i)
        }
    }
}

# Ghi SUMMARY.tsv theo thứ tự Id
$sortedResults = $completedResults | Sort-Object { $_.Id }
$tsvLines = [System.Collections.Generic.List[string]]::new()
foreach ($r in $sortedResults) {
    $tsvLines.Add("$($r.Id)`t$($r.Status)`t$($r.Job)`t$($r.Tokens)`t$($r.Seconds)`t$($r.Branch)")
}
[System.IO.File]::WriteAllLines($summaryFile, $tsvLines, [System.Text.Encoding]::UTF8)

# In bảng tổng hợp
Write-Output ("{0,-20} {1,-12} {2,-25} {3,-10} {4,-10} {5}" -f "ID", "STATUS", "JOB", "TOKENS", "SECONDS", "BRANCH")
Write-Output ("-" * 85)
$hasFailure = $false
foreach ($r in $sortedResults) {
    if ($r.Status -ne "SUCCESS") { $hasFailure = $true }
    Write-Output ("{0,-20} {1,-12} {2,-25} {3,-10} {4,-10} {5}" -f $r.Id, $r.Status, $r.Job, $r.Tokens, $r.Seconds, $r.Branch)
}

if ($hasFailure) {
    exit 1
}
exit 0
