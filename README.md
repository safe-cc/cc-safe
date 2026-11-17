# `cc-safe`

Claude Code 多账号物理硬隔离、一键无损换 IP 与美国静态住宅 ISP 防封套件 (Linux & Windows)

`cc-safe` 是一套专为在 **Linux 服务器 / WSL2 / 原生 Windows 10 & 11** 环境下安全运营多个 Claude Pro / Max 个人订阅账号而设计的 **账号级物理硬隔离 + Fail-Close 美国家宽专线熔断 + 无损换 IP** 一键工具链，同时实现与 API 中转通道（`claude-sub2api`）的 100% 物理分离。

---

## 一、 30 秒快速开始（Clone 后即装即用，免管理员/Root 自动装齐依赖）

### 🐧 Linux / WSL2 一键安装与启动

自动识别 `x86_64` / `arm64`，免 `sudo` 自动下载/编译 `jq`、`gost v3`、`proxychains4` 与 `claude` CLI，初始化 `chmod 700 / 600` 隔离空间并注册自愈守护任务：

```bash
# 推荐方式 1：Clone 后一键安装并直接进入交互式向导 (无需重开终端或手配 PATH)
git clone https://github.com/safe-cc/cc-safe.git && cd cc-safe
./quickstart.sh

# 快捷子命令：
./quickstart.sh add - acc1              # 安全隐藏输入添加新账号 acc1
./quickstart.sh set-ip acc1 -           # 为已有账号 acc1 一键无损换 IP (免重新登录！)
./quickstart.sh audit                   # 运行 15 维 360° 真实抓包防封审计

# 方式 2：远程单行无人值守直装 / 双机集群一键同步部署
curl -fsSL https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.sh | bash
./install.sh --peer <对端服务器IP>
```

---

### 🪟 Windows 10 / 11 一键安装与启动（原生免管理员）

自动识别 `x64` / `ARM64`，免管理员自动部署独立版 `Python 3.12`、`gost.exe v3` 与 `claude` CLI，执行 NTFS 用户独占 ACL 权限加固，注册无窗口后台隧道自愈守护，并内置 `cc-chrome` 一键同源隔离浏览器：

```powershell
# 推荐方式 1：Clone 后直接双击 quickstart.cmd，或在终端运行：
git clone https://github.com/safe-cc/cc-safe.git
cd cc-safe
.\quickstart.cmd

# 快捷子命令：
.\quickstart.cmd add - acc1             # 安全隐藏输入添加新账号 acc1
.\quickstart.cmd set-ip acc1 -          # 为已有账号 acc1 一键无损换 IP (免重新登录！)
.\quickstart.cmd chrome acc1            # 一键打开同源美国出口隔离浏览器 (远端 DNS + 禁 QUIC)
.\quickstart.cmd audit                  # 运行 15 维 360° 防封防关联实测审计

# 方式 2：PowerShell 远程单行一键直装
irm https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.ps1 | iex

# 方式 3：若偏好将 cc-safe 一键部署进 WSL2 Linux 子系统 (使用 ELF proxychains4)
.\install.ps1 -WSL -QuickStart
```

运行 `./quickstart.sh` 或 `.\quickstart.cmd` 后会直接打开交互式向导菜单：
- `[1]` **添加并激活新账号**（密码与代理全程隐藏输入，**0 字节留痕**于历史记录或进程参数）
- `[2]` **给已有账号一键无损换 IP**（保留设备指纹与已登录 OAuth 凭证，**免重新登录**！）
- `[3]` **秒切当前激活账号**（旧会话进程树清场 + Gost 专线热切 + HTTP/SOCKS5h 双通道 US 核验）
- `[4]` **配置双机集群同步**（双向绑定对端服务器 IP）
- `[5]` **运行 15 维 360° 真实抓包防泄漏实测 (`cc-audit`)**

---

## 二、 一键无损换 IP（`换IP`：免重新登录、不掉设备指纹）

当某个账号的静态住宅 ISP 代理到期、延迟变高或需要更换新家宽 IP 时，**切勿重新 `add` 新号**（否则会生成全新设备指纹并丢失登录态），直接使用 `set-ip`（同义命令：`change-ip` / `rotate-ip` / `set-proxy`）：

```bash
# 方式 A：全交互隐藏输入（最安全，代理账密零历史留痕）
cc-switch set-ip

# 方式 B：为指定账号（支持别名或邮箱）隐藏输入新代理
cc-switch set-ip acc1 -

# 方式 C：命令行直接传入新代理（支持 host:port:user:pass、[ipv6]:port:user:pass 或 URL 格式）
cc-switch set-ip acc1 "isp-new.example.com:10001:user:pass"
```

**`set-ip` 自动执行的 6 步防封保护：**
1. **5 维准入体检**：自动调用 `cc-check-ip` 核验 Cloudflare 路由、Scamalytics（`< 35`）、IPQS（`< 25`）、`ipapi`（`is_datacenter=false`）及 OAuth 连通性；
2. **防撞车与淘汰 IP 防回用**：自动拦截封禁账号误操作、与其它账号同 IP / 同 `/24` 子网、与已封禁号同 `/16` 段，以及 `ip_history` 中曾经淘汰退役过的旧 IP；
3. **长连接防瞬移清场**：若该账号当前处于激活态，先递归终止活跃旧会话进程树，严防同一会话中途瞬移 IP（跨州变更时区时自动给出静置提醒）；
4. **时区自动对齐**：根据新 IP 真实属地自动更新该账号的 `TZ`（如 `America/New_York` -> `America/Los_Angeles`），杜绝 IP 属地与时区穿帮；
5. **100% 无损保留身份与登录态**：原账号的 6 维设备指纹（`identity.json` 中的 `userID` / `machineID`）与已登录 `.credentials.json` 完整保留，换完直接运行 `cc-safe` 即可继续使用，**无需重新网页授权**；
6. **双通道热切核验**：自动热重启 Gost 隧道，强制校验 HTTP (`:7890`) 与 SOCKS5h (`:7891`) 出口均为新美国 IP。

---

## 三、 核心防封与反关联架构（Linux + Windows 10 层纵深防御）

```text
~/.claude/                                    <-- [中转专用] claude-sub2api 独占，零个人 OAuth 凭证、零代理污染
~/.claude-safe/                               <-- [个人订阅专用] cc-safe 物理隔离空间 (Linux 0700 / Windows NTFS 当前用户独占 ACL)
├── config/
│   ├── accounts.json                         <-- 账号池、专属 ISP 代理、ip_history 退役记录与封禁状态 (0600)
│   ├── us-tunnel.json                        <-- 当前激活账号隧道元数据 (ban 时自动归零，防计划任务复活)
│   └── gost.json                             <-- Gost v3 运行时配置 (0600，进程参数零明文账密，stop 时自动擦除)
├── libexec/
│   ├── git / git.cmd                         <-- Git `-c` 强制身份垫片 (同时阻断 ~/.gitconfig 与项目 .git/config 泄露)
│   └── py/                                   <-- Windows 原生监督器 (cc_win_launcher.py) 与跨平台管理引擎
├── locks/
│   ├── cc.lock / tunnel.lock                 <-- 全局文件锁 (Linux flock / Windows msvcrt.locking)
│   └── win_sessions/                         <-- Windows 会话 (PID + NT CreateTime) 精确追踪锚点
└── profiles/
    └── <acc1>/
        ├── identity.json                     <-- 账号专属 6 维设备指纹锚点 (0600)
        ├── gitconfig                         <-- 账号专属 GIT_CONFIG_GLOBAL
        ├── browser-profile/                  <-- [Windows] cc-chrome 独占浏览器目录 (继承 NTFS ACL)
        └── home/                             <-- CLAUDE_CONFIG_DIR / HOME / APPDATA 物理独占目录 (零跨号软链！)
            ├── .claude.json                  <-- 白名单纯净配置 (锁死自动更新与 GrowthBook 遥测)
            ├── .credentials.json             <-- 该账号独占 OAuth Token (0600)
            ├── settings.json                 <-- 强制大小写代理、socks5h、时区、遥测阻断 (保留自定义 MCP/Hooks)
            └── projects/                     <-- 独占历史会话 (零跨号邮箱/加密签名/路径污染)
```

1. **物理 `CLAUDE_CONFIG_DIR` 独占**：每号独占 `~/.claude-safe/profiles/<账号>/home`，零软链共享，彻底阻断 `history.jsonl`、服务端加密 `signature` 与 `userEmail` 跨号串染。
2. **中转 (`claude-sub2api`) 与个人订阅 100% 物理分家**：`claude-sub2api` 锁定 `~/.claude`，自动剥离 `libexec` 垫片、个人 OAuth 变量、自定义头与大小写代理环境。
3. **零命令行与历史泄密 (`ps aux` / 任务管理器安全)**：支持 `-` 隐藏输入；`gost` 通过临时 `gost.json` 加载账密并在停机/封禁时自动擦除；`curl` 统一走防换行注入的 `-K -` 标准输入。
4. **双平台内核级孤儿进程收割 + 实时断流熔断**：
   - **Linux**：注册 `PR_SET_CHILD_SUBREAPER` 内核子进程收养器 + `proxychains4` (`strict_chain` + `proxy_dns` `ATYP=0x03`)；
   - **Windows**：隔离 `HOME` / `USERPROFILE` / `APPDATA` / `LOCALAPPDATA`，创建 Windows NT 内核作业对象（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）杜绝任何 MCP/工具孤儿子进程逃逸，并内置 **1 秒级实时断流看门狗（Live Kill-Switch）**——一旦 Gost 专线端口断开、`us-tunnel.sha256` 停用/篡改或账号被切换/封禁，立即销毁整个会话作业树严防直连暴露！
5. **6 维独立设备指纹 + 双层 Git 身份防穿透**：固化独立 `userID`（`metadata.user_id.device_id`）、`machineID`、`summonSidKey`、`remoteControlMachineId`、`firstStartTime` 与 `claudeCodeFirstTokenDate`；通过 `GIT_CONFIG_GLOBAL` + `libexec/git -c` 垫片同时拦截全局 `~/.gitconfig` 与工作区本地 `.git/config` 身份/GPG 穿透；剥离 `GH_TOKEN`、`SSH_CONNECTION`、`ANTHROPIC_CUSTOM_HEADERS`。
6. **免疫 `NO_PROXY=*` 与小写代理劫持的双通道强校验**：内部探测强制 `--noproxy ""`；运行期同时锁定大小写 `HTTPS_PROXY`/`https_proxy` 与 `ALL_PROXY`/`all_proxy=socks5h://127.0.0.1:7891` + `BUN_FEATURE_FLAG_DISABLE_IPV6=1` + `ipv4first`，双通道均必须满足 `ip == EXPECTED_IP` 且 `loc == US`。
7. **封禁 (`banned`) 同步锁死防复活**：检测到 `account_on_hold` 或执行 `cc-switch ban` 时，立即清场会话进程、清空 `us-tunnel.json`、擦除 `gost.json`，并由 `cc-us-tunnel` 二次联锁拦截定时任务复活。
8. **历史会话深度递归脱敏 (`import-session`)**：支持任意文件大小全文检索、嵌套 `<sid>/subagents/*.jsonl` 同步导入，自动剥离全域名邮箱、`cwd`、分支名、旧 UUID 与服务端加密 `thinking.signature`。

---

## 四、 新账号首次同源 OAuth 登录（仅需一次，换 IP 与双机均免重登）

- **在 Windows 本机直接运行 `cc-safe` 时（最简单）**：
  1. 终端运行 `cc-chrome <账号别名>` —— 自动校验当前美国出口后拉起独立数据目录 Chrome/Edge（自动附带 `--host-resolver-rules=MAP * ~NOTFOUND` 强制远端 DNS 解析 + `--disable-quic` 阻断 UDP 泄漏）；
  2. 再运行 `cc-safe`，输入 `/login` 在该隔离浏览器窗口内完成授权（密码可运行 `cc-switch pass` 查看，2FA 动态码运行 `cc-totp` 获取）。
- **在远程 Linux 服务器运行 `cc-safe` 时**：
  1. 在本地电脑执行 SSH 端口转发（零公网/内网端口暴露）：
     ```bash
     ssh -N -L 7890:127.0.0.1:7890 <你的服务器SSH地址>
     # 本地打开独立目录 Chrome (远端 DNS + 禁 QUIC)：
     chrome --user-data-dir="%USERPROFILE%\.claude-chrome\<账号别名>" --proxy-server=http://127.0.0.1:7890 --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" --disable-quic
     ```
  2. 服务器终端运行 `cc-safe`，输入 `/login` 完成授权；后台守护自动提取归档并同步对端服务器。

---

## 五、 日常命令速查（Linux & Windows 通用）

```bash
# 快速开始与状态自检
./quickstart.sh / .\quickstart.cmd        # Clone 后一键安装并打开交互式向导菜单
cc-switch init                            # 随时打开交互式向导 (上号 / 换 IP / 切号 / 审计)
cc-switch status                          # 查看账号池、出口 IP、历史换 IP 次数与 2FA 动态码
cc-switch doctor                          # 运行 8 项生产运行态健康与双机一致性自检
cc-audit                                  # 运行 15 维 360° 真实抓包 + 熔断 + 换 IP 防封审计
cc-audit --repo-only                      # 扫描仓库工作区与全量 Git 历史零本机隐私泄漏 (内置 pre-push 钩子)

# 账号录入、无损换 IP 与代理体检 (推荐加 `-` 使用隐藏输入，零历史留痕)
cc-check-ip -                             # 隐藏输入代理，单独执行 5 维纯净度与 ASN 风控体检
cc-switch add - [别名]                    # 隐藏输入邮箱/密码/2FA/代理并激活新账号
cc-switch set-ip [别名] -                 # 隐藏输入新代理，无损更换账号出口 IP (保留指纹与登录态！)

# 会话启动、同源浏览器、切号与封禁熔断
cc-switch <账号别名>                      # 进程树清场 -> 切换 Gost 专线 -> 双通道核验 -> 同步对端
cc-safe                                   # 启动当前激活账号的物理隔离 Claude Code 会话 (已设 claude 别名保护)
cc-chrome [账号别名]                      # [Windows] 一键打开该账号专属同源美国 IP 隔离浏览器
claude-sub2api                            # 启动完全物理分离的中转通道 Claude Code (~/.claude)
cc-switch kill                            # 一键清零全部 cc-safe / MCP 残留子进程树
cc-switch ban <别名> / unban <别名>       # 封禁熔断锁死隧道 (防自愈任务复活) / 解除封禁
cc-switch rm <别名> [--purge]             # 移除账号配置 (--purge 同时删除其本地隔离档案目录)

# 额度查询、Reset 卡与历史会话脱敏迁移
cc-switch usage                           # 查询 5h 窗口、7d 周总额、专项额度与 Reset 卡状态
cc-switch reset                           # 一键使用可用 Reset 卡重置限额（无需重启会话）
cc-switch import-session <关键词或UUID>   # 深度剥离旧号 UUID/全域名邮箱/cwd/加密签名后导入历史会话 (含 subagents)

# 卸载
./uninstall.sh [--purge]                  # Linux 卸载命令、还原 shell alias 与 crontab
.\uninstall.ps1 [-Purge]                  # Windows 卸载命令、还原 PowerShell $PROFILE 与计划任务
```
