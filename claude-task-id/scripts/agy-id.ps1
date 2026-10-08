#Requires -Version 5.1
<#
.SYNOPSIS
    agy-id: cấp số 3 chữ số + tên cho phiên Claude Code trên Windows.
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = "",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList = @()
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$idDir = if ($env:AGY_ID_DIR) { $env:AGY_ID_DIR } else { Join-Path $HOME ".cache\agy-ids" }
if (-not (Test-Path $idDir)) { [System.IO.Directory]::CreateDirectory($idDir) | Out-Null }
$mapFile = Join-Path $idDir "map.tsv"
$cntFile = Join-Path $idDir "counter"
$days = if ($env:AGY_ID_ACTIVE_DAYS) { [int]$env:AGY_ID_ACTIVE_DAYS } else { 14 }
if (-not (Test-Path $mapFile)) { [System.IO.File]::WriteAllText($mapFile, "") }

function Get-Key {
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_SESSION_ID)) {
        return $env:CLAUDE_CODE_SESSION_ID
    }
    return "manual"
}

function Clean-Title([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return "" }
    $t = ($raw -replace "[\t\r\n]", " ") -replace "\s+", " "
    $t = $t.Trim()
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60) }
    return $t
}

function Alloc-Num {
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cutoff = $nowSec - ($days * 86400)
    $c = 99
    if (Test-Path $cntFile) {
        $rawC = Get-Content $cntFile -Raw -ErrorAction SilentlyContinue
        [int]::TryParse($rawC.Trim(), [ref]$c) | Out-Null
    }

    $used = [System.Collections.Generic.HashSet[int]]::new()
    if (Test-Path $mapFile) {
        $lines = [System.IO.File]::ReadAllLines($mapFile)
        foreach ($l in $lines) {
            $parts = $l -split "`t"
            if ($parts.Length -ge 4) {
                $epoch = 0
                [int64]::TryParse($parts[3], [ref]$epoch) | Out-Null
                if ($epoch -ge $cutoff) {
                    $uNum = 0
                    if ([int]::TryParse($parts[1], [ref]$uNum)) {
                        $used.Add($uNum) | Out-Null
                    }
                }
            }
        }
    }

    for ($i = 0; $i -lt 900; $i++) {
        $c++
        if ($c -gt 999) { $c = 100 }
        if (-not $used.Contains($c)) { break }
    }
    [System.IO.File]::WriteAllText($cntFile, "$c")
    return $c
}

function Read-Rows {
    $dict = @{}
    if (Test-Path $mapFile) {
        $lines = [System.IO.File]::ReadAllLines($mapFile)
        foreach ($l in $lines) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $parts = $l -split "`t"
            if ($parts.Length -ge 4) {
                $dict[$parts[0]] = @{
                    Num = $parts[1]
                    Title = $parts[2]
                    Epoch = $parts[3]
                }
            }
        }
    }
    return $dict
}

function Write-Rows($dict) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $dict.Keys) {
        $v = $dict[$k]
        $lines.Add("$k`t$($v.Num)`t$($v.Title)`t$($v.Epoch)")
    }
    [System.IO.File]::WriteAllLines($mapFile, $lines, [System.Text.Encoding]::UTF8)
}

$k = Get-Key
$rows = Read-Rows
$argTitle = Clean-Title ($ArgsList -join " ")

switch ($Command.ToLower()) {
    "claim" {
        $existing = $rows[$k]
        $num = ""
        $title = $argTitle
        if ($existing) {
            $num = $existing.Num
            if ([string]::IsNullOrWhiteSpace($title)) { $title = $existing.Title }
        } else {
            $num = Alloc-Num
        }
        $rows[$k] = @{ Num = $num; Title = $title; Epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        Write-Rows $rows
        if ($title) { Write-Output "#$num $title" } else { Write-Output "#$num" }
    }
    "rename" {
        $existing = $rows[$k]
        if ([string]::IsNullOrWhiteSpace($argTitle)) {
            [Console]::Error.WriteLine("agy-id: rename cần tên mới")
            exit 2
        }
        $num = if ($existing) { $existing.Num } else { Alloc-Num }
        $rows[$k] = @{ Num = $num; Title = $argTitle; Epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        Write-Rows $rows
        Write-Output "#$num $argTitle"
    }
    "label" {
        $existing = $rows[$k]
        $num = ""
        $title = ""
        if ($existing) {
            $num = $existing.Num
            $title = if ($existing.Title) { $existing.Title } else { $argTitle }
        } else {
            $num = Alloc-Num
            $title = $argTitle
        }
        $rows[$k] = @{ Num = $num; Title = $title; Epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        Write-Rows $rows
        if ($title) { Write-Output "#$num $title" } else { Write-Output "#$num" }
    }
    "show" {
        $existing = $rows[$k]
        if (-not $existing) {
            [Console]::Error.WriteLine("agy-id: phiên này chưa có số (agy-id claim `"tên`")")
            exit 1
        }
        if ($existing.Title) { Write-Output "#$($existing.Num) $($existing.Title)" } else { Write-Output "#$($existing.Num)" }
    }
    "num" {
        $existing = $rows[$k]
        if ($existing) { Write-Output $existing.Num }
    }
    "list" {
        $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Write-Output ("{0,-5} {1,-44} {2,-10} {3}" -f "SỐ", "TÊN", "PHIÊN", "TUỔI")
        foreach ($key in $rows.Keys) {
            $v = $rows[$key]
            $ep = 0
            [int64]::TryParse($v.Epoch, [ref]$ep) | Out-Null
            $ageH = [Math]::Floor(($nowSec - $ep) / 3600)
            $sessShort = if ($key.Length -gt 8) { $key.Substring(0, 8) } else { $key }
            Write-Output ("{0,-5} {1,-44} {2,-10} {3}h" -f "#$($v.Num)", $v.Title, $sessShort, $ageH)
        }
    }
    "release" {
        if ($rows.ContainsKey($k)) {
            $rows.Remove($k)
            Write-Rows $rows
            $sessShort = if ($k.Length -gt 8) { $k.Substring(0, 8) } else { $k }
            Write-Output "đã trả số của phiên $sessShort"
        }
    }
    default {
        @"
Usage:
  agy-id claim ["tên nhiệm vụ"]
  agy-id show
  agy-id label [tên mặc định]
  agy-id num
  agy-id rename "tên mới"
  agy-id list
  agy-id release
"@
        exit 2
    }
}
