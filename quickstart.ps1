<#
.SYNOPSIS
  quickstart.ps1 — Windows Clone 后一键装齐依赖 + 打开交互式上号/无损换 IP/防封自检入口
#>
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RepoDir = $PSScriptRoot
$InstallPs1 = Join-Path $RepoDir "install.ps1"
$BinDst = Join-Path $env:USERPROFILE ".local\bin"
$env:Path = "$BinDst;$env:Path"

$FirstArg = if ($args.Count -gt 0) { [string]$args[0] } else { "" }
$RestArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch ($FirstArg.ToLowerInvariant()) {
    { $_ -in @("set-ip", "change-ip", "rotate-ip", "set-proxy", "update-proxy", "huan-ip") } {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & (Join-Path $BinDst "cc-switch.cmd") set-ip @RestArgs
        exit $LASTEXITCODE
    }
    "add" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if ($RestArgs.Count -eq 0) {
            & (Join-Path $BinDst "cc-switch.cmd") add -
        } else {
            & (Join-Path $BinDst "cc-switch.cmd") add @RestArgs
        }
        exit $LASTEXITCODE
    }
    "chrome" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & (Join-Path $BinDst "cc-chrome.cmd") @RestArgs
        exit $LASTEXITCODE
    }
    "desktop" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & (Join-Path $BinDst "cc-desktop.cmd") @RestArgs
        exit $LASTEXITCODE
    }
    "audit" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & (Join-Path $BinDst "cc-audit.cmd") @RestArgs
        exit $LASTEXITCODE
    }
    { $_ -in @("status", "doctor", "kill", "usage", "reset", "init") } {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & (Join-Path $BinDst "cc-switch.cmd") $FirstArg @RestArgs
        exit $LASTEXITCODE
    }
    "wsl" {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 -WSL -QuickStart
        exit $LASTEXITCODE
    }
    { $_ -in @("-h", "--help", "help", "/?") } {
        Write-Host @"
🚀 cc-safe Windows Quick Start 一键快速开始 (支持双击 quickstart.cmd 或命令行运行)

用法:
  .\quickstart.cmd                              一键安装全部依赖 + 打开交互式向导 (添加账号 / 无损换 IP / 切号 / 自检)
  .\quickstart.cmd set-ip [账号] [新代理|-]     一键无损更换已有账号的静态住宅 IP (保留设备指纹与登录态免重登！)
  .\quickstart.cmd add [- | '账号串'] [别名]    安全隐藏输入添加并激活新账号
  .\quickstart.cmd chrome [账号]                打开该账号专属同源美国 IP 隔离浏览器 (远程 DNS + 禁 QUIC)
  .\quickstart.cmd status                       查看所有账号状态、出口 IP 与 2FA 动态验证码
  .\quickstart.cmd audit                        运行防泄漏与防关联实测审计
  .\quickstart.cmd wsl                          一键将 cc-safe 部署进 WSL2 Linux 子系统
"@
        exit 0
    }
}

if ($args.Count -gt 0) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 @args
    exit $LASTEXITCODE
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 -QuickStart
exit $LASTEXITCODE
