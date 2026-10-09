<#
setup.ps1: kiểm tra, cài đặt và tự sửa bộ agy trên Windows (Windows PowerShell 5.1 hoặc PowerShell 7).

  .\setup.ps1 check          chỉ kiểm: in [OK]/[THIẾU] kèm cách sửa; thoát 1 nếu thiếu thứ bắt buộc
  .\setup.ps1 fix [-Yes]     cài thứ còn thiếu rồi kiểm lại:
                               - agy:   script chính thức (irm https://antigravity.google/cli/install.ps1 | iex)
                               - herdr: script chính thức (irm https://herdr.dev/install.ps1 | iex)
                               - git, jq, python: winget
                               - skill vào %USERPROFILE%\.claude\skills (junction, không cần quyền admin)
                               - thư mục script (agy-sub/agy-ctl/agy-fan/agy-id .cmd) vào PATH của user
                               - có WSL: chạy luôn setup.sh fix -y bên trong WSL (bản đầy đủ: agy-hd, agy-p, lịch tick)
  -Yes                       không hỏi.

Trên Windows thuần chỉ có các runner chạy không giao diện (agy-sub, agy-ctl, agy-fan, agy-id bản .ps1/.cmd).
agy-hd (herdr) và agy-p (nhiều account) là script bash: dùng trong WSL.
#>
param(
  [ValidateSet('check', 'fix', 'help')][string]$Mode = 'check',
  [switch]$Yes
)
$ErrorActionPreference = 'Continue'
if ($Mode -eq 'help') { Get-Help $PSCommandPath -Full | Out-String | Write-Host; exit 0 }

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SkillsDir = if ($env:CLAUDE_SKILLS_DIR) { $env:CLAUDE_SKILLS_DIR } else { Join-Path $env:USERPROFILE '.claude\skills' }
$Skills = 'agy-subagent', 'agy-parallel', 'agy-review', 'claude-task-id', 'agy-accounts', 'agy-login', 'agy-quota', 'agy-switch', 'agy-setup'
$ScriptDirs = @((Join-Path $Repo 'agy-subagent\scripts'), (Join-Path $Repo 'claude-task-id\scripts'))
$script:Bad = 0; $script:Warn = 0

function Ok($m)   { Write-Host "  [OK]    $m" }
function No($m)   { Write-Host "  [THIẾU] $m"; $script:Bad++ }
function Hmm($m)  { Write-Host "  [!]     $m"; $script:Warn++ }
function Has($c)  { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Ask($q)  { if ($Yes) { return $true }; $r = Read-Host "$q [y/N]"; return ($r -eq 'y' -or $r -eq 'Y') }
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  $agyBin = Join-Path $env:LOCALAPPDATA 'agy\bin'
  if ((Test-Path $agyBin) -and ($env:Path -notlike "*$agyBin*")) { $env:Path += ";$agyBin" }
}
function Wsl-Distro {
  if (-not (Has 'wsl.exe')) { return $null }
  $raw = (& wsl.exe -l -q 2>$null) -join "`n"
  $list = ($raw -replace "`0", '').Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^docker-desktop' }
  if ($list) { return $list[0] } else { return $null }
}
function Junction-Ok($link, $target) {
  if (-not (Test-Path $link)) { return $false }
  $item = Get-Item $link -Force
  return ($item.LinkType -in 'Junction', 'SymbolicLink') -and ((@($item.Target)[0]) -eq $target)
}

function Run-Checks {
  $script:Bad = 0; $script:Warn = 0
  Write-Host "công cụ"
  foreach ($c in 'git', 'jq') { if (Has $c) { Ok $c } else { No "$c (winget)" } }
  if ((Has 'python') -or (Has 'py')) { Ok 'python' } else { No 'python (winget)' }
  if (Has 'winget') { Ok 'winget' } else { Hmm 'winget chưa có (cài "App Installer" từ Microsoft Store) - không tự cài được git/jq/python' }
  Write-Host "ứng dụng"
  if (Has 'agy') { Ok "agy $((& agy --version 2>$null | Select-Object -First 1))" } else { No 'agy (Antigravity CLI)' }
  if (Has 'herdr') { Ok "herdr $((& herdr --version 2>$null | Select-Object -First 1))" } else { No 'herdr' }
  Write-Host "skill + PATH"
  $miss = @($Skills | Where-Object { (Test-Path (Join-Path $Repo $_)) -and -not (Junction-Ok (Join-Path $SkillsDir $_) (Join-Path $Repo $_)) })
  if ($miss.Count -eq 0) { Ok "skill đã liên kết vào $SkillsDir" } else { No "$($miss.Count) skill chưa liên kết vào $SkillsDir" }
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $pmiss = @($ScriptDirs | Where-Object { $userPath -notlike "*$_*" })
  if ($pmiss.Count -eq 0) { Ok 'thư mục script đã trong PATH (agy-sub, agy-ctl, agy-fan, agy-id)' } else { No "$($pmiss.Count) thư mục script chưa trong PATH" }
  Write-Host "WSL (bản đầy đủ: agy-hd, agy-p, lịch tick)"
  $d = Wsl-Distro
  if ($d) { Ok "WSL có distro '$d' (setup.ps1 fix sẽ chạy setup.sh trong đó)" } else { Hmm 'chưa có WSL: chỉ dùng được runner không giao diện. Cài: wsl --install' }
}

function Fix-All {
  Write-Host "== sửa"
  if (Has 'winget') {
    $pk = @{ 'git' = 'Git.Git'; 'jq' = 'jqlang.jq' }
    foreach ($c in $pk.Keys) { if (-not (Has $c)) { Write-Host "  cài $c"; winget install --id $pk[$c] -e --silent --accept-package-agreements --accept-source-agreements | Out-Null } }
    if (-not ((Has 'python') -or (Has 'py'))) { Write-Host '  cài python'; winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
    Refresh-Path
  }
  if (-not (Has 'agy')) { Write-Host '  cài agy'; Invoke-RestMethod https://antigravity.google/cli/install.ps1 | Invoke-Expression; Refresh-Path }
  if (-not (Has 'herdr')) { Write-Host '  cài herdr'; Invoke-RestMethod https://herdr.dev/install.ps1 | Invoke-Expression; Refresh-Path }
  New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
  foreach ($s in $Skills) {
    $target = Join-Path $Repo $s; $link = Join-Path $SkillsDir $s
    if (-not (Test-Path $target)) { continue }
    if (Junction-Ok $link $target) { continue }
    if (Test-Path $link) { (Get-Item $link -Force).Delete() }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
  }
  Write-Host "  đã liên kết skill vào $SkillsDir"
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User'); $changed = $false
  foreach ($p in $ScriptDirs) { if ($userPath -notlike "*$p*") { $userPath = ($userPath.TrimEnd(';') + ";$p"); $changed = $true } }
  if ($changed) { [Environment]::SetEnvironmentVariable('Path', $userPath, 'User'); Refresh-Path; Write-Host '  đã thêm thư mục script vào PATH của user (mở terminal mới để áp dụng)' }
  $d = Wsl-Distro
  if ($d -and (Ask "Chạy setup.sh fix trong WSL '$d' (cài bản đầy đủ: agy-hd, agy-p, herdr, agy, lịch tick)?")) {
    $wslRepo = (& wsl.exe -d $d -- wslpath -a ($Repo -replace '\\', '/')) -join ''
    & wsl.exe -d $d -- bash -lc "'$wslRepo/agy-setup/scripts/setup.sh' fix -y"
  }
}

Write-Host "== Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion), repo: $Repo"
Run-Checks
if ($Mode -eq 'fix') { Fix-All; Write-Host '== kiểm lại'; Run-Checks }
Write-Host '---'
Write-Host "$($script:Bad) thiếu/lỗi, $($script:Warn) cảnh báo"
if ($script:Bad -gt 0) { exit 1 } else { exit 0 }
