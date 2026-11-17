<#
.SYNOPSIS
  uninstall.ps1 — 卸载 Windows 版 cc-safe 命令、停止 Gost 隧道、移除计划任务并还原 PowerShell $PROFILE (默认保留 ~/.claude-safe 账号数据，加 -Purge 彻底清除)
#>
param(
    [switch]$Purge
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$UserHome = $env:USERPROFILE
$BinDst   = Join-Path $UserHome ".local\bin"
$SafeDir  = Join-Path $UserHome ".claude-safe"

if (Test-Path -LiteralPath (Join-Path $BinDst "cc-switch.cmd")) {
    & (Join-Path $BinDst "cc-switch.cmd") kill-local 2>$null | Out-Null
}
if (Test-Path -LiteralPath (Join-Path $BinDst "cc-us-tunnel.cmd")) {
    & (Join-Path $BinDst "cc-us-tunnel.cmd") stop 2>$null | Out-Null
}

try {
    Unregister-ScheduledTask -TaskName "cc-safe-tunnel-guard" -Confirm:$false -ErrorAction SilentlyContinue
} catch {}

foreach ($cmd in @("cc-switch.cmd", "cc-safe.cmd", "cc-us-tunnel.cmd", "cc-check-ip.cmd", "cc-totp.cmd", "cc-audit.cmd", "claude-sub2api.cmd", "cc-chrome.cmd")) {
    $p = Join-Path $BinDst $cmd
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

if ($PROFILE -and (Test-Path -LiteralPath $PROFILE)) {
    try {
        [string[]]$lines = @(Get-Content -LiteralPath $PROFILE -ErrorAction SilentlyContinue)
        [string[]]$filtered = @(
            $lines | Where-Object {
                ($_ -notmatch "^# cc-safe bare-claude guard") -and ($_ -notmatch 'function\s+claude\s*\{.*cc-safe\.cmd')
            }
        )
        [System.IO.File]::WriteAllLines($PROFILE, $filtered, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

if ($Purge) {
    $GostExe = Join-Path $BinDst "gost.exe"
    if (Test-Path -LiteralPath $GostExe) {
        Remove-Item -LiteralPath $GostExe -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $SafeDir) {
        Remove-Item -LiteralPath $SafeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $RemFiles = @(Get-ChildItem -LiteralPath $BinDst -ErrorAction SilentlyContinue)
    if ($RemFiles.Count -eq 0) {
        try {
            $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($UserPath) {
                $NormBin = $BinDst.TrimEnd('\')
                $Kept = @($UserPath -split ";" | Where-Object { $_ -ne "" -and ($_.TrimEnd('\') -ine $NormBin) })
                [Environment]::SetEnvironmentVariable("Path", ($Kept -join ";"), "User")
            }
        } catch {}
    }
    Write-Host "🗑️  已卸载 Windows 版 cc-safe、还原 PowerShell 别名并彻底清除 $SafeDir。" -ForegroundColor Yellow
} else {
    Write-Host "✅ 已卸载 Windows 版 cc-safe 命令与计划任务（账号档案保留于 $SafeDir，彻底删除请运行 '.\uninstall.ps1 -Purge'）。" -ForegroundColor Green
}
