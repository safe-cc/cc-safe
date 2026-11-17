#!/usr/bin/env bash
# uninstall.sh — 卸载 cc-safe 脚本、停止隧道并清理 crontab (默认保留 ~/.claude-safe 账号数据，加 --purge 彻底清除)
set -euo pipefail

PURGE="${1:-}"

if [ -x "$HOME/.local/bin/cc-switch" ]; then
    "$HOME/.local/bin/cc-switch" kill-local >/dev/null 2>&1 || true
fi
if [ -x "$HOME/.local/bin/cc-us-tunnel" ]; then
    "$HOME/.local/bin/cc-us-tunnel" stop >/dev/null 2>&1 || true
fi

if command -v crontab >/dev/null 2>&1; then
    EXISTING="$(crontab -l 2>/dev/null || true)"
    if [ -n "$EXISTING" ]; then
        FILTERED="$(printf '%s\n' "$EXISTING" | grep -vE 'cc-us-tunnel start|cc-switch auto-sync' || true)"
        if [ -n "$FILTERED" ]; then
            printf '%s\n' "$FILTERED" | crontab - 2>/dev/null || true
        else
            crontab -r 2>/dev/null || true
        fi
    fi
fi

rm -f "$HOME/.local/bin"/{cc-switch,cc-safe,cc-us-tunnel,cc-totp,cc-check-ip,cc-audit,claude-sub2api}
rm -f "$HOME/.local/etc/proxychains.conf"

if [ "$PURGE" = "--purge" ]; then
    rm -rf "$HOME/.claude-safe"
    echo "🗑️  已卸载 cc-safe 并彻底清除 ~/.claude-safe。"
else
    echo "✅ 已卸载 cc-safe 可执行文件与定时任务（账号数据保留于 ~/.claude-safe，彻底删除可加 --purge）。"
fi
