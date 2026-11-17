#!/usr/bin/env bash
# install.sh — cc-safe 全自动一键部署脚本 (支持 git clone 本地安装、curl | bash 远程直装、免 root 依赖自举、双机同步与一键换 IP)
set -euo pipefail

REPO_URL="${CC_SAFE_REPO_URL:-https://github.com/safe-cc/cc-safe.git}"
TARBALL_URL="${CC_SAFE_TARBALL_URL:-https://github.com/safe-cc/cc-safe/archive/refs/heads/main.tar.gz}"
GOST_FALLBACK_VER="3.3.3"
JQ_VER="1.7.1"
PROXYCHAINS_VER="4.17"

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ---------------------------------------------------------------------------
# 0. 操作系统检查 (proxychains4 LD_PRELOAD + /proc 隔离 + PR_SET_CHILD_SUBREAPER 依赖 Linux 内核)
# ---------------------------------------------------------------------------
UNAME_S="$(uname -s)"
if [ "$UNAME_S" != "Linux" ]; then
    echo "❌ 当前系统为 ${UNAME_S}；cc-safe 依赖 Linux ELF LD_PRELOAD 与 /proc 内核隔离机制，请在 Linux 服务器或 Windows WSL2 中运行。" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0.5 若通过 `curl -fsSL .../install.sh | bash` 管道调用，先拉取仓库至 ~/.claude-safe/repo
# ---------------------------------------------------------------------------
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
if [ -z "$SCRIPT_SRC" ] || [ ! -f "$(cd "$(dirname "$SCRIPT_SRC")" 2>/dev/null && pwd)/bin/cc-switch" ]; then
    BOOTSTRAP_DIR="$HOME/.claude-safe/repo"
    mkdir -p "$HOME/.claude-safe"
    chmod 700 "$HOME/.claude-safe"
    echo "📦 [Bootstrap] 正在拉取 safe-cc/cc-safe 仓库至 $BOOTSTRAP_DIR ..."
    if command -v git >/dev/null 2>&1; then
        if [ -d "$BOOTSTRAP_DIR/.git" ]; then
            git -C "$BOOTSTRAP_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
            git -C "$BOOTSTRAP_DIR" fetch --depth 1 origin main -q
            git -C "$BOOTSTRAP_DIR" reset --hard FETCH_HEAD -q
        else
            rm -rf "$BOOTSTRAP_DIR"
            git clone --depth 1 -q "$REPO_URL" "$BOOTSTRAP_DIR"
        fi
        chmod 700 "$BOOTSTRAP_DIR" 2>/dev/null || true
    else
        rm -rf "$BOOTSTRAP_DIR"
        mkdir -p -m 700 "$BOOTSTRAP_DIR"
        curl -fsSL "$TARBALL_URL" | tar -xz -C "$BOOTSTRAP_DIR" --strip-components=1
    fi
    exec bash "$BOOTSTRAP_DIR/install.sh" "$@"
fi

REPO_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
BIN_DST="$HOME/.local/bin"
LIB_DST="$HOME/.local/lib"
ETC_DST="$HOME/.local/etc"
SAFE_DIR="$HOME/.claude-safe"

SYNC_PEER=0
PEER_IP=""
SKIP_CLAUDE=0
NO_CRON=0
NO_ALIAS=0
UPGRADE_DEPS=0
RUN_WIZARD=0
ADD_RAW=""
ADD_ALIAS=""
DO_SET_IP=0
SET_IP_ACC=""
SET_IP_PROXY=""
FORCE_FLAG=""

usage() {
    cat <<'EOF'
用法:
  ./quickstart.sh                                  # 克隆后一键安装 + 启动交互式向导 (含加号/换IP/切号/审计)
  ./install.sh [选项]
  curl -fsSL https://raw.githubusercontent.com/safe-cc/cc-safe/main/install.sh | bash -s -- [选项]

选项:
  -i, --quickstart, --init           部署完成后立即进入交互式配置向导 (支持添加账号 / 一键换 IP / 审计)
  --add '<账号串|->' [别名]          部署完成后立即体检并激活新账号 (`-` 表示隐藏输入防历史留痕)
  --set-ip [别名] ['<新代理>'|-]     部署完成后立即为指定账号无损换 IP (保留设备指纹与登录态)
  --sync-peer [PEER_IP]              一键全量部署并同步至对端服务器 (未传 IP 则读取 accounts.json)
  --peer <PEER_IP>                   绑定对端 IP 并执行双机一键部署同步
  --force                            配合 --add / --set-ip 跳过同子网/IP 纯净度强拦截
  --upgrade-deps                     强制重新下载/编译更新 gost、jq、proxychains4
  --skip-claude                      若未安装 Claude Code CLI，跳过自动安装
  --no-cron                          跳过注册 crontab 自愈守护任务
  --no-alias                         不在 ~/.bashrc / ~/.zshrc 中注册 `alias claude=cc-safe` 防裸奔保护
  -h, --help                         显示帮助说明
EOF
}

validate_peer_arg() {
    local p="$1"
    if [ -z "$p" ] || [[ "$p" =~ ^- ]] || [[ ! "$p" =~ ^[A-Za-z0-9._:\[\]-]+$ ]]; then
        echo "❌ 非法对端主机地址: '$p'" >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--quickstart|--init)
            RUN_WIZARD=1
            shift
            ;;
        --sync-peer)
            SYNC_PEER=1
            if [ $# -ge 2 ] && [[ ! "$2" =~ ^- ]]; then
                PEER_IP="$2"
                validate_peer_arg "$PEER_IP"
                shift
            fi
            shift
            ;;
        --peer)
            SYNC_PEER=1
            PEER_IP="${2:-}"
            validate_peer_arg "$PEER_IP"
            shift 2
            ;;
        --add)
            ADD_RAW="${2:-}"
            if [ -z "$ADD_RAW" ] || [[ "$ADD_RAW" =~ ^-- ]]; then
                echo "❌ --add 需要传入账号配置串或 '-' (安全隐藏输入)" >&2
                exit 1
            fi
            shift 2
            if [ $# -ge 1 ] && [[ ! "$1" =~ ^- ]]; then
                ADD_ALIAS="$1"
                shift
            fi
            ;;
        --set-ip|--change-ip|--rotate-ip)
            DO_SET_IP=1
            shift
            if [ $# -ge 1 ] && { [ "$1" = "-" ] || [[ ! "$1" =~ ^- ]]; }; then
                SET_IP_ACC="$1"
                shift
                if [ $# -ge 1 ] && { [ "$1" = "-" ] || [[ ! "$1" =~ ^- ]]; }; then
                    SET_IP_PROXY="$1"
                    shift
                fi
            fi
            ;;
        --force)
            FORCE_FLAG="--force"
            shift
            ;;
        --upgrade-deps)
            UPGRADE_DEPS=1
            shift
            ;;
        --skip-claude)
            SKIP_CLAUDE=1
            shift
            ;;
        --no-cron)
            NO_CRON=1
            shift
            ;;
        --no-alias)
            NO_ALIAS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ 未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

mkdir -p -m 0755 "$BIN_DST" "$LIB_DST" "$ETC_DST"
mkdir -p "$SAFE_DIR" "$SAFE_DIR/config" "$SAFE_DIR/locks" "$SAFE_DIR/logs" "$SAFE_DIR/profiles"
chmod 700 "$SAFE_DIR" "$SAFE_DIR/config" "$SAFE_DIR/locks" "$SAFE_DIR/logs" "$SAFE_DIR/profiles"

# ---------------------------------------------------------------------------
# 1. 系统架构与基础环境检查
# ---------------------------------------------------------------------------
UNAME_M="$(uname -m)"
case "$UNAME_M" in
    x86_64|amd64) ARCH_TAG="amd64" ;;
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *)
        echo "❌ 不支持的 CPU 架构: $UNAME_M (仅支持 x86_64 / arm64)" >&2
        exit 1
        ;;
esac

try_pkg_install() {
    local pkgs=("$@")
    local sudo_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        sudo_cmd=()
    elif command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            sudo_cmd=(sudo -n)
        elif [ -t 0 ]; then
            echo "🔐 需要 sudo 权限以安装系统组件 (${pkgs[*]})..."
            sudo_cmd=(sudo)
        else
            return 1
        fi
    else
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get install -y -qq "${pkgs[@]}" >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        "${sudo_cmd[@]}" dnf install -y -q "${pkgs[@]}" >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        "${sudo_cmd[@]}" yum install -y -q "${pkgs[@]}" >/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        local arch_pkgs=()
        local p
        for p in "${pkgs[@]}"; do
            if [ "$p" = "python3" ]; then
                arch_pkgs+=("python")
            else
                arch_pkgs+=("$p")
            fi
        done
        "${sudo_cmd[@]}" pacman -S --needed --noconfirm "${arch_pkgs[@]}" >/dev/null
    else
        return 1
    fi
}

for base_bin in curl python3 tar; do
    if ! command -v "$base_bin" >/dev/null 2>&1; then
        echo "🔧 正在安装缺失基础组件: $base_bin ..."
        try_pkg_install "$base_bin" ca-certificates || {
            echo "❌ 系统缺少 $base_bin 且当前无法自动安装，请先手动安装 $base_bin。" >&2
            exit 1
        }
    fi
done

BUILD_TMP="$SAFE_DIR/.build_tmp_$$"
mkdir -p -m 700 "$BUILD_TMP"
cleanup_tmp() { rm -rf "$BUILD_TMP" 2>/dev/null || true; }
trap cleanup_tmp EXIT

# ---------------------------------------------------------------------------
# 2. 免 root 自动安装 jq / gost v3 / proxychains4 / claude
# ---------------------------------------------------------------------------
if [ "$UPGRADE_DEPS" -eq 1 ] || ! command -v jq >/dev/null 2>&1; then
    echo "⬇️  正在安装静态二进制 jq (${ARCH_TAG}) -> $BIN_DST/jq ..."
    curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VER}/jq-linux-${ARCH_TAG}" -o "$BUILD_TMP/jq.tmp"
    chmod 0755 "$BUILD_TMP/jq.tmp"
    "$BUILD_TMP/jq.tmp" --version >/dev/null
    install -m 0755 "$BUILD_TMP/jq.tmp" "$BIN_DST/jq"
fi

need_gost=0
if [ "$UPGRADE_DEPS" -eq 1 ] || [ ! -x "$BIN_DST/gost" ]; then
    need_gost=1
elif ! "$BIN_DST/gost" -V 2>&1 | grep -qE "^gost 3\."; then
    need_gost=1
fi

if [ "$need_gost" -eq 1 ]; then
    echo "⬇️  正在安装 gost v3 (${ARCH_TAG}) -> $BIN_DST/gost ..."
    GOST_URL=$(python3 - "$ARCH_TAG" "$GOST_FALLBACK_VER" <<'PY'
import json, sys, urllib.request
arch, fb = sys.argv[1], sys.argv[2]
fallback = f"https://github.com/go-gost/gost/releases/download/v{fb}/gost_{fb}_linux_{arch}.tar.gz"
try:
    req = urllib.request.Request("https://api.github.com/repos/go-gost/gost/releases/latest", headers={"User-Agent": "cc-safe-installer"})
    with urllib.request.urlopen(req, timeout=6) as r:
        d = json.loads(r.read().decode())
    for a in d.get("assets") or []:
        u = a.get("browser_download_url", "")
        if f"linux_{arch}.tar.gz" in u:
            print(u)
            sys.exit(0)
except Exception:
    pass
print(fallback)
PY
)
    curl -fsSL "$GOST_URL" -o "$BUILD_TMP/gost.tar.gz"
    tar -xzf "$BUILD_TMP/gost.tar.gz" -C "$BUILD_TMP" gost
    install -m 0755 "$BUILD_TMP/gost" "$BIN_DST/gost"
fi

has_valid_proxychains() {
    if [ -x "$BIN_DST/proxychains4" ] && { [ -f "$LIB_DST/libproxychains4.so" ] || [ -f "$HOME/.local/lib64/libproxychains4.so" ]; }; then
        return 0
    fi
    local sys_pc
    sys_pc="$(PATH="/usr/local/bin:/usr/bin:/bin" command -v proxychains4 2>/dev/null || true)"
    if [ -n "$sys_pc" ] && [ -x "$sys_pc" ]; then
        return 0
    fi
    return 1
}

if [ "$UPGRADE_DEPS" -eq 1 ] || ! has_valid_proxychains; then
    echo "🔧 正在部署 proxychains4 (proxychains-ng v${PROXYCHAINS_VER}) ..."
    pc_installed=0
    if (command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1) && command -v make >/dev/null 2>&1; then
        mkdir -p -m 700 "$BUILD_TMP/pc"
        if curl -fsSL "https://github.com/rofl0r/proxychains-ng/archive/refs/tags/v${PROXYCHAINS_VER}.tar.gz" \
            | tar -xz -C "$BUILD_TMP/pc" --strip-components=1 \
            && (
                cd "$BUILD_TMP/pc"
                ./configure --prefix="$HOME/.local" --sysconfdir="$ETC_DST" >/dev/null
                make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
                make install >/dev/null
            ); then
            pc_installed=1
        else
            echo "⚠️  源码编译 proxychains-ng 未完成（可能缺少 libc 头文件），尝试通过包管理器安装..." >&2
        fi
    fi

    if [ "$pc_installed" -eq 0 ]; then
        if try_pkg_install proxychains4 || try_pkg_install proxychains-ng; then
            SYS_PC="$(PATH="/usr/local/bin:/usr/bin:/bin" command -v proxychains4 || true)"
            if [ -n "$SYS_PC" ] && [ "$SYS_PC" != "$BIN_DST/proxychains4" ]; then
                ln -sf "$SYS_PC" "$BIN_DST/proxychains4"
            fi
            pc_installed=1
        fi
    fi

    if [ "$pc_installed" -eq 0 ] && ! has_valid_proxychains; then
        echo "❌ 未找到 proxychains4，且系统缺少完整编译工具链 (gcc/make/libc-dev) 无法免 root 编译！" >&2
        echo "   请先安装 build-essential 或 proxychains4 后重跑 ./quickstart.sh 或 ./install.sh。" >&2
        exit 1
    fi
fi

if [ "$SKIP_CLAUDE" -eq 0 ] && ! command -v claude >/dev/null 2>&1; then
    echo "⬇️  未检测到 Claude Code CLI，正在执行官方原生安装 ..."
    curl -fsSL https://claude.ai/install.sh | bash || {
        echo "⚠️  Claude Code 自动安装未完成（若服务器直连受限，可稍后通过代理安装或加 --skip-claude）。" >&2
    }
fi

# ---------------------------------------------------------------------------
# 3. 部署核心脚本、配置文件与模板初始化 (100% 幂等，绝不覆盖已有真实密钥)
# ---------------------------------------------------------------------------
SCRIPTS=(cc-switch cc-safe cc-us-tunnel cc-totp cc-check-ip cc-audit claude-sub2api)
for script in "${SCRIPTS[@]}"; do
    install -m 0755 "$REPO_DIR/bin/$script" "$BIN_DST/$script"
done
install -m 0644 "$REPO_DIR/config/proxychains.conf" "$ETC_DST/proxychains.conf"

if [ -d "$REPO_DIR/.git" ] && [ -f "$REPO_DIR/.githooks/pre-push" ]; then
    chmod +x "$REPO_DIR/.githooks/pre-push"
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
fi

ACCOUNTS_FILE="$SAFE_DIR/config/accounts.json"
if [ ! -f "$ACCOUNTS_FILE" ]; then
    python3 - "$ACCOUNTS_FILE" <<'PY'
import json, os, sys
os.umask(0o077)
dst = sys.argv[1]
init_obj = {
    "active": "",
    "peers": {},
    "nodes": {},
    "win_proxy": "127.0.0.1:7890",
    "expose_tailscale_proxy": False,
    "accounts": {},
}
tmp = dst + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(init_obj, f, indent=2, ensure_ascii=False)
os.replace(tmp, dst)
PY
    echo "🆕 已初始化空白账号池配置: $ACCOUNTS_FILE (chmod 600, 默认仅监听本机 127.0.0.1)"
else
    chmod 600 "$ACCOUNTS_FILE" 2>/dev/null || true
fi

mkdir -p "$HOME/.claude"
chmod 700 "$HOME/.claude" 2>/dev/null || true
SUB2API_CFG="$HOME/.claude/sub2api.settings.json"
if [ ! -f "$SUB2API_CFG" ] && [ -f "$REPO_DIR/config/sub2api.settings.example.json" ]; then
    install -m 0600 "$REPO_DIR/config/sub2api.settings.example.json" "$SUB2API_CFG"
fi

# 若存量环境已有激活账号但尚未生成新版 us-tunnel.json，自动平滑生成配置
python3 - <<'PY'
import importlib.machinery, importlib.util, os
h = os.path.expanduser("~")
tj = os.path.join(h, ".claude-safe/config/us-tunnel.json")
sw = os.path.join(h, ".local/bin/cc-switch")
if not os.path.exists(tj) and os.path.exists(sw):
    loader = importlib.machinery.SourceFileLoader("cc_sw", sw)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    d = mod.load_accounts()
    ak = d.get("active", "")
    acc = (d.get("accounts") or {}).get(ak)
    if acc and acc.get("proxy") and acc.get("status") != "banned":
        mod.write_tunnel_configs(acc, expose_tailscale=bool(d.get("expose_tailscale_proxy", False)))
PY

# ---------------------------------------------------------------------------
# 4. 确保 ~/.local/bin 写入 PATH 并注册 crontab 自愈任务
# ---------------------------------------------------------------------------
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
ALIAS_LINE='alias claude="$HOME/.local/bin/cc-safe"'
for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && ! grep -qF '.local/bin' "$rc" 2>/dev/null; then
        printf '\n# cc-safe PATH\n%s\n' "$PATH_LINE" >> "$rc"
    fi
done
if [ "$NO_ALIAS" -eq 0 ]; then
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ] && ! grep -qE 'alias[[:space:]]+claude=' "$rc" 2>/dev/null; then
            printf '\n# cc-safe bare-claude guard (relay use `claude-sub2api`)\n%s\n' "$ALIAS_LINE" >> "$rc"
        fi
    done
fi
if [ ! -f "$HOME/.profile" ] && [ ! -f "$HOME/.bashrc" ]; then
    printf '# cc-safe PATH\n%s\n' "$PATH_LINE" > "$HOME/.profile"
fi

if [ "$NO_CRON" -eq 0 ] && command -v crontab >/dev/null 2>&1; then
    EXISTING_CRON="$(crontab -l 2>/dev/null || true)"
    NEW_CRON="$EXISTING_CRON"
    TUNNEL_CRON="*/5 * * * * $BIN_DST/cc-us-tunnel start >/dev/null 2>&1"
    SYNC_CRON="*/2 * * * * $BIN_DST/cc-switch auto-sync >/dev/null 2>&1"
    CRON_CHANGED=0
    if ! printf '%s\n' "$NEW_CRON" | grep -qF "cc-us-tunnel start"; then
        NEW_CRON="${NEW_CRON}"$'\n'"${TUNNEL_CRON}"
        CRON_CHANGED=1
    fi
    if ! printf '%s\n' "$NEW_CRON" | grep -qF "cc-switch auto-sync"; then
        NEW_CRON="${NEW_CRON}"$'\n'"${SYNC_CRON}"
        CRON_CHANGED=1
    fi
    if [ "$CRON_CHANGED" -eq 1 ]; then
        printf '%s\n' "$NEW_CRON" | sed '/^[[:space:]]*$/d' | crontab - 2>/dev/null || true
        echo "⏱️  已注册 crontab 自愈守护任务 (隧道巡检 5min / 凭证自愈同步 2min)"
    fi
    if command -v pgrep >/dev/null 2>&1 && ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
        echo "ℹ️  [提示] 当前系统后台 cron 服务未运行（常见于 WSL2/容器）；每次运行 cc-safe 仍会自动拉起并校验隧道。"
    fi
fi

echo "✅ 本机 ($(hostname)) 一键部署完成: ${SCRIPTS[*]}"

# ---------------------------------------------------------------------------
# 5. 双机一键同步部署 (--sync-peer / --peer)
# ---------------------------------------------------------------------------
if [ "$SYNC_PEER" -eq 1 ]; then
    if [ -n "$PEER_IP" ]; then
        "$BIN_DST/cc-switch" set-peer "$PEER_IP"
    else
        PEER_IP=$(python3 - <<'PY'
import importlib.machinery, importlib.util, os
sw = os.path.expanduser("~/.local/bin/cc-switch")
loader = importlib.machinery.SourceFileLoader("cc_sw", sw)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(mod.get_peer_host(mod.load_accounts()))
PY
)
    fi

    if [ -z "$PEER_IP" ]; then
        echo "❌ 未指定对端 IP，且 accounts.json 中未找到当前主机的对端配置！" >&2
        echo "   用法: ./install.sh --peer <对端IP>" >&2
        exit 1
    fi
    validate_peer_arg "$PEER_IP"

    echo "🔄 正在全量一键部署至对端主机 ($PEER_IP) ..."
    REMOTE_FLAGS=()
    [ "$SKIP_CLAUDE" -eq 1 ] && REMOTE_FLAGS+=("--skip-claude")
    [ "$NO_CRON" -eq 1 ] && REMOTE_FLAGS+=("--no-cron")
    [ "$NO_ALIAS" -eq 1 ] && REMOTE_FLAGS+=("--no-alias")
    [ "$UPGRADE_DEPS" -eq 1 ] && REMOTE_FLAGS+=("--upgrade-deps")
    REMOTE_FLAGS_STR="${REMOTE_FLAGS[*]+"${REMOTE_FLAGS[*]}"}"

    LOCAL_REACH_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -z "$LOCAL_REACH_IP" ] && command -v ip >/dev/null 2>&1; then
        LOCAL_REACH_IP="$(ip -4 route get "$PEER_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
    fi

    tar -czf - -C "$REPO_DIR" --exclude='.git' . \
        | ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -- "$PEER_IP" \
            "umask 077 && mkdir -p ~/.claude-safe/repo && chmod 700 ~/.claude-safe ~/.claude-safe/repo && tar -xzf - -C ~/.claude-safe/repo && bash ~/.claude-safe/repo/install.sh $REMOTE_FLAGS_STR"

    if [ -n "$LOCAL_REACH_IP" ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=5 -- "$PEER_IP" "~/.local/bin/cc-switch set-peer '$LOCAL_REACH_IP'" >/dev/null 2>&1 || true
    fi

    HAS_ACTIVE=$(python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.claude-safe/config/accounts.json"))); ak=d.get("active"); acc=(d.get("accounts") or {}).get(ak); print("1" if acc and acc.get("status")!="banned" else "0")')
    if [ "$HAS_ACTIVE" = "1" ]; then
        "$BIN_DST/cc-switch" sync --quiet || true
    fi
    echo "✅ 对端主机 ($PEER_IP) 全自动部署与双向绑定完成！"
fi

# ---------------------------------------------------------------------------
# 6. 可选一键录入账号 (--add) / 一键换 IP (--set-ip) / 交互式向导 (--quickstart)
# ---------------------------------------------------------------------------
if [ -n "$ADD_RAW" ]; then
    ADD_ARGS=("$ADD_RAW")
    [ -n "$ADD_ALIAS" ] && ADD_ARGS+=("$ADD_ALIAS")
    [ -n "$FORCE_FLAG" ] && ADD_ARGS+=("$FORCE_FLAG")
    "$BIN_DST/cc-switch" add "${ADD_ARGS[@]}"
elif [ "$DO_SET_IP" -eq 1 ]; then
    SIP_ARGS=()
    [ -n "$SET_IP_ACC" ] && SIP_ARGS+=("$SET_IP_ACC")
    [ -n "$SET_IP_PROXY" ] && SIP_ARGS+=("$SET_IP_PROXY")
    [ -n "$FORCE_FLAG" ] && SIP_ARGS+=("$FORCE_FLAG")
    "$BIN_DST/cc-switch" set-ip ${SIP_ARGS[@]+"${SIP_ARGS[@]}"}
elif [ "$RUN_WIZARD" -eq 1 ]; then
    "$BIN_DST/cc-switch" init
else
    echo "------------------------------------------------------------------"
    echo "🚀 下一步快速开始 (若当前终端提示找不到命令，请先执行: source ~/.bashrc)："
    echo "   1. 交互向导 (加号/换IP) : cc-switch init      (或直接运行 ./quickstart.sh)"
    echo "   2. 安全添加新账号       : cc-switch add - acc1"
    echo "   3. 一键无损换 IP        : cc-switch set-ip acc1 -"
    echo "   4. 启动隔离会话         : cc-safe"
    echo "   5. 360° 防封防泄密实测  : cc-audit && cc-switch doctor"
    echo "------------------------------------------------------------------"
fi
