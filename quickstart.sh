#!/usr/bin/env bash
# quickstart.sh — git clone 后的零门槛一键安装 + 交互式上号/换 IP/防封审计入口
# 用法:
#   ./quickstart.sh                            # 自动安装全部依赖 -> 直接打开交互菜单 (加号 / 换IP / 切号 / 审计)
#   ./quickstart.sh set-ip [别名] ['<新代理>'|-] # 自动安装/更新 -> 直接为指定账号无损换 IP (免重登)
#   ./quickstart.sh add ['<账号串>'|-] [别名]   # 自动安装/更新 -> 添加并激活新账号
#   ./quickstart.sh audit                      # 自动安装/更新 -> 运行 15 维 360° 真实抓包防泄漏实测
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SUBCMD="${1:-}"
case "$SUBCMD" in
    set-ip|change-ip|rotate-ip|set-proxy|update-proxy|huan-ip)
        shift
        bash "$REPO_DIR/install.sh"
        exec "$HOME/.local/bin/cc-switch" set-ip "$@"
        ;;
    add)
        shift
        bash "$REPO_DIR/install.sh"
        if [ $# -eq 0 ]; then
            exec "$HOME/.local/bin/cc-switch" add -
        else
            exec "$HOME/.local/bin/cc-switch" add "$@"
        fi
        ;;
    audit)
        shift
        bash "$REPO_DIR/install.sh"
        exec "$HOME/.local/bin/cc-audit" "$@"
        ;;
    status|doctor|kill|usage|reset|init)
        shift
        bash "$REPO_DIR/install.sh"
        exec "$HOME/.local/bin/cc-switch" "$SUBCMD" "$@"
        ;;
    -h|--help|help)
        cat <<'EOF'
🚀 cc-safe Quick Start 一键快速开始 (Clone 后即装即用)

用法:
  ./quickstart.sh                              一键装齐依赖 + 进入交互式管理向导 (添加账号 / 换 IP / 切号 / 双机同步 / 审计)
  ./quickstart.sh set-ip [账号] [新代理|-]     一键无损更换已有账号的静态住宅 IP (保留设备指纹与 OAuth 登录态免重登！)
  ./quickstart.sh add [- | '账号串'] [别名]    安全隐藏输入添加并激活新账号 (不留痕于 ~/.bash_history 或 ps aux)
  ./quickstart.sh status                       查看账号池、出口 IP、2FA 动态码与登录态
  ./quickstart.sh audit                        运行 15 维 360° 防封与防隐私泄漏真实验证套件
  ./quickstart.sh [install.sh 任意参数]        透传至 ./install.sh (如 --peer <IP> / --skip-claude / --no-cron)
EOF
        exit 0
        ;;
esac

# 若传入了 install.sh 的参数（如 --add / --set-ip / --peer / --no-cron 等），直接交由 install.sh 处理
if [ $# -gt 0 ]; then
    exec bash "$REPO_DIR/install.sh" "$@"
fi

# 无参数默认模式：若当前为交互式终端，一键部署后自动进入 cc-switch init 向导；非交互环境则仅执行幂等部署
if [ -t 0 ] && [ -t 1 ]; then
    exec bash "$REPO_DIR/install.sh" --quickstart
else
    exec bash "$REPO_DIR/install.sh"
fi
