#!/usr/bin/env bash
# uninstall.sh — 卸载 cc-safe 脚本、停止隧道、还原 shell alias 并清理 crontab (默认保留 ~/.claude-safe，加 --purge 彻底清除)
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

# 清理 ~/.bashrc / ~/.zshrc 中注册的 `alias claude=.../cc-safe` 防裸奔别名，避免卸载后 `claude` 报命令不存在
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import os, stat

home = os.path.expanduser("~")
for name in (".bashrc", ".zshrc"):
    rc = os.path.join(home, name)
    if not os.path.isfile(rc) or os.path.islink(rc):
        continue
    try:
        st_mode = stat.S_IMODE(os.stat(rc).st_mode)
        with open(rc, "r", encoding="utf-8", errors="surrogateescape") as rf:
            lines = rf.read().splitlines(True)
        out = []
        changed = False
        for ln in lines:
            s = ln.strip()
            if s.startswith("# cc-safe bare-claude guard") or (
                s.startswith("alias claude=") and ".local/bin/cc-safe" in s
            ):
                changed = True
                continue
            out.append(ln)
        if changed:
            tmp = rc + ".ccsafe.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, st_mode)
            with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.writelines(out)
            os.replace(tmp, rc)
    except Exception:
        pass
PY
fi

rm -f "$HOME/.local/bin"/{cc-switch,cc-safe,cc-us-tunnel,cc-totp,cc-check-ip,cc-audit,claude-sub2api}
rm -f "$HOME/.local/etc/proxychains.conf"

if [ "$PURGE" = "--purge" ]; then
    rm -rf "$HOME/.claude-safe"
    echo "🗑️  已卸载 cc-safe、还原 shell alias 并彻底清除 ~/.claude-safe。"
else
    echo "✅ 已卸载 cc-safe 可执行文件、还原 shell alias 与定时任务（账号数据保留于 ~/.claude-safe，彻底删除可加 --purge）。"
fi
