#!/bin/bash
# Install / uninstall / status / watch for Frida Chinese LaunchAgent (user domain).
# Usage:
#   frida-zh-resident-ctl.sh install <root> <python> <lang> [port]
#   frida-zh-resident-ctl.sh uninstall
#   frida-zh-resident-ctl.sh status
#   frida-zh-resident-ctl.sh watch   (used by LaunchAgent as the daemon entry point)
set -euo pipefail

LABEL="com.claude-desktop-zh-cn.frida-zh"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST="$PLIST_DIR/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/claude-frida-zh"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

cmd="${1:-}"
shift || true

log() { echo "[frida-resident] $*"; }

bootout_quiet() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl unload "$PLIST" 2>/dev/null || true
}

do_uninstall() {
  log "卸载系统常驻: $LABEL"
  bootout_quiet
  if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    log "已删除 $PLIST"
  else
    log "未找到 plist（可能尚未安装）"
  fi
  # Stop any leftover launcher / helper; do not force-kill a normal Claude
  # the user may have started outside Frida unless it is clearly ours.
  pkill -f "frida_launch_zh.py" 2>/dev/null || true
  pkill -f "frida-zh-resident-ctl.sh watch" 2>/dev/null || true
  pkill -9 -f "frida-helper" 2>/dev/null || true

  # Frida runtime extracts helpers under ~/.cache/frida (can be hundreds of MB).
  # Clean on uninstall so residual cache is not left after option [3] → N / restore.
  local frida_cache="${HOME}/.cache/frida"
  if [ -d "$frida_cache" ]; then
    rm -rf "$frida_cache"
    log "已清理 Frida 缓存: $frida_cache"
  else
    log "未找到 Frida 缓存目录（$frida_cache）"
  fi

  log "常驻已卸载。登录不再自动后台启动 Frida 汉化。"
}

do_status() {
  echo "Label:  $LABEL"
  echo "Plist:  $PLIST"
  if [ -f "$PLIST" ]; then
    echo "Plist:  installed"
  else
    echo "Plist:  not installed"
  fi
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "Agent:  loaded"
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n '1,40p' || true
  else
    echo "Agent:  not loaded"
  fi
  if pgrep -f "frida_launch_zh.py" >/dev/null 2>&1; then
    echo "Process: frida_launch_zh.py running"
    pgrep -lf "frida_launch_zh.py" || true
  else
    echo "Process: frida_launch_zh.py not running"
  fi
}

do_install() {
  local root="${1:-}"
  local py="${2:-}"
  local lang="${3:-zh-CN}"
  local port="${4:-19351}"
  # Only relaunch is supported for resident (full DOM + menus).
  local strategy="relaunch"

  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "install 需要项目根目录" >&2
    exit 1
  fi

  local launcher="$root/scripts/experimental/frida_launch_zh.py"
  local ctl_script="$root/scripts/experimental/frida-zh-resident-ctl.sh"
  local bridge="$root/scripts/experimental/objc.js"
  local root_venv_py="$root/scripts/experimental/.venv/bin/python"

  # Prefer python inside deploy root so deleting the download folder is safe.
  if [ -x "$root_venv_py" ] && "$root_venv_py" -c "import frida, websockets" >/dev/null 2>&1; then
    if [ -n "$py" ] && [ "$py" != "$root_venv_py" ]; then
      log "使用部署目录内 venv，忽略外部 python: $py"
    fi
    py="$root_venv_py"
  fi
  if [ -z "$py" ] || [ ! -x "$py" ]; then
    echo "install 需要可用的 python（含 frida）。期望: $root_venv_py" >&2
    exit 1
  fi

  if [ ! -f "$launcher" ]; then
    echo "缺少启动器: $launcher" >&2
    exit 1
  fi
  if ! "$py" -c "import frida, websockets" >/dev/null 2>&1; then
    echo "Python 无法 import frida/websockets: $py" >&2
    exit 1
  fi

  chmod +x "$ctl_script" 2>/dev/null || true
  mkdir -p "$PLIST_DIR" "$LOG_DIR"

  # Stop previous instance cleanly before rewriting plist.
  bootout_quiet
  pkill -f "frida_launch_zh.py" 2>/dev/null || true
  sleep 0.3

  local env_bridge=""
  if [ -f "$bridge" ]; then
    env_bridge="$bridge"
  fi

  # Absolute paths only — LaunchAgents should not rely on relative cwd.
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${ctl_script}</string>
    <string>watch</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${root}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_FRIDA_ROOT</key>
    <string>${root}</string>
    <key>CLAUDE_FRIDA_LAUNCHER</key>
    <string>${launcher}</string>
    <key>CLAUDE_FRIDA_PYTHON</key>
    <string>${py}</string>
    <key>CLAUDE_FRIDA_VENV_PY</key>
    <string>${root}/scripts/experimental/.venv/bin/python</string>
    <key>CLAUDE_FRIDA_LANG</key>
    <string>${lang}</string>
    <key>CLAUDE_FRIDA_PORT</key>
    <string>${port}</string>
    <key>CLAUDE_FRIDA_LOG_DIR</key>
    <string>${LOG_DIR}</string>
    <key>CLAUDE_FRIDA_RESIDENT</key>
    <string>1</string>
    <key>CLAUDE_FRIDA_WATCH_STRATEGY</key>
    <string>${strategy}</string>
    <key>CLAUDE_FRIDA_WATCH_INTERVAL</key>
    <string>3.0</string>
    <key>FRIDA_OBJC_BRIDGE</key>
    <string>${env_bridge}</string>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
</dict>
</plist>
EOF

  log "已写入 $PLIST"
  log "语言=$lang 端口=$port 方式=relaunch（点官方图标后替换为 Frida 启动）"
  log "Python=$py"
  log "日志目录=$LOG_DIR"
  log "常驻不再自己先开 Claude：请从 Dock/官方图标启动，监视器会接管。"

  # Modern launchctl (user gui domain)
  BOOT_ERR="$(mktemp -t claude-frida-boot.XXXXXX 2>/dev/null || echo /tmp/claude-frida-bootstrap.err)"
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>"$BOOT_ERR"; then
    # Already loaded? try bootout then bootstrap again
    bootout_quiet
    sleep 0.3
    if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>>"$BOOT_ERR"; then
      if ! launchctl load -w "$PLIST" 2>>"$BOOT_ERR"; then
        echo "launchctl 注册失败:" >&2
        cat "$BOOT_ERR" 2>/dev/null || true
        rm -f "$BOOT_ERR"
        exit 1
      fi
    fi
  fi
  rm -f "$BOOT_ERR"

  # Kick start now (don't wait for next login)
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || \
    launchctl start "$LABEL" 2>/dev/null || true

  # Verify: plist exists + agent loaded + process eventually appears
  sleep 1.2
  if [ ! -f "$PLIST" ]; then
    echo "错误: plist 写入后不存在: $PLIST" >&2
    exit 1
  fi
  if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "警告: launchctl 未看到服务 $DOMAIN/$LABEL — 尝试 load -w"
    launchctl load -w "$PLIST" 2>/dev/null || true
    sleep 0.8
  fi
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    log "launchctl: 服务已加载"
  else
    echo "错误: 常驻服务未能加载。请检查：" >&2
    echo "  launchctl print $DOMAIN/$LABEL" >&2
    echo "  tail -50 $LOG_DIR/stderr.log" >&2
    exit 1
  fi

  # Wait briefly for watcher process
  for _i in 1 2 3 4 5 6 7 8; do
    if pgrep -f "frida_launch_zh.py" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  log "系统常驻已安装。"
  log "  - 监视器应常驻后台（KeepAlive=true）"
  log "  - 请从 Dock / 官方 Claude.app 打开客户端"
  log "  - 策略 relaunch：发现官方进程后会替换为 Frida 版（可能闪一下）"
  log "查看日志: tail -f \"$LOG_DIR/stdout.log\""
  log "确认监视: 日志应出现 Watch mode ON"
  log "卸载: install-mac.command 选 [3] → N"
  do_status
  if ! pgrep -f "frida_launch_zh.py" >/dev/null 2>&1; then
    echo
    log "警告: 尚未看到 frida_launch_zh.py 进程。请立刻查看："
    log "  tail -50 \"$LOG_DIR/stdout.log\""
    log "  tail -50 \"$LOG_DIR/stderr.log\""
    exit 1
  fi
  if ! rg -q "Watch mode ON" "$LOG_DIR/stdout.log" 2>/dev/null; then
    # give it a moment to print
    sleep 1
  fi
  if rg -q "Watch mode ON" "$LOG_DIR/stdout.log" 2>/dev/null; then
    log "已确认日志含 Watch mode ON（监视模式正常）"
  else
    log "警告: 日志里还没有 'Watch mode ON'。若仍是 Frida spawn 开头，说明跑的是旧逻辑。"
    log "  tail -30 \"$LOG_DIR/stdout.log\""
  fi
}

do_watch() {
  # Daemon entry point: called by LaunchAgent to monitor and inject Claude.
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

  : "${CLAUDE_FRIDA_ROOT:=$ROOT}"
  : "${CLAUDE_FRIDA_LAUNCHER:=$CLAUDE_FRIDA_ROOT/scripts/experimental/frida_launch_zh.py}"
  : "${CLAUDE_FRIDA_VENV_PY:=$CLAUDE_FRIDA_ROOT/scripts/experimental/.venv/bin/python}"
  : "${CLAUDE_FRIDA_LANG:=zh-CN}"
  : "${CLAUDE_FRIDA_PORT:=19351}"
  : "${CLAUDE_FRIDA_LOG_DIR:=$HOME/Library/Logs/claude-frida-zh}"

  mkdir -p "$CLAUDE_FRIDA_LOG_DIR"

  # Prefer deploy-root venv so deleting the download/project folder cannot break
  # the LaunchAgent. CLAUDE_FRIDA_PYTHON may still point at a deleted path.
  ROOT_VENV_PY="$CLAUDE_FRIDA_ROOT/scripts/experimental/.venv/bin/python"
  ROOT_VENV_PY3="$CLAUDE_FRIDA_ROOT/scripts/experimental/.venv/bin/python3"
  : "${CLAUDE_FRIDA_VENV_PY:=$ROOT_VENV_PY}"

  pick_python() {
    local cand
    for cand in \
      "$CLAUDE_FRIDA_VENV_PY" \
      "$ROOT_VENV_PY" \
      "$ROOT_VENV_PY3" \
      "${CLAUDE_FRIDA_PYTHON:-}"
    do
      [ -n "$cand" ] || continue
      [ -x "$cand" ] || continue
      if "$cand" -c "import frida, websockets" >/dev/null 2>&1; then
        echo "$cand"
        return 0
      fi
    done
    return 1
  }

  PY="$(pick_python || true)"
  if [ -z "$PY" ]; then
    PY="$(command -v python3 2>/dev/null || true)"
  fi
  if [ -z "$PY" ] || [ ! -x "$PY" ]; then
    echo "[frida-zh-resident] no python3" >&2; exit 1
  fi
  if [ ! -f "$CLAUDE_FRIDA_LAUNCHER" ]; then
    echo "[frida-zh-resident] launcher missing: $CLAUDE_FRIDA_LAUNCHER" >&2; exit 1
  fi
  if ! "$PY" -c "import frida, websockets" >/dev/null 2>&1; then
    echo "[frida-zh-resident] frida/websockets missing in $PY (expected deploy venv under $CLAUDE_FRIDA_ROOT)" >&2
    exit 1
  fi
  # Prefer recording the resolved deploy python for logs/debug.
  export CLAUDE_FRIDA_PYTHON="$PY"

  BRIDGE="$CLAUDE_FRIDA_ROOT/scripts/experimental/objc.js"
  if [ -z "${FRIDA_OBJC_BRIDGE:-}" ] && [ -f "$BRIDGE" ]; then
    export FRIDA_OBJC_BRIDGE="$BRIDGE"
  fi

  export CLAUDE_FRIDA_RESIDENT=1
  export CLAUDE_FRIDA_WATCH_STRATEGY=relaunch

  exec "$PY" "$CLAUDE_FRIDA_LAUNCHER" \
    --lang "$CLAUDE_FRIDA_LANG" \
    --port "$CLAUDE_FRIDA_PORT" \
    --watch \
    --watch-strategy relaunch \
    "$@"
}

case "$cmd" in
  install)
    do_install "$@"
    ;;
  uninstall|remove|off)
    do_uninstall
    ;;
  status)
    do_status
    ;;
  watch)
    do_watch "$@"
    ;;
  *)
    echo "Usage: $0 install <root> <python> <lang> [port] [strategy]"
    echo "       $0 uninstall"
    echo "       $0 status"
    echo "       $0 watch"
    exit 1
    ;;
esac
