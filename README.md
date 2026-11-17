# `cc-safe` 


Claude Code 多账号物理硬隔离与美国静态住宅 ISP 专线防封套件


`cc-safe` 是一套专为在 Linux 服务器（单机或双机集群）上安全使用多个 Claude Pro / Max 个人订阅账号而设计的**账号级物理硬隔离 + Fail-Close 静态住宅 ISP 专线熔断**一键工具链，同时实现与 API 中转通道（`claude-sub2api`）的 100% 物理分离。

---

## 一、 一键部署（免 Root 自动装齐全部依赖）

脚本会自动检测 CPU 架构（`x86_64` / `arm64`），免 `sudo` 自动下载/编译 `jq`、`gost v3`、`proxychains4` 与 `claude` CLI，初始化 `chmod 700` 隔离目录并注册 `crontab` 自愈任务：

### 1. 单机一键直装
```bash
curl -fsSL https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.sh | bash
```

### 2. 双机集群 + 首个账号全自动一步到位
```bash
curl -fsSL https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.sh | bash -s -- \
  --peer <对端服务器IP> \
  --add '邮箱----密码----TOTP密钥----sid(可留空)----代理host:port:user:pass' acc1
```

### 3. 本地克隆安装 / 升级
```bash
git clone https://github.com/safe-cc/cc-safe.git && cd cc-safe
./install.sh
# 或同步全自动部署至对端主机：
./install.sh --sync-peer <对端服务器IP>
```

---

## 二、 核心防封与反关联架构（8 层防御）

```text
~/.claude/                                    <-- [中转专用] claude-sub2api 独占，零个人 OAuth 凭证、零代理污染
~/.claude-safe/                               <-- [个人订阅专用] cc-safe 物理隔离空间 (chmod 700)
├── config/
│   ├── accounts.json                         <-- 账号池、专属 ISP 代理、集群拓扑与封禁状态 (chmod 600)
│   ├── us-tunnel.json                        <-- 当前激活账号隧道元数据 (chmod 600)
│   └── gost.json                             <-- Gost v3 渲染配置 (chmod 600, 进程 cmdline 零明文账密！)
├── locks/
│   ├── cc.lock                               <-- cc-switch / auto-sync 全局本机+对端 flock 互斥锁
│   └── tunnel.lock                           <-- cc-us-tunnel 启停互斥锁
└── profiles/
    ├── <acc1>/
    │   ├── identity.json                     <-- 账号专属 6 维设备指纹锚点
    │   ├── gitconfig                         <-- 账号专属 GIT_CONFIG_GLOBAL (阻断宿主机 Git 用户名跨号关联)
    │   └── home/                             <-- CLAUDE_CONFIG_DIR 物理独占目录 (零跨号软链！)
    │       ├── .claude.json                  <-- 白名单生成的纯净配置
    │       ├── .credentials.json             <-- 该账号独占 OAuth Token
    │       ├── settings.json                 <-- 强制代理、时区、遥测阻断 (保留自定义 MCP/Hooks)
    │       ├── projects/                     <-- 该账号独占历史会话 (无跨号邮箱/签名污染)
    │       └── sessions/
    └── <acc2>/
        └── ...
```

1. **账号级物理 `CLAUDE_CONFIG_DIR` 硬隔离**：每号独占 `~/.claude-safe/profiles/<账号>/home`，零软链共享，杜绝 `history.jsonl`、`signature` 与 `userEmail` 跨号串染。
2. **中转 (`claude-sub2api`) 与个人订阅 100% 物理分家**：`claude-sub2api` 锁定 `~/.claude` 并剥离一切个人代理/OAuth 环境。
3. **零进程参数泄密 (`ps aux` 安全)**：`gost` 通过 `chmod 600` 的 `gost.json` 加载上游账密，`curl` 统一通过 `-K -` 标准输入传参，同机多用户环境下 `cmdline` 零密码与 Bearer Token 泄露。
4. **切号前双机精准进程树清场**：基于 `CC_SAFE_MANAGED=1` 与专属目录锚点递归清理旧会话及全部 MCP/工具子进程，100% 零残留确认后才切隧道，且**绝不误杀**其它使用代理或 `proxychains4` 的普通任务。
5. **6 维独立设备指纹 + Git 身份 + 系统 Keyring 全量隔离**：固化独立 `userID`（即 `/v1/messages` 上报的 `metadata.user_id.device_id`）、`machineID`、`summonSidKey`、`remoteControlMachineId`、`firstStartTime` 与 `claudeCodeFirstTokenDate`；每号生成独立 `GIT_CONFIG_GLOBAL` 阻断 `<system-reminder>` 上报宿主机全局 `Git user`；剥离 `DBUS_SESSION_BUS_ADDRESS` 并锁定 `CLAUDE_SECURESTORAGE_CONFIG_DIR` 阻断 Linux Keyring 串号；同时启用 `BUN_FEATURE_FLAG_DISABLE_IPV6=1` 与 `ipv4first` 双栈封死 IPv6 旁路。
6. **HTTP(7890) + SOCKS5h(7891) 双通道 Fail-Close 强校验**：切号与启动均强制核验双通道 Cloudflare Trace 出口 `ip == EXPECTED_IP` 且 `loc == US`，不匹配直接熔断中止。
7. **封禁状态双机同步熔断 (`banned`)**：检测到 `account_on_hold` 或执行 `cc-switch ban` 时，自动清场双机进程、关闭隧道并同步封锁状态至对端。
8. **新号准入 5 维体检 + 同网段防连坐拦截**：自动核验 Cloudflare 路由、Scamalytics、IPQS (`< 25`)、`ipapi` (`is_datacenter=false`) 与 OAuth 连通性，自动拦截同 IP、同 `/24` 子网及与封禁号同 `/16` 段的高危代理。

---

## 三、 日常命令速查

### 1. 360° 无死角防泄漏抓包实测 (`cc-audit`) 与日常自检 (`doctor`)
```bash
cc-audit                  # 12 维全栈真实验证：本机隐私扫描 + 真实 Claude 报文抓包 + strace 越界审计 + SOCKS5h/Fail-Close 压测
cc-audit --repo-only      # 仅扫描 Git 仓库工作区与全量提交历史是否存在本机主机名/IP/邮箱/密钥泄漏 (已内置为 pre-push 钩子)
cc-switch status          # 查看所有账号状态、当前激活账号、2FA 动态码与 Win+R 浏览器命令
cc-switch doctor          # 运行 8 项生产运行态健康与双机一致性自检
```

### 2. 添加新账号与 IP 准入体检
```bash
# 单独对任意代理执行 5 维风控体检
cc-check-ip 'http://user:pass@host:port'

# 添加并激活新账号（支持命令行或 `cc-switch add -` 交互式输入防终端历史留痕）
cc-switch add '邮箱----密码----TOTP密钥----sid(可留空)----host:port:user:pass' [账号别名]
cc-switch add - [账号别名]
```

### 3. 新账号首次同源 OAuth 登录（仅需一次，双机免重登）
1. 本地电脑按 `Win + R`，粘贴 `cc-switch status` 输出的独立 Chrome 启动命令（通过 Tailscale 走服务器 `:7890` 出口，确保浏览器与服务器出口 IP 100% 同源）：
   ```text
   chrome --user-data-dir="%USERPROFILE%\.claude-chrome\<账号别名>" --proxy-server=<服务器TailscaleIP>:7890
   ```
2. 服务器终端运行 `cc-safe`，输入 `/login` 完成授权（密码可运行 `cc-switch pass` 查看，验证码运行 `cc-totp` 获取）。
3. 授权完成后后台自动归档并同步对端（也可手动执行 `cc-switch sync`）。

### 4. 秒切账号、进程清场、集群绑定与封禁管理
```bash
cc-switch <账号别名>              # 双机进程清场 -> 切换 Gost 专线 -> 双通道核验 -> 同步对端
cc-switch kill                    # 一键清零双机全部 cc-safe / MCP 残留子进程树
cc-switch set-peer <对端IP|off>   # 绑定对端主机 IP 或切换回单机模式
cc-switch ban <账号别名>          # 双机同步标记封禁并熔断停用其隧道
cc-switch unban <账号别名>        # 解除账号封禁状态
```

### 5. 实时额度查询、一键使用 Reset 卡与历史会话脱敏导入
```bash
cc-switch usage                           # 查询 5h 窗口、7d 周额、专项周额及 Reset 卡状态
cc-switch reset                           # 消耗 1 张可用 Reset 卡重置限额（无需重启会话）
cc-switch import-session <关键词或UUID>   # 深度剥离旧号邮箱/UUID/签名后导入指定历史会话
```

### 6. 卸载
```bash
./uninstall.sh            # 卸载命令与定时任务（保留 ~/.claude-safe 账号档案）
./uninstall.sh --purge    # 彻底卸载并清除 ~/.claude-safe
```
