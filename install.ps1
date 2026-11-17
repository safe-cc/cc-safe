<#
.SYNOPSIS
  install.ps1 — cc-safe Windows 10/11 全自动一键部署脚本 (免管理员权限、自动装齐 Python/Gost/Claude、NTFS 权限硬隔离、无损换 IP)

.EXAMPLE
  # 方式 1: Clone 后本地一键部署并进入交互菜单
  .\quickstart.cmd

  # 方式 2: PowerShell 远程单行一键直装
  irm https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.ps1 | iex

  # 方式 3: 若偏好在 WSL2 Linux 子系统内运行 (启用 ELF proxychains4)
  .\install.ps1 -WSL
#>
param(
    [switch]$QuickStart,
    [string]$Add = "",
    [string]$Alias = "",
    [switch]$SetIp,
    [string]$Account = "",
    [string]$Proxy = "",
    [switch]$Force,
    [switch]$UpgradeDeps,
    [switch]$SkipClaude,
    [switch]$NoTask,
    [switch]$NoAlias,
    [switch]$WSL,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$RepoZipUrl = if ($env:CC_SAFE_ZIP_URL) { $env:CC_SAFE_ZIP_URL } else { "https://github.com/safe-cc/cc-safe/archive/refs/heads/main.zip" }
$RepoGitUrl = if ($env:CC_SAFE_REPO_URL) { $env:CC_SAFE_REPO_URL } else { "https://github.com/safe-cc/cc-safe.git" }
$GostFallbackVer = "3.3.3"
$PyNugetVer = "3.12.8"

if ($Help) {
    Write-Host @"
用法:
  .\quickstart.cmd                                  # 双击或命令行运行: 一键安装 + 打开交互式上号/换 IP 向导
  .\install.ps1 [参数]
  irm https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.ps1 | iex

参数:
  -QuickStart                         部署完成后立即启动交互式管理向导 (添加账号 / 无损换 IP / 切号 / 审计)
  -Add '<账号串|->' [-Alias acc1]     部署完成后立即体检并激活新账号 ('-' 表示隐藏输入防历史留痕)
  -SetIp [-Account acc1] [-Proxy -]   部署完成后立即为指定账号无损换 IP (保留设备指纹与登录态免重登)
  -Force                              配合 -Add / -SetIp 跳过同子网或纯净度强拦截
  -WSL                                将 cc-safe 一键自动部署进默认 WSL2 Linux 发行版
  -UpgradeDeps                        强制重新下载更新 gost.exe
  -SkipClaude                         若未安装 Claude Code CLI，跳过自动安装
  -NoTask                             不注册 Windows 计划任务后台隧道自愈守护
  -NoAlias                            不在 PowerShell `$PROFILE 中注册 'claude -> cc-safe' 防裸奔保护
"@
    exit 0
}

function Lock-DirectoryAcl([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) {
        New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
    }
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = & icacls.exe $DirPath /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*${sid}:(OI)(CI)F" 2>$null
    } catch {
        # 非 NTFS 文件系统忽略
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

# ---------------------------------------------------------------------------
# 0. 若通过 `irm .../install.ps1 | iex` 远程无文件调用，先自举拉取仓库至 ~/.claude-safe/repo
# ---------------------------------------------------------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { "" }
if ([string]::IsNullOrWhiteSpace($ScriptDir) -or -not (Test-Path -LiteralPath (Join-Path $ScriptDir "bin\cc-switch"))) {
    $SafeBase = Join-Path $env:USERPROFILE ".claude-safe"
    Lock-DirectoryAcl $SafeBase
    $BootDir = Join-Path $SafeBase "repo"
    Write-Host "📦 [Bootstrap] 正在拉取 safe-cc/cc-safe 仓库至 $BootDir ..." -ForegroundColor Cyan
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        if (Test-Path -LiteralPath (Join-Path $BootDir ".git")) {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & git.exe -C $BootDir remote set-url origin $RepoGitUrl 2>$null
            $ErrorActionPreference = $oldEap
            & git.exe -C $BootDir fetch --depth 1 origin main -q
            if ($LASTEXITCODE -ne 0) { Write-Error "❌ 拉取仓库更新失败 (git fetch)"; exit 1 }
            & git.exe -C $BootDir reset --hard FETCH_HEAD -q
            if ($LASTEXITCODE -ne 0) { Write-Error "❌ 重置仓库工作区失败 (git reset)"; exit 1 }
        } else {
            if (Test-Path -LiteralPath $BootDir) { Remove-Item -LiteralPath $BootDir -Recurse -Force }
            & git.exe clone --depth 1 -q $RepoGitUrl $BootDir
            if ($LASTEXITCODE -ne 0) { Write-Error "❌ 克隆 safe-cc/cc-safe 仓库失败"; exit 1 }
        }
    } else {
        $TmpZip = Join-Path $SafeBase "repo_bootstrap.zip"
        $TmpExt = Join-Path $SafeBase "repo_extract_tmp"
        if (Test-Path -LiteralPath $TmpExt) { Remove-Item -LiteralPath $TmpExt -Recurse -Force }
        $BootCurl = Join-Path $env:SystemRoot "System32\curl.exe"
        if (Test-Path -LiteralPath $BootCurl) {
            & $BootCurl --ssl-no-revoke --connect-timeout 15 --max-time 120 --retry 2 -fSL $RepoZipUrl -o $TmpZip
            if ($LASTEXITCODE -ne 0) { Write-Error "❌ 下载 safe-cc/cc-safe 源码包失败 (curl 退出码: $LASTEXITCODE)"; exit 1 }
        } else {
            Invoke-WebRequest -Uri $RepoZipUrl -OutFile $TmpZip -UseBasicParsing
        }
        Expand-Archive -LiteralPath $TmpZip -DestinationPath $TmpExt -Force
        Remove-Item -LiteralPath $TmpZip -Force -ErrorAction SilentlyContinue
        $Inner = Get-ChildItem -LiteralPath $TmpExt -Directory | Select-Object -First 1
        if (Test-Path -LiteralPath $BootDir) { Remove-Item -LiteralPath $BootDir -Recurse -Force }
        Move-Item -LiteralPath $Inner.FullName -Destination $BootDir
        Remove-Item -LiteralPath $TmpExt -Recurse -Force -ErrorAction SilentlyContinue
    }
    $ForwardArgs = @{}
    if ($QuickStart) { $ForwardArgs["QuickStart"] = $true }
    if ($Add)        { $ForwardArgs["Add"] = $Add }
    if ($Alias)      { $ForwardArgs["Alias"] = $Alias }
    if ($SetIp)      { $ForwardArgs["SetIp"] = $true }
    if ($Account)    { $ForwardArgs["Account"] = $Account }
    if ($Proxy)      { $ForwardArgs["Proxy"] = $Proxy }
    if ($Force)      { $ForwardArgs["Force"] = $true }
    if ($UpgradeDeps){ $ForwardArgs["UpgradeDeps"] = $true }
    if ($SkipClaude) { $ForwardArgs["SkipClaude"] = $true }
    if ($NoTask)     { $ForwardArgs["NoTask"] = $true }
    if ($NoAlias)    { $ForwardArgs["NoAlias"] = $true }
    if ($WSL)        { $ForwardArgs["WSL"] = $true }
    & (Join-Path $BootDir "install.ps1") @ForwardArgs
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# 0.5 可选 WSL2 桥接部署模式 (-WSL)
# ---------------------------------------------------------------------------
if ($WSL) {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Error "❌ 当前系统未启用 WSL2。您可以直接运行无参数的 '.\install.ps1' 使用原生 Windows 模式，或先运行 'wsl --install'。"
        exit 1
    }
    Write-Host "🐧 [WSL2 模式] 正在将 cc-safe 一键同步部署至默认 WSL2 Linux 子系统..." -ForegroundColor Cyan
    $WslFlag = if ($QuickStart) { "--quickstart" } else { "" }
    $PrevWslEnv = $env:WSLENV
    try {
        $env:CC_WIN_SRC = $ScriptDir
        $env:CC_WSL_FLAG = $WslFlag
        $env:WSLENV = if ($PrevWslEnv) { "$PrevWslEnv:CC_WIN_SRC/p:CC_WSL_FLAG/u" } else { "CC_WIN_SRC/p:CC_WSL_FLAG/u" }
        & wsl.exe bash -lc 'mkdir -p -m 700 ~/.claude-safe/repo && cp -r "$CC_WIN_SRC"/. ~/.claude-safe/repo/ && chmod +x ~/.claude-safe/repo/install.sh ~/.claude-safe/repo/quickstart.sh ~/.claude-safe/repo/bin/* && bash ~/.claude-safe/repo/install.sh ${CC_WSL_FLAG:+"$CC_WSL_FLAG"}'
        exit $LASTEXITCODE
    } finally {
        $env:WSLENV = $PrevWslEnv
        Remove-Item Env:\CC_WIN_SRC -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_WSL_FLAG -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 1. 原生 Windows 架构检查与隔离目录 ACL 加固 (等效 Linux chmod 700)
# ---------------------------------------------------------------------------
$RawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($RawArch) {
    "AMD64|x86_64" { $ArchTag = "amd64"; $NugetPkg = "python" }
    "ARM64"        { $ArchTag = "arm64"; $NugetPkg = "pythonarm64" }
    default {
        Write-Error "❌ 不支持的 Windows CPU 架构: $RawArch (仅支持 x64 / ARM64)"
        exit 1
    }
}

$UserHome  = $env:USERPROFILE
$BinDst    = Join-Path $UserHome ".local\bin"
$SafeDir   = Join-Path $UserHome ".claude-safe"
$CfgDir    = Join-Path $SafeDir  "config"
$LockDir   = Join-Path $SafeDir  "locks"
$LogDir    = Join-Path $SafeDir  "logs"
$ProfDir   = Join-Path $SafeDir  "profiles"
$LibExec   = Join-Path $SafeDir  "libexec"
$PyLibExec = Join-Path $LibExec  "py"
$RuntimeDir= Join-Path $SafeDir  "runtime"
$ClaudeRelayDir = Join-Path $UserHome ".claude"

New-Item -ItemType Directory -Path $BinDst -Force | Out-Null
foreach ($sd in @($SafeDir, $CfgDir, $LockDir, $LogDir, $ProfDir, $LibExec, $PyLibExec, $RuntimeDir, $ClaudeRelayDir)) {
    Lock-DirectoryAcl $sd
}

$SysCurl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path -LiteralPath $SysCurl)) {
    Write-Error "❌ 未找到 $SysCurl (需要 Windows 10 1803+ 或 Windows 11)。"
    exit 1
}
# Windows System32\curl.exe 使用 Schannel，在国内/内网直连海外 OCSP 吊销服务器离线时会硬报错 (exit 35: 0x80092013)
# --ssl-no-revoke 保留完整 TLS 证书链、CA 根与域名校验，仅关闭旁路 OCSP/CRL 直连阻塞
$CurlWinArgs = @("--ssl-no-revoke", "--retry", "2", "--connect-timeout", "15", "-fSL")

# ---------------------------------------------------------------------------
# 2. 免管理员权限解析 / 自动部署独立 Python 3.12 运行时
# ---------------------------------------------------------------------------
function Find-WorkingPython {
    $PortablePy = Join-Path $RuntimeDir "python\tools\python.exe"
    $Candidates = @($PortablePy)
    foreach ($cmdName in @("python.exe", "python3.exe")) {
        $found = Get-Command $cmdName -All -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            if ($f.Source -and ($f.Source -notmatch "WindowsApps")) {
                $Candidates += $f.Source
            }
        }
    }
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $py3Path = ((& py.exe -3 -c "import sys; print(sys.executable)" 2>$null) | Out-String).Trim()
            if ($py3Path -and (Test-Path -LiteralPath $py3Path)) { $Candidates += $py3Path }
        } catch {} finally { $ErrorActionPreference = $oldEap }
    }
    foreach ($cand in ($Candidates | Select-Object -Unique)) {
        if (-not $cand -or -not (Test-Path -LiteralPath $cand)) { continue }
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $verCheck = ((& $cand -c "import sys, ssl, ctypes, sqlite3; print(sys.executable if sys.version_info >= (3, 9) else '')" 2>$null) | Out-String).Trim()
            if ($verCheck -and (Test-Path -LiteralPath $verCheck)) {
                return $verCheck
            }
        } catch {} finally { $ErrorActionPreference = $oldEap }
    }
    return ""
}

$PythonExe = Find-WorkingPython
if (-not $PythonExe) {
    Write-Host "⬇️  未检测到系统 Python 3.9+，正在免管理员下载官方独立版 Python $PyNugetVer ($ArchTag)..." -ForegroundColor Cyan
    $PyZip = Join-Path $RuntimeDir "python_nuget.zip"
    $PyDst = Join-Path $RuntimeDir "python"
    if (Test-Path -LiteralPath $PyDst) { Remove-Item -LiteralPath $PyDst -Recurse -Force }
    $NugetUrl = "https://www.nuget.org/api/v2/package/$NugetPkg/$PyNugetVer"
    & $SysCurl @CurlWinArgs $NugetUrl -o $PyZip
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $PyZip)) {
        Write-Host "⚠️  curl 下载 Python 未成功 (exit=$LASTEXITCODE)，切换 PowerShell TLS 通道重试..." -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $NugetUrl -OutFile $PyZip -UseBasicParsing
        } catch {
            Write-Error "❌ 下载独立版 Python 失败，请检查网络连接。"
            exit 1
        }
    }
    Expand-Archive -LiteralPath $PyZip -DestinationPath $PyDst -Force
    Remove-Item -LiteralPath $PyZip -Force -ErrorAction SilentlyContinue
    $PythonExe = Join-Path $PyDst "tools\python.exe"
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        Write-Error "❌ 独立版 Python 解压校验失败，请检查网络或手动安装 Python 3.11+。"
        exit 1
    }
    Write-Host "✅ 独立版 Python 已就绪: $PythonExe" -ForegroundColor Green
}

$PythonDir = Split-Path -Parent $PythonExe
$PythonwCandidate = Join-Path $PythonDir "pythonw.exe"
$PythonwExe = if (Test-Path -LiteralPath $PythonwCandidate) { $PythonwCandidate } else { $PythonExe }

# ---------------------------------------------------------------------------
# 3. 免管理员自动部署 Gost v3 (gost.exe) 与 Claude Code CLI
# ---------------------------------------------------------------------------
$GostExe = Join-Path $BinDst "gost.exe"
$NeedGost = $UpgradeDeps.IsPresent -or (-not (Test-Path -LiteralPath $GostExe))
if (-not $NeedGost) {
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $gv = (& $GostExe -V 2>&1 | Out-String)
        if ($gv -notmatch "gost 3\.") { $NeedGost = $true }
    } catch {
        $NeedGost = $true
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

if ($NeedGost) {
    Write-Host "⬇️  正在下载安装 gost v3 ($ArchTag) -> $GostExe ..." -ForegroundColor Cyan
    $GostUrl = "https://github.com/go-gost/gost/releases/download/v${GostFallbackVer}/gost_${GostFallbackVer}_windows_${ArchTag}.zip"
    $GostDigest = ""
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/go-gost/gost/releases/latest" -Headers @{"User-Agent"="cc-safe-win"} -TimeoutSec 6
        foreach ($asset in $rel.assets) {
            if ($asset.browser_download_url -match "windows_${ArchTag}\.zip$") {
                $GostUrl = $asset.browser_download_url
                if ($asset.PSObject.Properties["digest"] -and $asset.digest) {
                    $GostDigest = [string]$asset.digest
                }
                break
            }
        }
    } catch {}
    $GostZip = Join-Path $RuntimeDir "gost_win.zip"
    $GostTmp = Join-Path $RuntimeDir "gost_tmp"
    if (Test-Path -LiteralPath $GostTmp) { Remove-Item -LiteralPath $GostTmp -Recurse -Force }
    if (Test-Path -LiteralPath $GostZip) { Remove-Item -LiteralPath $GostZip -Force -ErrorAction SilentlyContinue }
    & $SysCurl @CurlWinArgs $GostUrl -o $GostZip
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $GostZip)) {
        Write-Host "⚠️  curl 下载 gost 未成功 (exit=$LASTEXITCODE)，切换 Python/PowerShell TLS 通道重试..." -ForegroundColor Yellow
        $oldEapDl = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $PythonExe -c "import sys, urllib.request; req=urllib.request.Request(sys.argv[1], headers={'User-Agent':'cc-safe-win'}); data=urllib.request.urlopen(req, timeout=60).read(); open(sys.argv[2],'wb').write(data)" $GostUrl $GostZip
        } catch {} finally {
            $ErrorActionPreference = $oldEapDl
        }
        if (-not (Test-Path -LiteralPath $GostZip) -or ((Get-Item -LiteralPath $GostZip).Length -lt 1024)) {
            try {
                Invoke-WebRequest -Uri $GostUrl -OutFile $GostZip -UseBasicParsing
            } catch {
                Write-Error "❌ 下载 gost v3 失败，请检查目标机器到 GitHub Releases 的网络连接。"
                exit 1
            }
        }
    }
    if ($GostDigest -match '^sha256:([0-9a-fA-F]{64})$') {
        $ExpectedHash = $Matches[1]
        $ActualHash = (Get-FileHash -LiteralPath $GostZip -Algorithm SHA256).Hash
        if ($ActualHash -ine $ExpectedHash) {
            Remove-Item -LiteralPath $GostZip -Force -ErrorAction SilentlyContinue
            Write-Error "❌ gost.zip SHA-256 完整性校验未通过 (预期=$ExpectedHash, 实际=$ActualHash)！"
            exit 1
        }
    }
    Expand-Archive -LiteralPath $GostZip -DestinationPath $GostTmp -Force
    $FoundGost = Get-ChildItem -Path $GostTmp -Filter "gost.exe" -Recurse | Select-Object -First 1
    if (-not $FoundGost) {
        Write-Error "❌ gost.zip 中未找到 gost.exe"
        exit 1
    }
    Copy-Item -LiteralPath $FoundGost.FullName -Destination $GostExe -Force
    Remove-Item -LiteralPath $GostZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $GostTmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "✅ gost v3 已安装: $GostExe" -ForegroundColor Green
}

$env:Path = "$BinDst;$env:Path"
$HasClaude = [bool](Get-Command claude.exe -ErrorAction SilentlyContinue) -or [bool](Get-Command claude.cmd -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath (Join-Path $BinDst "claude.exe"))
if (-not $SkipClaude -and -not $HasClaude) {
    Write-Host "⬇️  未检测到 Claude Code CLI，正在尝试自动下载官方 Windows 原生版 ..." -ForegroundColor Cyan
    $ClaudePlat = if ($ArchTag -eq "arm64") { "win32-arm64" } else { "win32-x64" }
    $ClaudeBase = "https://downloads.claude.ai/claude-code-releases"
    $ClaudeProxyArgs = @()
    try {
        if ((New-Object Net.Sockets.TcpClient).ConnectAsync("127.0.0.1", 7890).Wait(300)) {
            $ClaudeProxyArgs = @("--noproxy", "", "-x", "http://127.0.0.1:7890")
        }
    } catch {}
    $oldEapCc = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $CcVer = ((& $SysCurl --ssl-no-revoke -fsSL --max-time 10 @ClaudeProxyArgs "$ClaudeBase/latest" 2>$null) | Out-String).Trim()
        if ($CcVer -match '^\d+\.\d+\.\d+') {
            $CcManifestRaw = ((& $SysCurl --ssl-no-revoke -fsSL --max-time 12 @ClaudeProxyArgs "$ClaudeBase/$CcVer/manifest.json" 2>$null) | Out-String).Trim()
            $CcManifest = $CcManifestRaw | ConvertFrom-Json
            $CcExpectedSha = [string]$CcManifest.platforms.$ClaudePlat.checksum
            if ($CcExpectedSha -match '^[0-9a-fA-F]{64}$') {
                $CcTmpExe = Join-Path $RuntimeDir "claude_download.exe.tmp"
                if (Test-Path -LiteralPath $CcTmpExe) { Remove-Item -LiteralPath $CcTmpExe -Force -ErrorAction SilentlyContinue }
                & $SysCurl --ssl-no-revoke --retry 2 --connect-timeout 15 -fSL @ClaudeProxyArgs "$ClaudeBase/$CcVer/$ClaudePlat/claude.exe" -o $CcTmpExe
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $CcTmpExe)) {
                    $CcActualSha = (Get-FileHash -LiteralPath $CcTmpExe -Algorithm SHA256).Hash
                    if ($CcActualSha -ieq $CcExpectedSha) {
                        Move-Item -LiteralPath $CcTmpExe -Destination (Join-Path $BinDst "claude.exe") -Force
                        Write-Host "✅ Claude Code CLI v$CcVer 已安装并通过 SHA-256 校验: $BinDst\claude.exe" -ForegroundColor Green
                        $HasClaude = $true
                    } else {
                        Remove-Item -LiteralPath $CcTmpExe -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } catch {} finally {
        $ErrorActionPreference = $oldEapCc
    }
    if (-not $HasClaude) {
        Write-Warning "当前直连尚未拉取到 Claude Code CLI（添加美国代理账号后首次运行 cc-safe 将自动通过专线补齐安装）。"
    }
}

# ---------------------------------------------------------------------------
# 4. 部署跨平台核心引擎与 Windows `.cmd` 启动垫片 (UTF-8 无乱码 + 防注入)
# ---------------------------------------------------------------------------
foreach ($pyMod in @("cc-switch", "cc-us-tunnel", "cc-check-ip", "cc-audit")) {
    Copy-Item -LiteralPath (Join-Path $ScriptDir "bin\$pyMod") -Destination (Join-Path $PyLibExec $pyMod) -Force
}
Copy-Item -LiteralPath (Join-Path $ScriptDir "windows\cc_win_launcher.py") -Destination (Join-Path $PyLibExec "cc_win_launcher.py") -Force

function Write-CmdShim([string]$Name, [string]$TargetPy, [string]$ExtraArg = "") {
    $CmdPath = Join-Path $BinDst "$Name.cmd"
    $EscPy = $PythonExe -replace "%", "%%"
    $EscTarget = $TargetPy -replace "%", "%%"
    $Mid = if ($ExtraArg) { " $ExtraArg" } else { "" }
    $Body = @"
@echo off
setlocal DisableDelayedExpansion
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
"$EscPy" "$EscTarget"$Mid %*
exit /b %ERRORLEVEL%
"@
    [System.IO.File]::WriteAllText($CmdPath, ($Body -replace "`r?`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

Write-CmdShim "cc-switch"      (Join-Path $PyLibExec "cc-switch")
Write-CmdShim "cc-us-tunnel"   (Join-Path $PyLibExec "cc-us-tunnel")
Write-CmdShim "cc-check-ip"    (Join-Path $PyLibExec "cc-check-ip")
Write-CmdShim "cc-audit"       (Join-Path $PyLibExec "cc-audit")
Write-CmdShim "cc-safe"        (Join-Path $PyLibExec "cc_win_launcher.py") "safe"
Write-CmdShim "cc-desktop"     (Join-Path $PyLibExec "cc_win_launcher.py") "desktop"
Write-CmdShim "claude-sub2api" (Join-Path $PyLibExec "cc_win_launcher.py") "sub2api"
Write-CmdShim "cc-totp"        (Join-Path $PyLibExec "cc_win_launcher.py") "totp"
Write-CmdShim "cc-chrome"      (Join-Path $PyLibExec "cc_win_launcher.py") "chrome"

# 初始化空白 accounts.json (幂等，绝不覆盖已有账号数据)
$AccFile = Join-Path $CfgDir "accounts.json"
if (-not (Test-Path -LiteralPath $AccFile)) {
    $InitJson = @"
{
  "active": "",
  "peers": {},
  "nodes": {},
  "win_proxy": "127.0.0.1:7890",
  "expose_tailscale_proxy": false,
  "accounts": {}
}
"@
    [System.IO.File]::WriteAllText($AccFile, $InitJson, [System.Text.UTF8Encoding]::new($false))
    Write-Host "🆕 已初始化空白账号池配置: $AccFile (NTFS 当前用户独占 ACL)" -ForegroundColor Green
}

$Sub2Cfg = Join-Path $ClaudeRelayDir "sub2api.settings.json"
$Sub2Example = Join-Path $ScriptDir "config\sub2api.settings.example.json"
if (-not (Test-Path -LiteralPath $Sub2Cfg) -and (Test-Path -LiteralPath $Sub2Example)) {
    Copy-Item -LiteralPath $Sub2Example -Destination $Sub2Cfg -Force
}

# ---------------------------------------------------------------------------
# 5. 配置用户级 PATH、PowerShell 防裸奔别名与后台无窗口计划任务自愈守护
# ---------------------------------------------------------------------------
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $UserPath) { $UserPath = "" }
$PathParts = $UserPath -split ";" | Where-Object { $_ -ne "" }
if ($PathParts -notcontains $BinDst) {
    $NewUserPath = (@($BinDst) + $PathParts) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    Write-Host "✅ 已将 $BinDst 写入当前用户永久 PATH 环境变量。" -ForegroundColor Green
}

if (-not $NoAlias -and $PROFILE) {
    try {
        $ProfDirPath = Split-Path -Parent $PROFILE
        if (-not (Test-Path -LiteralPath $ProfDirPath)) { New-Item -ItemType Directory -Path $ProfDirPath -Force | Out-Null }
        $ExistingProf = if (Test-Path -LiteralPath $PROFILE) { Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($ExistingProf -notmatch "cc-safe bare-claude guard") {
            $GuardBlock = "`r`n# cc-safe bare-claude guard (relay use claude-sub2api)`r`nfunction claude { & `"`$env:USERPROFILE\.local\bin\cc-safe.cmd`" @args }`r`n"
            [System.IO.File]::AppendAllText($PROFILE, $GuardBlock, [System.Text.UTF8Encoding]::new($false))
        }
    } catch {}
}

if (-not $NoTask) {
    try {
        $TaskName = "cc-safe-tunnel-guard"
        $TunScript = Join-Path $PyLibExec "cc-us-tunnel"
        $Action = New-ScheduledTaskAction -Execute $PythonwExe -Argument "`"$TunScript`" start"
        $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
        Write-Host "⏱️  已注册 Windows 后台静默计划任务 ($TaskName, 每 5 分钟无窗口巡检自愈隧道)。" -ForegroundColor Green
    } catch {
        # 受限组策略环境静默降级（每次运行 cc-safe 仍会自动拉起并校验隧道）
    }
}

Write-Host "✅ Windows ($env:COMPUTERNAME / $ArchTag) 一键部署完成: cc-switch, cc-safe, cc-desktop, cc-chrome, cc-us-tunnel, cc-check-ip, cc-totp, cc-audit, claude-sub2api" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. 执行快捷后续动作 (-Add / -SetIp / -QuickStart)
# ---------------------------------------------------------------------------
$SwCmd = Join-Path $PyLibExec "cc-switch"
if ($Add) {
    $aList = @($SwCmd, "add", $Add)
    if ($Alias) { $aList += $Alias }
    if ($Force) { $aList += "--force" }
    & $PythonExe @aList
    exit $LASTEXITCODE
} elseif ($SetIp) {
    $sList = @($SwCmd, "set-ip")
    if ($Account) { $sList += $Account }
    if ($Proxy)   { $sList += $Proxy }
    if ($Force)   { $sList += "--force" }
    & $PythonExe @sList
    exit $LASTEXITCODE
} elseif ($QuickStart) {
    & $PythonExe $SwCmd init
    exit $LASTEXITCODE
} else {
    Write-Host "--------------------------------------------------------------------------"
    Write-Host "🚀 Windows 快速开始：" -ForegroundColor Yellow
    Write-Host "   1. 交互式菜单 (加号/换IP) : cc-switch init      (或直接双击 quickstart.cmd)"
    Write-Host "   2. 安全添加新账号         : cc-switch add - acc1"
    Write-Host "   3. 一键无损换 IP          : cc-switch set-ip acc1 -"
    Write-Host "   4. 启动隔离 Claude 桌面端 : cc-desktop acc1     (Windows 原生 GUI 客户端防关联)"
    Write-Host "   5. 打开同源隔离浏览器     : cc-chrome acc1      (首次登录授权免配代理)"
    Write-Host "   6. 启动隔离 Claude CLI    : cc-safe"
    Write-Host "--------------------------------------------------------------------------"
}
