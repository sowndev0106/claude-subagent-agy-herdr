# Kiểm cú pháp mọi file .ps1 của bộ agy (chạy được bằng pwsh trên Linux/macOS hoặc PowerShell trên Windows)
#   pwsh -NoProfile -File agy-setup/tests/ps-parse.ps1
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path; $bad = 0
foreach ($f in Get-ChildItem $repo -Recurse -Filter *.ps1) {
  $t = $null; $e = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
  $b = [System.IO.File]::ReadAllBytes($f.FullName)
  $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  $nonAscii = @($b | Where-Object { $_ -gt 127 }).Count
  if ($e.Count) { Write-Host "FAIL $($f.Name): $($e[0].Message) (dòng $($e[0].Extent.StartLineNumber))"; $bad++ }
  elseif ($nonAscii -and -not $bom) { Write-Host "FAIL $($f.Name): có ký tự ngoài ASCII mà không có BOM UTF-8 (Windows PowerShell 5.1 sẽ đọc sai)"; $bad++ }
  else { Write-Host "PASS $($f.Name)" }
}
exit $bad
