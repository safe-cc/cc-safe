#!/usr/bin/env python3
"""
cc_win_launcher.py — Native Windows Isolation Supervisor & Helper Suite for cc-safe
Provides five modes invoked by .cmd/.ps1 shims in %USERPROFILE%\\.local\\bin:
  1. safe    (cc-safe)        : Fail-Close dual-channel US residential IP check + isolated CLAUDE_CONFIG_DIR
                                + Windows NT Job Object (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) orphan containment
                                + Live 1s Gost tunnel kill-switch watchdog + non-expiring OAuth login watcher
  2. desktop (cc-desktop)     : Native Claude Desktop (Claude.exe MSIX/Squirrel) GUI isolation wrapper with
                                per-account ant-did (LOCALAPPDATA/APPDATA/--user-data-dir), forced proxy + remote DNS,
                                tray residual clean-sweep, and Live 1s Job Object kill-switch watchdog
  3. sub2api (claude-sub2api) : Physically separated relay launcher locked to %USERPROFILE%\\.claude
  4. totp    (cc-totp)        : 6-digit 2FA TOTP helper
  5. chrome  (cc-chrome)      : One-click isolated Chrome/Edge OAuth browser with remote-only DNS & QUIC disabled
"""
import ctypes
import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

IS_WINDOWS = os.name == "nt"
if IS_WINDOWS:
    from ctypes import wintypes

try:
    os.umask(0o077)
except Exception:
    pass

HOME = os.path.expanduser("~")
SAFE_DIR = os.path.abspath(os.environ.get("CC_SAFE_ROOT") or os.path.join(HOME, ".claude-safe"))
CFG_DIR = os.path.join(SAFE_DIR, "config")
LOCK_DIR = os.path.join(SAFE_DIR, "locks")
WIN_SESS_DIR = os.path.join(LOCK_DIR, "win_sessions")
SUB2_SESS_DIR = os.path.join(LOCK_DIR, "sub2api_sessions")
ACCOUNTS_FILE = os.path.join(CFG_DIR, "accounts.json")
TUNNEL_JSON = os.path.join(CFG_DIR, "us-tunnel.json")
TUNNEL_HASH_FILE = os.path.join(CFG_DIR, "us-tunnel.sha256")
LOCAL_BIN = os.path.join(HOME, ".local", "bin")


def _pop_env_ci(env_dict: dict, names):
    targets = {n.upper() for n in names}
    for k in [ek for ek in env_dict.keys() if ek.upper() in targets]:
        env_dict.pop(k, None)


def _get_env_ci(env_dict: dict, name: str, default: str = "") -> str:
    tu = name.upper()
    for k, v in env_dict.items():
        if k.upper() == tu:
            return v
    return default


def _build_claude_popen_cmd(claude_bin: str, extra_args: list):
    if IS_WINDOWS and claude_bin.lower().endswith((".cmd", ".bat")):
        comspec = os.environ.get("ComSpec") or os.path.join(os.environ.get("SystemRoot") or r"C:\Windows", "System32", "cmd.exe")
        inner = subprocess.list2cmdline([claude_bin, *extra_args])
        return f'"{comspec}" /d /s /c "{inner}"'
    return [claude_bin, *extra_args]

DEFAULT_HTTP_LISTEN = "127.0.0.1:7890"
DEFAULT_SOCKS_LISTEN = "127.0.0.1:7891"


def _get_tunnel_endpoints() -> tuple:
    http_l = DEFAULT_HTTP_LISTEN
    socks_l = DEFAULT_SOCKS_LISTEN
    if os.path.isfile(TUNNEL_JSON):
        try:
            with open(TUNNEL_JSON, "r", encoding="utf-8") as f:
                tj = json.load(f)
            if isinstance(tj, dict):
                http_l = str(tj.get("http_listen") or DEFAULT_HTTP_LISTEN).strip()
                socks_l = str(tj.get("socks_listen") or DEFAULT_SOCKS_LISTEN).strip()
        except Exception:
            pass
    return http_l, socks_l, f"http://{http_l}", f"socks5h://{socks_l}"


def _split_listen_addr(addr: str) -> tuple:
    a = (addr or "").strip()
    if a.startswith("[") and "]:" in a:
        rb = a.find("]")
        return a[1:rb], int(a[rb + 2 :])
    h, p = a.rsplit(":", 1)
    return h, int(p)


def _get_k32():
    k32 = ctypes.windll.kernel32
    if not getattr(_get_k32, "_configured", False):
        k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.GetProcessTimes.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
        ]
        k32.GetProcessTimes.restype = wintypes.BOOL
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.CloseHandle.restype = wintypes.BOOL
        k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        k32.CreateJobObjectW.restype = wintypes.HANDLE
        k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        k32.SetInformationJobObject.restype = wintypes.BOOL
        k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        k32.AssignProcessToJobObject.restype = wintypes.BOOL
        k32.QueryInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
        ]
        k32.QueryInformationJobObject.restype = wintypes.BOOL
        k32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        k32.TerminateJobObject.restype = wintypes.BOOL
        k32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        k32.TerminateProcess.restype = wintypes.BOOL
        k32.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        k32.QueryFullProcessImageNameW.restype = wintypes.BOOL
        k32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        k32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
        k32.Process32FirstW.restype = wintypes.BOOL
        k32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
        k32.Process32NextW.restype = wintypes.BOOL
        _get_k32._configured = True
    return k32


def _find_curl_bin() -> str:
    if IS_WINDOWS:
        sys_root = os.environ.get("SystemRoot") or r"C:\Windows"
        sys_curl = os.path.join(sys_root, "System32", "curl.exe")
        if os.path.isfile(sys_curl):
            return sys_curl
        return shutil.which("curl.exe") or "curl"
    return shutil.which("curl") or "curl"


def _is_desktop_gui_path(path: str) -> bool:
    low = (path or "").lower().replace("/", "\\")
    return "\\windowsapps\\" in low or "\\anthropicclaude\\" in low


def _auto_install_claude_via_proxy(proxy_http_url: str) -> str:
    if not IS_WINDOWS or not proxy_http_url:
        return ""
    import hashlib
    import platform as _plat

    mach = (_plat.machine() or "").lower()
    plat_key = "win32-arm64" if "arm" in mach else "win32-x64"
    base_url = "https://downloads.claude.ai/claude-code-releases"
    curl_bin = _find_curl_bin()
    os.makedirs(LOCAL_BIN, exist_ok=True)
    tmp_exe = os.path.join(SAFE_DIR, "runtime", f"claude_dl_{os.getpid()}.exe.tmp")
    os.makedirs(os.path.dirname(tmp_exe), exist_ok=True)
    print(f"⬇️  [CC-Guard] 检测到尚未安装 claude.exe，正在通过已核验美国专线 ({proxy_http_url}) 自动下载安装...", file=sys.stderr)
    try:
        cfg_ver = f'noproxy = ""\nproxy = "{_curl_esc_strict(proxy_http_url)}"\nurl = "{base_url}/latest"\n'
        r_ver = subprocess.run(
            [curl_bin, "--ssl-no-revoke", "-fsSL", "--noproxy", "", "--max-time", "12", "-K", "-"],
            input=cfg_ver,
            capture_output=True,
            text=True,
            timeout=16,
        )
        ver = (r_ver.stdout or "").strip()
        if not re.match(r"^\d+\.\d+\.\d+", ver):
            return ""
        cfg_man = f'noproxy = ""\nproxy = "{_curl_esc_strict(proxy_http_url)}"\nurl = "{base_url}/{ver}/manifest.json"\n'
        r_man = subprocess.run(
            [curl_bin, "--ssl-no-revoke", "-fsSL", "--noproxy", "", "--max-time", "15", "-K", "-"],
            input=cfg_man,
            capture_output=True,
            text=True,
            timeout=20,
        )
        manifest = json.loads(r_man.stdout or "{}")
        exp_sha = str((((manifest.get("platforms") or {}).get(plat_key)) or {}).get("checksum") or "").strip().lower()
        if not re.match(r"^[0-9a-f]{64}$", exp_sha):
            return ""
        cfg_bin = f'noproxy = ""\nproxy = "{_curl_esc_strict(proxy_http_url)}"\nurl = "{base_url}/{ver}/{plat_key}/claude.exe"\n'
        r_dl = subprocess.run(
            [curl_bin, "--ssl-no-revoke", "--retry", "2", "-fSL", "--noproxy", "", "-o", tmp_exe, "-K", "-"],
            input=cfg_bin,
            timeout=600,
        )
        if r_dl.returncode != 0 or not os.path.isfile(tmp_exe):
            return ""
        h = hashlib.sha256()
        with open(tmp_exe, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        if h.hexdigest().lower() != exp_sha:
            print("❌ [CC-Guard] claude.exe SHA-256 校验失败，已丢弃文件。", file=sys.stderr)
            return ""
        dst_exe = os.path.join(LOCAL_BIN, "claude.exe")
        os.replace(tmp_exe, dst_exe)
        print(f"✅ [CC-Guard] Claude Code CLI v{ver} 已通过美国专线自动安装完成: {dst_exe}", file=sys.stderr)
        return dst_exe
    except Exception as exc:
        print(f"⚠️  [CC-Guard] 自动下载 claude.exe 未成功: {exc}", file=sys.stderr)
        return ""
    finally:
        if os.path.exists(tmp_exe):
            try:
                os.remove(tmp_exe)
            except Exception:
                pass


def _find_claude_bin() -> str:
    env_override = os.environ.get("CLAUDE_BIN", "").strip()
    if env_override and os.path.isfile(env_override):
        return env_override

    candidates = []
    if IS_WINDOWS:
        for d in (
            LOCAL_BIN,
            os.path.join(os.environ.get("APPDATA", ""), "npm"),
            os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "claude-code"),
        ):
            if d:
                for nm in ("claude.exe", "claude.cmd"):
                    candidates.append(os.path.join(d, nm))
        for nm in ("claude.exe", "claude.cmd", "claude"):
            w = shutil.which(nm)
            if w and "cc-safe" not in os.path.basename(w).lower() and not _is_desktop_gui_path(w):
                candidates.append(w)
    else:
        candidates.append(os.path.join(LOCAL_BIN, "claude"))
        w = shutil.which("claude")
        if w:
            candidates.append(w)

    for c in candidates:
        if c and os.path.isfile(c) and not (IS_WINDOWS and _is_desktop_gui_path(c)):
            return c
    return ""


def _resolve_py_tool(name: str) -> str:
    self_dir = os.path.dirname(os.path.abspath(__file__))
    for cand in (
        os.path.join(SAFE_DIR, "libexec", "py", name),
        os.path.join(LOCAL_BIN, name),
        os.path.join(os.path.dirname(self_dir), "bin", name),
    ):
        if os.path.isfile(cand):
            return cand
    return os.path.join(LOCAL_BIN, name)


def _get_win_proc_create_time(pid: int) -> int:
    if not IS_WINDOWS:
        return 0
    try:
        k32 = _get_k32()
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not h:
            return 0
        try:
            ct = wintypes.FILETIME()
            et = wintypes.FILETIME()
            kt = wintypes.FILETIME()
            ut = wintypes.FILETIME()
            if k32.GetProcessTimes(h, ctypes.byref(ct), ctypes.byref(et), ctypes.byref(kt), ctypes.byref(ut)):
                return (int(ct.dwHighDateTime) << 32) | int(ct.dwLowDateTime)
        finally:
            k32.CloseHandle(h)
    except Exception:
        pass
    return 0


def _create_kill_on_close_job():
    """创建 Windows NT 内核作业对象 (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)，确保任何子孙/脱离进程 100% 随会话销毁。"""
    if not IS_WINDOWS:
        return None
    try:
        k32 = _get_k32()

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [
                ("ReadOperationCount", ctypes.c_ulonglong),
                ("WriteOperationCount", ctypes.c_ulonglong),
                ("OtherOperationCount", ctypes.c_ulonglong),
                ("ReadTransferCount", ctypes.c_ulonglong),
                ("WriteTransferCount", ctypes.c_ulonglong),
                ("OtherTransferCount", ctypes.c_ulonglong),
            ]

        class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
                ("IoInfo", IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        h_job = k32.CreateJobObjectW(None, None)
        if not h_job:
            return None

        info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (0x2000) | JOB_OBJECT_LIMIT_BREAKAWAY_OK Disabled (default 0)
        info.BasicLimitInformation.LimitFlags = 0x2000
        JobObjectExtendedLimitInformation = 9
        ok = k32.SetInformationJobObject(
            h_job,
            JobObjectExtendedLimitInformation,
            ctypes.byref(info),
            ctypes.sizeof(info),
        )
        if not ok:
            k32.CloseHandle(h_job)
            return None
        return h_job
    except Exception:
        return None


def _assign_pid_to_job(h_job, pid: int):
    if not IS_WINDOWS or not h_job:
        return
    try:
        k32 = _get_k32()
        PROCESS_SET_QUOTA = 0x0100
        PROCESS_TERMINATE = 0x0001
        hp = k32.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, int(pid))
        if hp:
            try:
                k32.AssignProcessToJobObject(h_job, hp)
            finally:
                k32.CloseHandle(hp)
    except Exception:
        pass


def _get_job_active_processes(h_job) -> int:
    if not IS_WINDOWS or not h_job:
        return 0
    try:
        class JOBOBJECT_BASIC_ACCOUNTING_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("TotalUserTime", ctypes.c_longlong),
                ("TotalKernelTime", ctypes.c_longlong),
                ("ThisPeriodTotalUserTime", ctypes.c_longlong),
                ("ThisPeriodTotalKernelTime", ctypes.c_longlong),
                ("TotalPageFaultCount", wintypes.DWORD),
                ("TotalProcesses", wintypes.DWORD),
                ("ActiveProcesses", wintypes.DWORD),
                ("TotalTerminatedProcesses", wintypes.DWORD),
            ]

        acct = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION()
        ret_len = wintypes.DWORD(0)
        JobObjectBasicAccountingInformation = 1
        if _get_k32().QueryInformationJobObject(
            h_job,
            JobObjectBasicAccountingInformation,
            ctypes.byref(acct),
            ctypes.sizeof(acct),
            ctypes.byref(ret_len),
        ):
            return int(acct.ActiveProcesses)
    except Exception:
        pass
    return 0


def _terminate_job(h_job, exit_code: int = 1):
    if not IS_WINDOWS or not h_job:
        return
    try:
        _get_k32().TerminateJobObject(h_job, int(exit_code))
    except Exception:
        pass


def _close_job(h_job):
    if not IS_WINDOWS or not h_job:
        return
    try:
        _get_k32().CloseHandle(h_job)
    except Exception:
        pass


def _curl_esc_strict(s: str) -> str:
    val = s or ""
    if any(c in val for c in ("\r", "\n", "\x00")):
        raise ValueError("illegal control character")
    return val.replace("\\", "\\\\").replace('"', '\\"')


def _probe_trace(proxy_url: str, timeout: int = 6) -> dict:
    curl_bin = _find_curl_bin()
    cfg_stdin = (
        'noproxy = ""\n'
        f'proxy = "{_curl_esc_strict(proxy_url)}"\n'
        'url = "https://api.anthropic.com/cdn-cgi/trace"\n'
    )
    try:
        curl_cmd = [curl_bin, "-s", "--noproxy", "", "--max-time", str(timeout)]
        if IS_WINDOWS:
            curl_cmd.append("--ssl-no-revoke")
        curl_cmd += ["-K", "-"]
        res = subprocess.run(
            curl_cmd,
            input=cfg_stdin,
            capture_output=True,
            text=True,
            timeout=timeout + 3,
        )
    except Exception:
        return {}
    out = {}
    for ln in res.stdout.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def _read_active_meta() -> dict:
    if not os.path.isfile(ACCOUNTS_FILE):
        return {"ok": False, "missing": True, "err": ""}
    try:
        with open(ACCOUNTS_FILE, "r", encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("root is not JSON object")
    except Exception as e:
        return {"ok": False, "missing": False, "err": f"配置文件损坏: {e}"}

    ak = str(d.get("active") or "").strip()
    accounts = d.get("accounts") or {}
    acc = accounts.get(ak) if isinstance(accounts, dict) else None
    if not ak or not isinstance(acc, dict):
        return {"ok": False, "missing": False, "err": ""}

    email = str(acc.get("email") or "").strip()
    git_user = re.sub(r"[^a-zA-Z0-9._-]", "", (email.split("@")[0] if "@" in email else ak)) or ak
    git_email = re.sub(r"[\r\n\x00\"'\\]", "", email) if "@" in email else f"{ak}@users.noreply.github.com"
    tz = str(acc.get("tz") or "").strip() or "America/New_York"
    return {
        "ok": True,
        "account": ak,
        "status": str(acc.get("status") or "active").strip(),
        "ip": str(acc.get("ip") or "").strip(),
        "tz": tz,
        "git_user": git_user,
        "git_email": git_email,
    }


def _port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.4):
            return True
    except Exception:
        return False


def _write_session_marker(sess_dir: str, payload: dict) -> str:
    os.makedirs(sess_dir, mode=0o700, exist_ok=True)
    p = os.path.join(sess_dir, f"{os.getpid()}.json")
    try:
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f)
    except Exception:
        pass
    return p


def _remove_file_quiet(p: str):
    if p and os.path.exists(p):
        try:
            os.remove(p)
        except Exception:
            pass


def run_safe(claude_args: list) -> int:
    meta = _read_active_meta()
    if meta.get("missing"):
        print(f"❌ [CC-Guard] 未找到账号配置文件: {ACCOUNTS_FILE}", file=sys.stderr)
        print("   请先运行: cc-switch init  (或双击 quickstart.cmd)", file=sys.stderr)
        return 1
    if meta.get("err"):
        print(f"❌ [CC-Guard 熔断] 无法解析 {ACCOUNTS_FILE} ({meta['err']})", file=sys.stderr)
        return 1
    if not meta.get("ok") or not meta.get("account"):
        print("❌ [CC-Guard] 当前未激活任何账号！请运行 `cc-switch init` 或 `cc-switch status`。", file=sys.stderr)
        return 1

    active_acc = meta["account"]
    if meta["status"] == "banned":
        print(f"🚫 [CC-Guard 熔断] 当前账号 [{active_acc}] 已标记为封禁 (banned)，严禁启动！", file=sys.stderr)
        print("👉 请运行 `cc-switch <可用账号>` 切换，或运行 `cc-switch init` 添加新账号。", file=sys.stderr)
        return 1

    expected_ip = meta["ip"]
    if not expected_ip or expected_ip == "未知":
        print(f"❌ [CC-Guard 熔断] 账号 [{active_acc}] 未绑定明确的静态住宅 EXPECTED_IP，拒绝启动！", file=sys.stderr)
        return 1

    sw_py = _resolve_py_tool("cc-switch")
    tun_py = _resolve_py_tool("cc-us-tunnel")

    clean_helper_env = dict(os.environ)
    _pop_env_ci(clean_helper_env, ("CC_SAFE_MANAGED", "CC_SAFE_ACCOUNT", "NO_PROXY"))
    if os.path.isfile(tun_py):
        rc_tun = subprocess.run([sys.executable, tun_py, "ensure"], env=clean_helper_env).returncode
        if rc_tun != 0:
            print("❌ [CC-Guard 熔断] 本地美国家宽隧道启动失败，请运行 `cc-us-tunnel status` 排查！", file=sys.stderr)
            return 1

    http_listen, socks_listen, proxy_http_url, proxy_socks_url = _get_tunnel_endpoints()
    h_host, h_port = _split_listen_addr(http_listen)
    s_host, s_port = _split_listen_addr(socks_listen)

    print(f"🔍 [CC-Guard] 正在核验账号 [{active_acc}] 专属隧道 (HTTP+SOCKS5h -> {expected_ip})...")
    tr_h = _probe_trace(proxy_http_url, timeout=6)
    if tr_h.get("loc") != "US" or not tr_h.get("ip"):
        print(f"❌ [严重警告] HTTP 代理链路异常或非美国出口 (LOC={tr_h.get('loc') or '超时'}, IP={tr_h.get('ip') or '无'})！", file=sys.stderr)
        print("🛑 已熔断阻断启动，防止本机真实 IP 暴露。", file=sys.stderr)
        return 1
    if tr_h.get("ip") != expected_ip:
        print(f"❌ [严重警告] HTTP 出口 IP ({tr_h.get('ip')}) 与账号 [{active_acc}] 绑定 IP ({expected_ip}) 不一致！", file=sys.stderr)
        print(f"🛑 已熔断阻断启动，严防跨号串 IP！请运行 `cc-switch {active_acc}` 修复。", file=sys.stderr)
        return 1

    tr_s = _probe_trace(proxy_socks_url, timeout=6)
    if tr_s.get("loc") != "US" or tr_s.get("ip") != expected_ip:
        print(
            f"❌ [严重警告] SOCKS5h 隧道出口异常 (LOC={tr_s.get('loc') or '超时'}, IP={tr_s.get('ip') or '无'}, 绑定={expected_ip})！",
            file=sys.stderr,
        )
        return 1

    claude_bin = _find_claude_bin()
    if not claude_bin and IS_WINDOWS and not os.environ.get("CLAUDE_BIN", "").strip():
        claude_bin = _auto_install_claude_via_proxy(proxy_http_url)
    if not claude_bin:
        print("❌ [CC-Guard] 未找到 Claude Code CLI (claude.exe)，请重新运行 .\\install.ps1 自动安装。", file=sys.stderr)
        return 1

    prof_dir = os.path.join(SAFE_DIR, "profiles", active_acc)
    prof_home = os.path.join(prof_dir, "home")
    cred_path = os.path.join(prof_home, ".credentials.json")

    if os.path.isfile(sw_py):
        subprocess.run(
            [sys.executable, sw_py, "apply-local", active_acc, "--if-idle"],
            env=clean_helper_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        bg_flags = (subprocess.CREATE_NO_WINDOW | subprocess.DETACHED_PROCESS) if IS_WINDOWS else 0
        try:
            subprocess.Popen(
                [sys.executable, sw_py, "auto-sync"],
                env=clean_helper_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=bg_flags,
            )
        except Exception:
            pass

    recheck = _read_active_meta()
    if (
        not recheck.get("ok")
        or recheck.get("account") != active_acc
        or recheck.get("status") == "banned"
        or recheck.get("ip") != expected_ip
    ):
        print("🛑 [CC-Guard 熔断] 启动期间检测到账号/IP 状态变更，已中止启动！", file=sys.stderr)
        return 1

    print(f"✅ [核验通过] 账号: {active_acc} | 专属目录: ~/.claude-safe/profiles/{active_acc}/home")
    print(f"   出口 IP: {expected_ip} (HTTP & SOCKS5h 双通道 US 一致) | 机房: {tr_h.get('colo','')} | 时区: {meta['tz']}")

    run_env = dict(os.environ)
    _pop_env_ci(
        run_env,
        (
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_CUSTOM_HEADERS",
            "BROWSER",
            "CLAUDE_SUB2API_MANAGED",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_ENABLE_TELEMETRY",
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "OTEL_EXPORTER_OTLP_HEADERS",
            "CLAUDE_CODE_ORGANIZATION_UUID",
            "CLAUDE_CODE_ACCOUNT_UUID",
            "CLAUDE_CODE_HARBOR_KITE_CLOUD",
            "DBUS_SESSION_BUS_ADDRESS",
            "FTP_PROXY",
            "RSYNC_PROXY",
            "GIT_CONFIG_COUNT",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_SYSTEM",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "ALL_PROXY",
            "GRPC_PROXY",
            "NO_PROXY",
        ),
    )

    if _get_env_ci(run_env, "CC_SAFE_KEEP_HOST_TOKENS") != "1":
        _pop_env_ci(
            run_env,
            (
                "GH_TOKEN",
                "GITHUB_TOKEN",
                "GH_ENTERPRISE_TOKEN",
                "GITLAB_TOKEN",
                "GLAB_TOKEN",
                "SSH_CONNECTION",
                "SSH_CLIENT",
                "SSH_TTY",
                "TMUX",
                "TMUX_PANE",
                "AWS_ACCESS_KEY_ID",
                "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN",
                "AWS_PROFILE",
                "AZURE_CONFIG_DIR",
                "GOOGLE_APPLICATION_CREDENTIALS",
                "CLOUDSDK_CONFIG",
            ),
        )
        gh_dir = os.path.join(prof_home, ".config", "gh")
        os.makedirs(gh_dir, exist_ok=True)
        run_env["GH_CONFIG_DIR"] = gh_dir

    prof_appdata = os.path.join(prof_home, "AppData", "Roaming")
    prof_localappdata = os.path.join(prof_home, "AppData", "Local")
    prof_xdg_cfg = os.path.join(prof_home, ".config")
    prof_xdg_cache = os.path.join(prof_home, ".cache")
    prof_xdg_state = os.path.join(prof_home, ".local", "state")
    for _iso_d in (prof_home, prof_appdata, prof_localappdata, prof_xdg_cfg, prof_xdg_cache, prof_xdg_state):
        os.makedirs(_iso_d, exist_ok=True)
    _pop_env_ci(run_env, ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"))

    libexec_dir = os.path.join(SAFE_DIR, "libexec")
    cur_path = _get_env_ci(run_env, "PATH")
    _pop_env_ci(run_env, ("PATH",))
    run_env["PATH"] = (libexec_dir + os.pathsep + cur_path) if os.path.isdir(libexec_dir) else cur_path

    gitconfig_p = os.path.join(prof_dir, "gitconfig")
    _pop_env_ci(
        run_env,
        ("GIT_CONFIG_GLOBAL", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"),
    )
    if os.path.isfile(gitconfig_p):
        run_env["GIT_CONFIG_GLOBAL"] = gitconfig_p
        run_env["GIT_AUTHOR_NAME"] = meta["git_user"]
        run_env["GIT_AUTHOR_EMAIL"] = meta["git_email"]
        run_env["GIT_COMMITTER_NAME"] = meta["git_user"]
        run_env["GIT_COMMITTER_EMAIL"] = meta["git_email"]
        run_env["EMAIL"] = meta["git_email"]

    run_env.update(
        {
            "HOME": prof_home,
            "USERPROFILE": prof_home,
            "APPDATA": prof_appdata,
            "LOCALAPPDATA": prof_localappdata,
            "XDG_CONFIG_HOME": prof_xdg_cfg,
            "XDG_CACHE_HOME": prof_xdg_cache,
            "XDG_STATE_HOME": prof_xdg_state,
            "CC_SAFE_MANAGED": "1",
            "CC_SAFE_ACCOUNT": active_acc,
            "CC_SAFE_ROOT": SAFE_DIR,
            "CLAUDE_CONFIG_DIR": prof_home,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": prof_home,
            "ANTHROPIC_CONFIG_DIR": prof_home,
            "GIT_CONFIG_NOSYSTEM": "1",
            "TZ": meta["tz"],
            "HTTPS_PROXY": proxy_http_url,
            "https_proxy": proxy_http_url,
            "HTTP_PROXY": proxy_http_url,
            "http_proxy": proxy_http_url,
            "ALL_PROXY": proxy_socks_url,
            "all_proxy": proxy_socks_url,
            "GRPC_PROXY": proxy_http_url,
            "grpc_proxy": proxy_http_url,
            "NO_PROXY": "localhost,127.0.0.1,::1",
            "no_proxy": "localhost,127.0.0.1,::1",
            "NODE_OPTIONS": "--dns-result-order=ipv4first",
            "BUN_FEATURE_FLAG_DISABLE_IPV6": "1",
            "DISABLE_TELEMETRY": "1",
            "DO_NOT_TRACK": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_GROWTHBOOK": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
        }
    )

    h_job = _create_kill_on_close_job()
    stop_evt = threading.Event()
    synced_once = threading.Event()
    need_watch = (not os.path.exists(cred_path) or os.path.getsize(cred_path) <= 20) and os.path.isfile(sw_py)
    initial_tunnel_hash = None
    if os.path.isfile(TUNNEL_HASH_FILE):
        try:
            initial_tunnel_hash = open(TUNNEL_HASH_FILE, "r", encoding="utf-8").read().strip()
        except Exception:
            initial_tunnel_hash = None

    def _sync_cred_once():
        if synced_once.is_set():
            return
        synced_once.set()
        subprocess.run(
            [sys.executable, sw_py, "sync-cred", active_acc, "--quiet"],
            env=clean_helper_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )

    def _cred_watcher():
        while not stop_evt.wait(1.0):
            try:
                if os.path.exists(cred_path) and os.path.getsize(cred_path) > 20:
                    time.sleep(1.2)
                    _sync_cred_once()
                    return
            except Exception:
                pass

    cmd_exec = _build_claude_popen_cmd(claude_bin, claude_args)
    proc = subprocess.Popen(cmd_exec, env=run_env)
    _assign_pid_to_job(h_job, proc.pid)

    marker_file = _write_session_marker(
        WIN_SESS_DIR,
        {
            "pid": os.getpid(),
            "create_time": _get_win_proc_create_time(os.getpid()),
            "claude_pid": proc.pid,
            "claude_create_time": _get_win_proc_create_time(proc.pid),
            "account": active_acc,
            "safe_root": SAFE_DIR,
        },
    )

    # 实时断流熔断看门狗 (Kill-Switch): 若运行期间 Gost 端口断开、隧道配置停用/变更或账号被切走/封禁，立即销毁整个 Job Object！
    def _live_killswitch():
        fail_streak = 0
        while not stop_evt.wait(1.0):
            if proc.poll() is not None:
                return
            m_now = _read_active_meta()
            if (
                not m_now.get("ok")
                or m_now.get("account") != active_acc
                or m_now.get("status") == "banned"
                or m_now.get("ip") != expected_ip
            ):
                print("\n🛑 [CC-Guard 实时熔断] 检测到当前账号已被切换或封禁，立即终止会话进程树！", file=sys.stderr)
                _terminate_job(h_job, 1)
                try:
                    proc.kill()
                except Exception:
                    pass
                return
            if initial_tunnel_hash is not None:
                cur_hash = None
                try:
                    if os.path.isfile(TUNNEL_HASH_FILE):
                        cur_hash = open(TUNNEL_HASH_FILE, "r", encoding="utf-8").read().strip()
                except Exception:
                    cur_hash = None
                if cur_hash != initial_tunnel_hash:
                    print("\n🛑 [CC-Guard 实时熔断] 检测到本地专线隧道已停用或切换，立即终止会话严防串流泄漏！", file=sys.stderr)
                    _terminate_job(h_job, 1)
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    return
            if not (_port_open(h_host, h_port) and _port_open(s_host, s_port)):
                fail_streak += 1
                if fail_streak >= 2:
                    print("\n🛑 [CC-Guard 实时熔断] 检测到本地 Gost 专线端口意外断开，立即阻断会话严防直连暴露！", file=sys.stderr)
                    _terminate_job(h_job, 1)
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    return
            else:
                fail_streak = 0

    watcher_t = None
    if need_watch:
        watcher_t = threading.Thread(target=_cred_watcher, daemon=True)
        watcher_t.start()
    threading.Thread(target=_live_killswitch, daemon=True).start()

    try:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
    except Exception:
        pass

    try:
        rc = proc.wait()
    finally:
        stop_evt.set()
        if watcher_t is not None:
            watcher_t.join(timeout=3.0)
        if need_watch and not synced_once.is_set() and os.path.exists(cred_path) and os.path.getsize(cred_path) > 20:
            try:
                _sync_cred_once()
            except Exception:
                pass
        _remove_file_quiet(marker_file)
        _terminate_job(h_job, 0)
        _close_job(h_job)

    return rc


def run_sub2api(claude_args: list) -> int:
    claude_bin = _find_claude_bin()
    if not claude_bin:
        print("❌ [claude-sub2api] 未找到 Claude Code CLI (claude.exe)，请先运行 .\\install.ps1。", file=sys.stderr)
        return 1

    sub2_dir = os.path.join(HOME, ".claude")
    os.makedirs(sub2_dir, exist_ok=True)
    settings_p = os.path.join(sub2_dir, "sub2api.settings.json")
    if not os.path.isfile(settings_p):
        print(f"❌ [claude-sub2api] 缺少中转配置文件: {settings_p}", file=sys.stderr)
        return 1
    try:
        raw_st = open(settings_p, "r", encoding="utf-8").read()
        json.loads(raw_st)
    except Exception as e:
        print(f"❌ [claude-sub2api] 中转配置文件 JSON 格式损坏 ({settings_p}): {e}", file=sys.stderr)
        return 1
    if "sk-REPLACE_WITH_YOUR_RELAY_KEY" in raw_st:
        print(f"⚠️  [claude-sub2api] 请先编辑 {settings_p} 填入真实的中转 API Key！", file=sys.stderr)
        return 1

    env = dict(os.environ)
    blocked_dirs = {
        os.path.normcase(os.path.abspath(os.path.join(SAFE_DIR, "libexec"))),
        os.path.normcase(os.path.abspath(os.path.join(SAFE_DIR, "bin"))),
    }
    cur_path = _get_env_ci(env, "PATH")
    clean_parts = [
        p for p in cur_path.split(os.pathsep) if p and os.path.normcase(os.path.abspath(p)) not in blocked_dirs
    ]
    _pop_env_ci(
        env,
        (
            "PATH",
            "HOME",
            "USERPROFILE",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "ALL_PROXY",
            "GRPC_PROXY",
            "NO_PROXY",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_CUSTOM_HEADERS",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "GIT_CONFIG_GLOBAL",
            "CC_SAFE_MANAGED",
            "CC_SAFE_ACCOUNT",
            "CC_SAFE_ROOT",
        ),
    )
    env["PATH"] = os.pathsep.join(clean_parts)
    env["HOME"] = sub2_dir
    env["USERPROFILE"] = sub2_dir
    env["CLAUDE_SUB2API_MANAGED"] = "1"
    env["CLAUDE_CONFIG_DIR"] = sub2_dir
    env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = sub2_dir
    env["ANTHROPIC_CONFIG_DIR"] = sub2_dir

    cmd_exec = _build_claude_popen_cmd(claude_bin, ["--settings", settings_p, *claude_args])
    proc = subprocess.Popen(cmd_exec, env=env)
    marker = _write_session_marker(
        SUB2_SESS_DIR,
        {"pid": os.getpid(), "create_time": _get_win_proc_create_time(os.getpid()), "claude_pid": proc.pid},
    )
    try:
        try:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
        except Exception:
            pass
        return proc.wait()
    finally:
        _remove_file_quiet(marker)


def _find_chromium_bin() -> str:
    pf = os.environ.get("ProgramFiles", r"C:\Program Files")
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    lad = os.environ.get("LOCALAPPDATA", "")
    cands = [
        os.path.join(pf, "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(pf86, "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(lad, "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(pf, "Microsoft", "Edge", "Application", "msedge.exe"),
        os.path.join(pf86, "Microsoft", "Edge", "Application", "msedge.exe"),
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return shutil.which("chrome.exe") or shutil.which("msedge.exe") or ""


def run_chrome(args: list) -> int:
    if not os.path.isfile(ACCOUNTS_FILE):
        print("❌ 未找到 accounts.json，请先运行 `cc-switch init` 添加账号。", file=sys.stderr)
        return 1
    try:
        with open(ACCOUNTS_FILE, "r", encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("root is not JSON object")
    except Exception as e:
        print(f"❌ 读取 accounts.json 失败: {e}", file=sys.stderr)
        return 1
    accs = d.get("accounts") or {}
    raw_target = (args[0] if args else d.get("active", "")).strip()
    target = raw_target
    if target and target not in accs and "@" in target:
        for k_cand, v_cand in accs.items():
            if isinstance(v_cand, dict) and str(v_cand.get("email") or "").strip().lower() == target.lower():
                target = k_cand
                break
    if not target or target not in accs:
        print(f"❌ 未找到目标账号 '{raw_target}'。用法: cc-chrome [账号别名或邮箱]", file=sys.stderr)
        return 1
    if d.get("active") != target:
        print(f"⚠️  账号 [{target}] 当前未激活！请先运行 `cc-switch {target}` 切换专线后再打开同源浏览器。", file=sys.stderr)
        return 1
    acc = accs[target]
    if acc.get("status") == "banned":
        print(f"🚫 账号 [{target}] 已处于封禁熔断状态，拒绝打开浏览器！", file=sys.stderr)
        return 1

    clean_helper_env = dict(os.environ)
    _pop_env_ci(clean_helper_env, ("CC_SAFE_MANAGED", "CC_SAFE_ACCOUNT", "NO_PROXY"))
    tun_py = _resolve_py_tool("cc-us-tunnel")
    if os.path.isfile(tun_py):
        if subprocess.run([sys.executable, tun_py, "ensure"], env=clean_helper_env).returncode != 0:
            print("❌ 本地美国家宽隧道启动失败！", file=sys.stderr)
            return 1

    http_l, _, proxy_http_url, _ = _get_tunnel_endpoints()
    h_host, _ = _split_listen_addr(http_l)
    expected_ip = str(acc.get("ip") or "").strip()
    if not expected_ip:
        print(f"❌ [Fail-Close] 账号 [{target}] 未绑定 EXPECTED_IP，已阻断浏览器启动！", file=sys.stderr)
        return 1
    tr = _probe_trace(proxy_http_url, timeout=6)
    if tr.get("ip") != expected_ip or tr.get("loc") != "US":
        print(
            f"❌ [Fail-Close] 浏览器出口核验未通过 (实际={tr.get('ip')} / {tr.get('loc')}, 绑定={expected_ip})！已阻断启动。",
            file=sys.stderr,
        )
        return 1

    browser = os.environ.get("CC_CHROME_BIN", "").strip() or _find_chromium_bin()
    if not browser or not os.path.isfile(browser):
        print(f"❌ 未检测到 Chrome 或 Edge 浏览器，请手动使用 --proxy-server={proxy_http_url} 启动浏览器。", file=sys.stderr)
        return 1

    profile_dir = os.path.join(SAFE_DIR, "profiles", target, "browser-profile")
    os.makedirs(profile_dir, mode=0o700, exist_ok=True)
    excl_hosts = "EXCLUDE 127.0.0.1 , EXCLUDE localhost"
    if h_host not in ("127.0.0.1", "localhost"):
        excl_hosts += f" , EXCLUDE {h_host}"
    # 强制浏览器所有域名走代理远端解析 (阻断本地 DNS 泄漏) 并禁用 QUIC (阻断 UDP WebRTC/QUIC 直连旁路)
    b_args = [
        browser,
        f"--user-data-dir={profile_dir}",
        f"--proxy-server={proxy_http_url}",
        f"--host-resolver-rules=MAP * ~NOTFOUND , {excl_hosts}",
        "--disable-quic",
        "--no-first-run",
        "https://claude.ai",
    ]
    p_flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) if IS_WINDOWS else 0
    subprocess.Popen(b_args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=p_flags)
    print(f"🌐 已启动账号 [{target}] 专属隔离浏览器 (同源美国出口 IP: {expected_ip} | 远端 DNS + 禁用 QUIC)！")
    print(f"   浏览器数据目录: {profile_dir}")
    print("   ⚠️ 完成登录或切号前请关闭此浏览器窗口。")
    return 0


def _find_claude_desktop_bin() -> str:
    env_override = os.environ.get("CC_DESKTOP_BIN", "").strip()
    if env_override and os.path.isfile(env_override):
        return env_override
    if not IS_WINDOWS:
        return ""

    cands = []
    # 1. MSIX / Store 安装包 (优先定位真实 <InstallLocation>\app\Claude.exe，绕过 WindowsApps 单实例转发桩)
    try:
        ps = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                '(Get-AppxPackage -Name "*Claude*" | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation',
            ],
            capture_output=True,
            text=True,
            timeout=12,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        iloc = (ps.stdout or "").strip()
        if iloc and os.path.isdir(iloc):
            cands.append(os.path.join(iloc, "app", "Claude.exe"))
            cands.append(os.path.join(iloc, "Claude.exe"))
    except Exception:
        pass

    pf = os.environ.get("ProgramFiles", r"C:\Program Files")
    for g in sorted(glob.glob(os.path.join(pf, "WindowsApps", "Claude_*", "app", "Claude.exe")), reverse=True):
        cands.append(g)

    # 2. Squirrel / 独立 EXE 安装包 (优先定位 app-<ver>\claude.exe 主进程二进制，避免 Update.exe 桩脱离作业对象)
    lad = os.environ.get("LOCALAPPDATA", "")
    if lad:
        squirrel_apps = sorted(
            glob.glob(os.path.join(lad, "AnthropicClaude", "app-*", "claude.exe"))
            + glob.glob(os.path.join(lad, "AnthropicClaude", "app-*", "Claude.exe")),
            reverse=True,
        )
        cands.extend(squirrel_apps)
        cands.append(os.path.join(lad, "AnthropicClaude", "claude.exe"))
        cands.append(os.path.join(lad, "Programs", "Claude", "Claude.exe"))
        cands.append(os.path.join(lad, "Microsoft", "WindowsApps", "Claude.exe"))

    cands.append(os.path.join(pf, "Claude", "Claude.exe"))
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return ""


def _kill_unmanaged_desktop_procs(exclude_pids: set = None) -> int:
    """启动隔离桌面端前，清理后台/系统托盘中残留的裸跑或异号 Claude.exe 桌面端进程，防止单实例锁与 claude:// 串号。"""
    if not IS_WINDOWS or os.environ.get("CC_AUDIT_SANDBOX") == "1":
        return 0
    excl = set(exclude_pids or ())
    excl.add(os.getpid())
    killed = 0
    try:
        k32 = _get_k32()
        TH32CS_SNAPPROCESS = 0x00000002
        INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

        class PROCESSENTRY32W(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        pids_to_kill = []
        snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if snap and snap != INVALID_HANDLE_VALUE:
            try:
                pe = PROCESSENTRY32W()
                pe.dwSize = ctypes.sizeof(PROCESSENTRY32W)
                if k32.Process32FirstW(snap, ctypes.byref(pe)):
                    while True:
                        pid = int(pe.th32ProcessID)
                        if pid not in excl and pe.szExeFile.lower() == "claude.exe":
                            hp = k32.OpenProcess(0x1000, False, pid)
                            if hp:
                                try:
                                    buf = ctypes.create_unicode_buffer(1024)
                                    sz = wintypes.DWORD(1024)
                                    if k32.QueryFullProcessImageNameW(hp, 0, buf, ctypes.byref(sz)):
                                        low_img = buf.value.lower().replace("/", "\\")
                                        if (
                                            "\\windowsapps\\claude" in low_img
                                            or "\\anthropicclaude\\" in low_img
                                            or "\\programs\\claude\\" in low_img
                                        ):
                                            pids_to_kill.append(pid)
                                finally:
                                    k32.CloseHandle(hp)
                        if not k32.Process32NextW(snap, ctypes.byref(pe)):
                            break
            finally:
                k32.CloseHandle(snap)

        for pid in pids_to_kill:
            hp = k32.OpenProcess(0x0001, False, pid)
            if hp:
                try:
                    if k32.TerminateProcess(hp, 1):
                        killed += 1
                finally:
                    k32.CloseHandle(hp)
        if killed:
            time.sleep(0.4)
    except Exception:
        pass
    return killed


def _count_live_win_sessions(exclude_account: str = "") -> tuple:
    """统计 WIN_SESS_DIR 中当前仍存活的受管会话数与所属账号集合 (支持 NT CreateTime 防 PID 复用误判)。"""
    alive_cnt = 0
    alive_accs = set()
    if not os.path.isdir(WIN_SESS_DIR):
        return 0, alive_accs
    for fn in os.listdir(WIN_SESS_DIR):
        if not fn.endswith(".json"):
            continue
        fp = os.path.join(WIN_SESS_DIR, fn)
        try:
            info = json.load(open(fp, "r", encoding="utf-8"))
        except Exception:
            continue
        acc_name = str(info.get("account") or "").strip()
        if exclude_account and acc_name == exclude_account:
            continue
        pid = int(info.get("pid") or 0)
        exp_ct = int(info.get("create_time") or 0)
        if pid <= 0 or pid == os.getpid():
            continue
        is_live = False
        if IS_WINDOWS:
            cur_ct = _get_win_proc_create_time(pid)
            is_live = cur_ct > 0 and (exp_ct == 0 or cur_ct == exp_ct)
        else:
            try:
                os.kill(pid, 0)
                is_live = True
            except OSError:
                is_live = False
        if is_live:
            alive_cnt += 1
            if acc_name:
                alive_accs.add(acc_name)
    return alive_cnt, alive_accs


def run_desktop(args: list) -> int:
    if not os.path.isfile(ACCOUNTS_FILE):
        print("❌ [CC-Desktop] 未找到 accounts.json，请先运行 `cc-switch init` 添加账号。", file=sys.stderr)
        return 1
    try:
        with open(ACCOUNTS_FILE, "r", encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("root is not JSON object")
    except Exception as e:
        print(f"❌ [CC-Desktop] 读取 accounts.json 失败: {e}", file=sys.stderr)
        return 1

    accs = d.get("accounts") or {}
    no_chrome_hint = "--no-chrome" in args
    force_switch = "--switch" in args
    filtered_args = [a for a in args if a not in ("--no-chrome", "--switch")]

    extra_electron_args = []
    if filtered_args and not filtered_args[0].startswith("-"):
        raw_target = filtered_args[0].strip()
        extra_electron_args = filtered_args[1:]
    else:
        raw_target = str(d.get("active") or "").strip()
        extra_electron_args = filtered_args

    target = raw_target
    if target and target not in accs and "@" in target:
        for k_cand, v_cand in accs.items():
            if isinstance(v_cand, dict) and str(v_cand.get("email") or "").strip().lower() == target.lower():
                target = k_cand
                break

    if not target or target not in accs:
        print(f"❌ [CC-Desktop] 未找到目标账号 '{raw_target}'。用法: cc-desktop [账号别名或邮箱] [--switch]", file=sys.stderr)
        return 1

    target_cfg = accs[target] if isinstance(accs.get(target), dict) else {}
    if target_cfg.get("status") == "banned":
        print(f"🚫 [CC-Desktop 熔断] 账号 [{target}] 已处于封禁 (banned) 状态，严禁启动桌面客户端！", file=sys.stderr)
        return 1
    if not str(target_cfg.get("ip") or "").strip() or str(target_cfg.get("ip")).strip() == "未知":
        print(f"❌ [CC-Desktop 熔断] 账号 [{target}] 未绑定 EXPECTED_IP，拒绝启动！", file=sys.stderr)
        return 1

    clean_helper_env = dict(os.environ)
    _pop_env_ci(clean_helper_env, ("CC_SAFE_MANAGED", "CC_SAFE_ACCOUNT", "NO_PROXY"))
    sw_py = _resolve_py_tool("cc-switch")
    tun_py = _resolve_py_tool("cc-us-tunnel")

    if d.get("active") != target:
        live_cnt, live_accs = _count_live_win_sessions(exclude_account=target)
        if not force_switch and (live_cnt > 0 or os.environ.get("CC_NO_AUTO_SWITCH") == "1"):
            running_hint = f" (当前活跃会话: {', '.join(sorted(live_accs))})" if live_accs else ""
            print(
                f"⚠️  账号 [{target}] 当前未激活{running_hint}！请先关闭旧会话并运行 `cc-switch {target}`，或使用 `cc-desktop {target} --switch` 强制切号清场。",
                file=sys.stderr,
            )
            return 1
        if not os.path.isfile(sw_py):
            print(f"⚠️  账号 [{target}] 当前未激活！请先运行 `cc-switch {target}` 切换专线。", file=sys.stderr)
            return 1
        print(f"🔀 [CC-Desktop] 当前空闲，正在自动将美国家宽专线切换至账号 [{target}] ...")
        if subprocess.run([sys.executable, sw_py, target], env=clean_helper_env).returncode != 0:
            print(f"❌ [CC-Desktop 熔断] 自动切换至账号 [{target}] 失败，已阻断启动！", file=sys.stderr)
            return 1

    meta = _read_active_meta()
    if not meta.get("ok") or meta.get("account") != target:
        print("❌ [CC-Desktop 熔断] 账号配置异常，拒绝启动！", file=sys.stderr)
        return 1
    if meta["status"] == "banned":
        print(f"🚫 [CC-Desktop 熔断] 账号 [{target}] 已处于封禁 (banned) 状态，严禁启动桌面客户端！", file=sys.stderr)
        return 1
    expected_ip = meta["ip"]
    if not expected_ip or expected_ip == "未知":
        print(f"❌ [CC-Desktop 熔断] 账号 [{target}] 未绑定 EXPECTED_IP，拒绝启动！", file=sys.stderr)
        return 1

    desktop_bin = _find_claude_desktop_bin()
    if not desktop_bin:
        print("❌ [CC-Desktop] 未检测到 Windows 版 Claude Desktop 客户端 (Claude.exe)！", file=sys.stderr)
        print("   请先从 https://claude.ai/download 安装官方桌面客户端，再使用 `cc-desktop` 启动。", file=sys.stderr)
        return 1
    if os.path.isfile(tun_py):
        if subprocess.run([sys.executable, tun_py, "ensure"], env=clean_helper_env).returncode != 0:
            print("❌ [CC-Desktop 熔断] 本地美国家宽隧道启动失败！", file=sys.stderr)
            return 1

    http_listen, socks_listen, proxy_http_url, proxy_socks_url = _get_tunnel_endpoints()
    h_host, h_port = _split_listen_addr(http_listen)
    s_host, s_port = _split_listen_addr(socks_listen)

    print(f"🔍 [CC-Desktop] 正在核验账号 [{target}] 桌面端专属隧道 (HTTP+SOCKS5h -> {expected_ip})...")
    tr_h = _probe_trace(proxy_http_url, timeout=6)
    if tr_h.get("loc") != "US" or tr_h.get("ip") != expected_ip:
        print(
            f"❌ [Fail-Close] HTTP 出口核验未通过 (实际={tr_h.get('ip') or '无'} / {tr_h.get('loc') or '超时'}, 绑定={expected_ip})！已阻断桌面端启动。",
            file=sys.stderr,
        )
        return 1
    tr_s = _probe_trace(proxy_socks_url, timeout=6)
    if tr_s.get("loc") != "US" or tr_s.get("ip") != expected_ip:
        print(
            f"❌ [Fail-Close] SOCKS5h 出口核验未通过 (实际={tr_s.get('ip') or '无'} / {tr_s.get('loc') or '超时'}, 绑定={expected_ip})！已阻断桌面端启动。",
            file=sys.stderr,
        )
        return 1

    if os.path.isfile(sw_py):
        subprocess.run(
            [sys.executable, sw_py, "apply-local", target, "--if-idle"],
            env=clean_helper_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    killed_tray = _kill_unmanaged_desktop_procs()
    if killed_tray:
        print(f"🧹 已自动清理 {killed_tray} 个后台/托盘残留的 Claude.exe 进程，严防单实例锁串号。")

    prof_dir = os.path.join(SAFE_DIR, "profiles", target)
    prof_cli_home = os.path.join(prof_dir, "home")
    desk_root = os.path.join(prof_dir, "desktop")
    desk_home = os.path.join(desk_root, "home")
    desk_user_data = os.path.join(desk_root, "user-data")
    desk_roaming = os.path.join(desk_root, "AppData", "Roaming")
    desk_local = os.path.join(desk_root, "AppData", "Local")
    desk_claude_cfg_dir = os.path.join(desk_roaming, "Claude")
    desk_claude_data_dir = os.path.join(desk_local, "Claude-Data")
    desk_xdg_cfg = os.path.join(desk_home, ".config")
    desk_xdg_cache = os.path.join(desk_home, ".cache")
    desk_xdg_state = os.path.join(desk_home, ".local", "state")
    for _dd in (
        prof_cli_home,
        desk_home,
        desk_user_data,
        desk_roaming,
        desk_local,
        desk_claude_cfg_dir,
        desk_claude_data_dir,
        desk_xdg_cfg,
        desk_xdg_cache,
        desk_xdg_state,
    ):
        os.makedirs(_dd, mode=0o700, exist_ok=True)

    desk_cfg_json = os.path.join(desk_claude_cfg_dir, "claude_desktop_config.json")
    if not os.path.exists(desk_cfg_json):
        with open(desk_cfg_json, "wb") as cf:
            cf.write(b"{}\n")

    run_env = dict(os.environ)
    _pop_env_ci(
        run_env,
        (
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_CUSTOM_HEADERS",
            "BROWSER",
            "CLAUDE_SUB2API_MANAGED",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_ENABLE_TELEMETRY",
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "OTEL_EXPORTER_OTLP_HEADERS",
            "CLAUDE_CODE_ORGANIZATION_UUID",
            "CLAUDE_CODE_ACCOUNT_UUID",
            "CLAUDE_CODE_HARBOR_KITE_CLOUD",
            "DBUS_SESSION_BUS_ADDRESS",
            "FTP_PROXY",
            "RSYNC_PROXY",
            "GIT_CONFIG_COUNT",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_SYSTEM",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "ALL_PROXY",
            "GRPC_PROXY",
            "NO_PROXY",
            "HOME",
            "USERPROFILE",
            "APPDATA",
            "LOCALAPPDATA",
            "XDG_CONFIG_HOME",
            "XDG_CACHE_HOME",
            "XDG_STATE_HOME",
        ),
    )

    if _get_env_ci(run_env, "CC_SAFE_KEEP_HOST_TOKENS") != "1":
        _pop_env_ci(
            run_env,
            (
                "GH_TOKEN",
                "GITHUB_TOKEN",
                "GH_ENTERPRISE_TOKEN",
                "GITLAB_TOKEN",
                "GLAB_TOKEN",
                "SSH_CONNECTION",
                "SSH_CLIENT",
                "SSH_TTY",
                "TMUX",
                "TMUX_PANE",
                "AWS_ACCESS_KEY_ID",
                "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN",
                "AWS_PROFILE",
                "AZURE_CONFIG_DIR",
                "GOOGLE_APPLICATION_CREDENTIALS",
                "CLOUDSDK_CONFIG",
            ),
        )
        desk_gh_dir = os.path.join(desk_xdg_cfg, "gh")
        os.makedirs(desk_gh_dir, exist_ok=True)
        run_env["GH_CONFIG_DIR"] = desk_gh_dir

    libexec_dir = os.path.join(SAFE_DIR, "libexec")
    cur_path = _get_env_ci(run_env, "PATH")
    _pop_env_ci(run_env, ("PATH",))
    run_env["PATH"] = (libexec_dir + os.pathsep + cur_path) if os.path.isdir(libexec_dir) else cur_path

    gitconfig_p = os.path.join(prof_dir, "gitconfig")
    _pop_env_ci(
        run_env,
        ("GIT_CONFIG_GLOBAL", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"),
    )
    if os.path.isfile(gitconfig_p):
        run_env["GIT_CONFIG_GLOBAL"] = gitconfig_p
        run_env["GIT_AUTHOR_NAME"] = meta["git_user"]
        run_env["GIT_AUTHOR_EMAIL"] = meta["git_email"]
        run_env["GIT_COMMITTER_NAME"] = meta["git_user"]
        run_env["GIT_COMMITTER_EMAIL"] = meta["git_email"]
        run_env["EMAIL"] = meta["git_email"]

    run_env.update(
        {
            "HOME": desk_home,
            "USERPROFILE": desk_home,
            "APPDATA": desk_roaming,
            "LOCALAPPDATA": desk_local,
            "XDG_CONFIG_HOME": desk_xdg_cfg,
            "XDG_CACHE_HOME": desk_xdg_cache,
            "XDG_STATE_HOME": desk_xdg_state,
            "CC_SAFE_MANAGED": "1",
            "CC_SAFE_ACCOUNT": target,
            "CC_SAFE_ROOT": SAFE_DIR,
            "CLAUDE_CONFIG_DIR": prof_cli_home,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": prof_cli_home,
            "ANTHROPIC_CONFIG_DIR": prof_cli_home,
            "GIT_CONFIG_NOSYSTEM": "1",
            "TZ": meta["tz"],
            "HTTPS_PROXY": proxy_http_url,
            "https_proxy": proxy_http_url,
            "HTTP_PROXY": proxy_http_url,
            "http_proxy": proxy_http_url,
            "ALL_PROXY": proxy_socks_url,
            "all_proxy": proxy_socks_url,
            "GRPC_PROXY": proxy_http_url,
            "grpc_proxy": proxy_http_url,
            "NO_PROXY": "localhost,127.0.0.1,::1",
            "no_proxy": "localhost,127.0.0.1,::1",
            "NODE_OPTIONS": "--dns-result-order=ipv4first",
            "BUN_FEATURE_FLAG_DISABLE_IPV6": "1",
            "DISABLE_TELEMETRY": "1",
            "DO_NOT_TRACK": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_GROWTHBOOK": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
        }
    )

    excl_hosts = "EXCLUDE 127.0.0.1 , EXCLUDE localhost"
    if h_host not in ("127.0.0.1", "localhost"):
        excl_hosts += f" , EXCLUDE {h_host}"

    d_args = [
        desktop_bin,
        f"--user-data-dir={desk_user_data}",
        f"--proxy-server={proxy_http_url}",
        "--proxy-bypass-list=<-loopback>",
        f"--host-resolver-rules=MAP * ~NOTFOUND , {excl_hosts}",
        "--disable-quic",
        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
        *extra_electron_args,
    ]

    cookie_cand1 = os.path.join(desk_user_data, "Network", "Cookies")
    cookie_cand2 = os.path.join(desk_user_data, "Cookies")
    has_logged_in = (os.path.isfile(cookie_cand1) and os.path.getsize(cookie_cand1) > 4096) or (
        os.path.isfile(cookie_cand2) and os.path.getsize(cookie_cand2) > 4096
    )

    print(f"✅ [CC-Desktop] 账号: {target} | 出口 IP: {expected_ip} (US) | 时区: {meta['tz']}")
    print(f"   独立设备指纹空间 (ant-did): {desk_root}")
    if not has_logged_in and not no_chrome_hint and os.environ.get("CC_AUDIT_SANDBOX") != "1":
        print("   💡 [首次登录防漏提示]：")
        print(f"      1) 请先运行 `cc-chrome {target}` 打开同源美国 IP 隔离浏览器（若点击登录弹出了系统默认未代理浏览器，请立即关闭并把链接复制到隔离浏览器）；")
        print("      2) 在隔离浏览器验证邮箱后，弹出 'Open Claude?' 时点【取消】，点击网页上的【Sign in with a code / 验证码登录】粘贴回桌面客户端！")
    print("   🛡️ 1s 级断流熔断看门狗守护中（请保持本守护终端开启，关闭客户端及右下角托盘后自动退出）...")

    initial_tunnel_hash = None
    if os.path.isfile(TUNNEL_HASH_FILE):
        try:
            initial_tunnel_hash = open(TUNNEL_HASH_FILE, "r", encoding="utf-8").read().strip()
        except Exception:
            initial_tunnel_hash = None

    h_job = _create_kill_on_close_job()
    stop_evt = threading.Event()
    killswitch_tripped = threading.Event()

    try:
        proc = subprocess.Popen(d_args, env=run_env)
    except PermissionError:
        alias_exe = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WindowsApps", "Claude.exe")
        if IS_WINDOWS and alias_exe and os.path.isfile(alias_exe) and os.path.normcase(alias_exe) != os.path.normcase(desktop_bin):
            d_args[0] = alias_exe
            proc = subprocess.Popen(d_args, env=run_env)
        else:
            raise
    _assign_pid_to_job(h_job, proc.pid)

    marker_file = _write_session_marker(
        WIN_SESS_DIR,
        {
            "pid": os.getpid(),
            "create_time": _get_win_proc_create_time(os.getpid()),
            "claude_pid": proc.pid,
            "claude_create_time": _get_win_proc_create_time(proc.pid),
            "account": target,
            "mode": "desktop",
            "safe_root": SAFE_DIR,
        },
    )

    def _desktop_killswitch():
        fail_streak = 0
        while not stop_evt.wait(1.0):
            if proc.poll() is not None and _get_job_active_processes(h_job) == 0:
                return
            m_now = _read_active_meta()
            if (
                not m_now.get("ok")
                or m_now.get("account") != target
                or m_now.get("status") == "banned"
                or m_now.get("ip") != expected_ip
            ):
                print("\n🛑 [CC-Desktop 实时熔断] 检测到账号已被切换或封禁，立即终止桌面端全部进程（含托盘）！", file=sys.stderr)
                killswitch_tripped.set()
                _terminate_job(h_job, 1)
                try:
                    proc.kill()
                except Exception:
                    pass
                return
            if initial_tunnel_hash is not None:
                cur_hash = None
                try:
                    if os.path.isfile(TUNNEL_HASH_FILE):
                        cur_hash = open(TUNNEL_HASH_FILE, "r", encoding="utf-8").read().strip()
                except Exception:
                    cur_hash = None
                if cur_hash != initial_tunnel_hash:
                    print("\n🛑 [CC-Desktop 实时熔断] 检测到本地专线已停用或切换，立即终止桌面端严防串流泄漏！", file=sys.stderr)
                    killswitch_tripped.set()
                    _terminate_job(h_job, 1)
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    return
            if not (_port_open(h_host, h_port) and _port_open(s_host, s_port)):
                fail_streak += 1
                if fail_streak >= 2:
                    print("\n🛑 [CC-Desktop 实时熔断] 检测到本地 Gost 端口断开，立即阻断桌面端严防直连暴露！", file=sys.stderr)
                    killswitch_tripped.set()
                    _terminate_job(h_job, 1)
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    return
            else:
                fail_streak = 0

    threading.Thread(target=_desktop_killswitch, daemon=True).start()
    try:
        rc = proc.wait()
        if IS_WINDOWS and h_job and not killswitch_tripped.is_set():
            while not killswitch_tripped.is_set() and _get_job_active_processes(h_job) > 0:
                time.sleep(0.5)
    except KeyboardInterrupt:
        _terminate_job(h_job, 1)
        rc = 130
    finally:
        stop_evt.set()
        _remove_file_quiet(marker_file)
        _terminate_job(h_job, 0)
        _close_job(h_job)

    return 1 if killswitch_tripped.is_set() else rc


def main():
    if len(sys.argv) < 2:
        print("Usage: cc_win_launcher.py <safe|desktop|sub2api|totp|chrome> [args...]", file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1].lower()
    rest = sys.argv[2:]
    if mode == "safe":
        sys.exit(run_safe(rest))
    elif mode == "desktop":
        sys.exit(run_desktop(rest))
    elif mode == "sub2api":
        sys.exit(run_sub2api(rest))
    elif mode == "totp":
        sw_py = _resolve_py_tool("cc-switch")
        sys.exit(subprocess.call([sys.executable, sw_py, "totp", *rest]))
    elif mode == "chrome":
        sys.exit(run_chrome(rest))
    else:
        print(f"Unknown launcher mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
