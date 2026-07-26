#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="/usr/bin/python3"
PATCHER="$DIR/scripts/patch_claude_zh_cn.py"
FRIDA_LAUNCHER="$DIR/scripts/experimental/frida_launch_zh.py"

if [ ! -x "$PYTHON" ]; then
  PYTHON="$(command -v python3)"
fi

# Prefer any Python that already has frida. Do NOT hardcode miniforge/conda —
# plain Macs only have /usr/bin/python3; package-local .venv is the portable path.
find_python_with_frida() {
  local candidates=()
  if [ -n "${CLAUDE_PYTHON:-}" ]; then
    candidates+=("$CLAUDE_PYTHON")
  fi
  # Package-local venv first (created by option [3] bootstrap on any machine)
  candidates+=(
    "$DIR/scripts/experimental/.venv/bin/python"
    "$DIR/scripts/experimental/.venv/bin/python3"
  )
  candidates+=("$PYTHON" "$(command -v python3 2>/dev/null || true)" /usr/bin/python3)
  # Optional extras if present on PATH layout (no miniforge-specific assumption)
  candidates+=(
    /opt/homebrew/bin/python3
    /usr/local/bin/python3
  )
  local seen="|"
  local p
  for p in "${candidates[@]}"; do
    [ -z "$p" ] && continue
    case "$seen" in
      *"|$p|"*) continue ;;
    esac
    seen="${seen}${p}|"
    if [ -x "$p" ] && "$p" -c "import frida, websockets" >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

check_release_update() {
  if [ "${CLAUDE_ZH_SKIP_UPDATE_CHECK:-0}" = "1" ]; then
    return
  fi

  "$PYTHON" - "$DIR/resources/release.json" 2>/dev/null <<'PY'
import json
import re
import sys
import urllib.request

metadata_path = sys.argv[1]
try:
    with open(metadata_path, "r", encoding="utf-8") as f:
        metadata = json.load(f)
    repo = metadata["repo"]
    current = str(metadata["release"])
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "claude-desktop-zh-cn-update-check",
        },
    )
    with urllib.request.urlopen(req, timeout=3) as response:
        latest = str(json.load(response)["tag_name"])

    def version_key(value):
        parts = [int(part) for part in re.findall(r"\d+", value)]
        return parts + [0] * (3 - len(parts))

    if version_key(latest) > version_key(current):
        print(
            f"检测到 GitHub Releases 已发布新版 {latest}，当前脚本包为 {current}。"
            "建议及时更新。本次操作会继续执行。"
        )
except Exception:
    pass
PY
}

check_release_update

echo "Claude Desktop 中文补丁"
echo "目录: $DIR"
echo

ACTION="${CLAUDE_ACTION:-}"
SKIP_ASAR_PATCH="${CLAUDE_SKIP_ASAR_PATCH:-0}"
if [ -z "$ACTION" ]; then
  echo "请选择操作："
  echo "  [1] 安装中文补丁(官方订阅与第三方api均可使用：Cowork 沙箱/工作区不可用看群公告)"
  echo "  [2] 安装中文补丁(第三方api可用：第三方模型需借助ccswitch映射(Cowork 沙箱/工作区不可用看群公告))"
  echo "  [3] Frida 运行时汉化（实验特性，可测试）"
  echo "  [4] 恢复原样 / 卸载补丁"
  echo "  [5] 自动更新设置（y=禁止自动更新，n=允许自动更新）"
  echo "  [6] 同步CC Switch skills （y=同步，n=删除之前的同步）"
  echo
  read -rp "请输入选项 [1/2/3/4/5/6，默认 1]: " action_choice
  case "${action_choice:-1}" in
    2) ACTION="install"; SKIP_ASAR_PATCH="1" ;;
    3) ACTION="frida-launch" ;;
    4) ACTION="restore" ;;
    5)
      read -rp "是否禁止自动更新？[y=禁止 / n=允许]: " update_choice
      case "$update_choice" in
        y|Y) ACTION="disable-updates" ;;
        n|N) ACTION="enable-updates" ;;
        *) echo "无效输入，请输入 y 或 n。"; exit 1 ;;
      esac
      ;;
    6)
      read -rp "是否同步 CC Switch skills？[y=同步 / n=删除之前的同步]: " skills_choice
      case "$skills_choice" in
        y|Y) ACTION="sync-skills" ;;
        n|N) ACTION="unsync-skills" ;;
        *) echo "无效输入，请输入 y 或 n。"; exit 1 ;;
      esac
      ;;
    *) ACTION="install" ;;
  esac
  echo
fi

if [ "$ACTION" = "uninstall" ]; then
  ACTION="restore"
fi

DRY_RUN=0
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then
    DRY_RUN=1
  fi
done

if [ "$ACTION" = "install" ]; then
  echo "安装前清理旧中文补丁..."
  if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    sudo "$PYTHON" "$PATCHER" --user-home "$HOME" --restore-if-backup-exists "$@"
  else
    "$PYTHON" "$PATCHER" --user-home "$HOME" --restore-if-backup-exists "$@"
  fi
  echo
fi

# Language selection
if [ "$ACTION" = "restore" ] || [ "$ACTION" = "disable-updates" ] || [ "$ACTION" = "enable-updates" ] || [ "$ACTION" = "sync-skills" ] || [ "$ACTION" = "unsync-skills" ]; then
  LANG_CODE=""
elif [ -z "${CLAUDE_LANG:-}" ]; then
  if [ "$ACTION" = "frida-launch" ]; then
    echo "请选择要注入的语言："
  else
    echo "请选择要安装的语言："
  fi
  echo "  [1] 简体中文"
  echo "  [2] 繁体中文（中国台湾）"
  echo "  [3] 繁体中文（中国香港）"
  echo
  read -rp "请输入选项 [1/2/3，默认 1]: " choice
  case "${choice:-1}" in
    2) LANG_CODE="zh-TW" ;;
    3) LANG_CODE="zh-HK" ;;
    *) LANG_CODE="zh-CN" ;;
  esac
  echo
else
  LANG_CODE="$CLAUDE_LANG"
fi

SKIP_ASAR_ARG=""
case "$SKIP_ASAR_PATCH" in
  1|true|TRUE|yes|YES|y|Y) SKIP_ASAR_ARG="--skip-asar-patch" ;;
esac

if [ "$ACTION" = "install" ]; then
  echo "选择的语言: $LANG_CODE"
  if [ -n "$SKIP_ASAR_ARG" ]; then
    echo "安全模式: 跳过结构性 app.asar 补丁，仅应用等长菜单汉化补丁"
  fi
  echo
fi

if [ "$ACTION" = "frida-launch" ]; then
  if [ ! -f "$FRIDA_LAUNCHER" ]; then
    echo "未找到 Frida 启动器: $FRIDA_LAUNCHER"
    echo "按回车退出。"
    read -r _
    exit 1
  fi

  FRIDA_REQ="$DIR/scripts/experimental/requirements-frida.txt"
  FRIDA_VENV="$DIR/scripts/experimental/.venv"
  FRIDA_RESIDENT_CTL="$DIR/scripts/experimental/frida-zh-resident-ctl.sh"
  FRIDA_PORT="${CLAUDE_FRIDA_PORT:-19351}"
  FRIDA_PYTHON="$(find_python_with_frida || true)"

  ensure_frida_python() {
    # Populate FRIDA_PYTHON (package .venv or existing install). No launch.
    if [ -n "${FRIDA_PYTHON:-}" ] && [ -x "$FRIDA_PYTHON" ] \
      && "$FRIDA_PYTHON" -c "import frida, websockets" >/dev/null 2>&1; then
      return 0
    fi
    FRIDA_PYTHON=""

    echo "当前环境未检测到可用的 frida / websockets。"
    echo
    echo "说明："
    echo "  - 不写磁盘 app.asar，不复制 Claude.app"
    echo "  - 若官方包带 Hardened Runtime 且 SIP 仍开启，会自动对本机 /Applications/Claude.app 做 ad-hoc 重签名（加 get-task-allow、去掉 hardened runtime），仅改签名以允许 Frida 注入"
    echo "  - 将创建 .venv 并 pip 安装依赖（需要网络）"
    echo "  - 不依赖 miniforge/conda；用系统自带或已安装的 python3 即可"
    echo

    if [ ! -f "$FRIDA_REQ" ]; then
      echo "未找到依赖清单，无法自动下载。"
      echo "请手动安装：python3 -m pip install frida frida-tools websockets"
      return 1
    fi

    INSTALL_FRIDA="y"
    case "${CLAUDE_FRIDA_INSTALL:-1}" in
      0|n|N|no|NO|false|FALSE) INSTALL_FRIDA="n" ;;
    esac
    if [ "$INSTALL_FRIDA" != "y" ]; then
      echo "已跳过安装（CLAUDE_FRIDA_INSTALL=0）"
    fi

    if [ "$INSTALL_FRIDA" != "y" ]; then
      echo "已跳过下载。可再选 [3] 重试。"
      return 1
    fi

    echo
    BASE_PY="${CLAUDE_PYTHON:-}"
    if [ -z "$BASE_PY" ] || [ ! -x "$BASE_PY" ]; then
      BASE_PY="$(command -v python3 2>/dev/null || true)"
    fi
    if [ -z "$BASE_PY" ] || [ ! -x "$BASE_PY" ]; then
      BASE_PY="/usr/bin/python3"
    fi
    if [ ! -x "$BASE_PY" ]; then
      echo "未找到 Python 3，无法安装依赖。"
      return 1
    fi

    # Prefer bootstrap's venv creation logic when available, but do NOT launch Claude.
    if [ ! -x "$FRIDA_VENV/bin/python" ]; then
      echo "创建包内 .venv: $FRIDA_VENV"
      if ! "$BASE_PY" -m venv "$FRIDA_VENV"; then
        echo "创建 venv 失败。若是 /usr/bin/python3，请先: xcode-select --install"
        return 1
      fi
    fi
    set +e
    "$FRIDA_VENV/bin/python" -m pip install -q --upgrade pip
    "$FRIDA_VENV/bin/python" -m pip install -r "$FRIDA_REQ"
    PIP_STATUS=$?
    set -e
    SHIM_SRC="${FRIDA_VENV%/.venv}/typing_shim_sitecustomize.py"
    if [ -f "$SHIM_SRC" ]; then
      SP="$("$FRIDA_VENV/bin/python" -c 'import sys,site; print(site.getsitepackages()[0] if sys.version_info < (3,11) else "")' 2>/dev/null || true)"
      if [ -n "$SP" ]; then
        cp "$SHIM_SRC" "$SP/sitecustomize.py"
      fi
    fi
    if [ "$PIP_STATUS" -ne 0 ] || ! "$FRIDA_VENV/bin/python" -c "import frida, websockets" 2>/dev/null; then
      echo "依赖安装失败（需要网络；可配置 pip 镜像后重试）。"
      return 1
    fi
    FRIDA_PYTHON="$FRIDA_VENV/bin/python"
    echo "依赖就绪: $FRIDA_PYTHON"
    return 0
  }

  # --- Resident Y/N (or one-shot) ---
  # Y = install LaunchAgent + background run
  # N = uninstall LaunchAgent
  # empty / other = one-shot foreground (default; does not change agent)
  # Always set with default — script runs under `set -u`.
  INSTALL_DIR="${INSTALL_DIR:-$HOME/.claude-zh}"

  deploy_to_claude_zh() {
    # Copy all needed runtime files to deploy root preserving structure.
    # After this, the download/project folder can be deleted safely.
    local install_dir="${INSTALL_DIR:-$HOME/.claude-zh}"
    echo "部署文件到 $install_dir ..."
    mkdir -p "$install_dir/scripts/experimental"
    mkdir -p "$install_dir/resources"

    # Core scripts
    cp "$DIR/scripts/patch_claude_zh_cn.py" "$install_dir/scripts/"
    cp "$DIR/scripts/experimental/frida_launch_zh.py" "$install_dir/scripts/experimental/"
    cp "$DIR/scripts/experimental/cdp_launch_zh.py" "$install_dir/scripts/experimental/"
    cp "$DIR/scripts/experimental/frida_cdp_gate.js" "$install_dir/scripts/experimental/"
    cp "$DIR/scripts/experimental/objc.js" "$install_dir/scripts/experimental/"
    cp "$DIR/scripts/experimental/typing_shim_sitecustomize.py" "$install_dir/scripts/experimental/"
    cp "$DIR/scripts/experimental/requirements-frida.txt" "$install_dir/scripts/experimental/"
    cp "$DIR/scripts/experimental/frida-zh-resident-ctl.sh" "$install_dir/scripts/experimental/"
    chmod +x "$install_dir/scripts/experimental/frida-zh-resident-ctl.sh"

    # Resources — copy all (small JSON/strings files)
    cp "$DIR/resources/"* "$install_dir/resources/" 2>/dev/null || true

    # Python venv must live under deploy root (not the download folder).
    # Prefer moving/copying an existing project venv; else create one here.
    local src_venv="$DIR/scripts/experimental/.venv"
    local dst_venv="$install_dir/scripts/experimental/.venv"
    if [ -x "$dst_venv/bin/python" ] \
      && "$dst_venv/bin/python" -c "import frida, websockets" >/dev/null 2>&1; then
      echo "部署目录已有可用 .venv: $dst_venv"
    else
      if [ -d "$src_venv" ] && [ -x "$src_venv/bin/python" ]; then
        echo "迁移 .venv → $dst_venv"
        rm -rf "$dst_venv"
        # cp -a preserves symlinks inside venv; recreate if import fails after copy
        cp -a "$src_venv" "$dst_venv"
        if ! "$dst_venv/bin/python" -c "import frida, websockets" >/dev/null 2>&1; then
          echo "迁移后的 venv 不可用，将在部署目录重建"
          rm -rf "$dst_venv"
        fi
      fi
    fi

    # Export so callers under `set -u` always see a defined path.
    INSTALL_DIR="$install_dir"
    echo "部署完成: $INSTALL_DIR"
  }
  FRIDA_RESIDENT_CHOICE="${CLAUDE_FRIDA_RESIDENT:-}"
  if [ -z "$FRIDA_RESIDENT_CHOICE" ]; then
    echo "是否注册为系统常驻（监视官方 Claude Desktop 并自动汉化）？"
    echo "安装并后台运行(Y为安装，N为卸载)"
    echo
    if [ -t 0 ]; then
      read -rp "请选择 [Y/N]: " FRIDA_RESIDENT_CHOICE || true
    else
      FRIDA_RESIDENT_CHOICE=""
      echo "非交互模式: 仅本次前台启动（设置 CLAUDE_FRIDA_RESIDENT=Y|N 可改）"
    fi
    echo
  fi

  case "${FRIDA_RESIDENT_CHOICE}" in
    y|Y|yes|YES|Yes)
      # Deploy files to ~/.claude-zh so project dir can be deleted safely.
      INSTALL_DIR="${INSTALL_DIR:-$HOME/.claude-zh}"
      deploy_to_claude_zh
      INSTALL_DIR="${INSTALL_DIR:-$HOME/.claude-zh}"

      # Point venv/req to deployed location for ensure_frida_python.
      FRIDA_VENV="${INSTALL_DIR}/scripts/experimental/.venv"
      FRIDA_REQ="${INSTALL_DIR}/scripts/experimental/requirements-frida.txt"
      FRIDA_RESIDENT_CTL="${INSTALL_DIR}/scripts/experimental/frida-zh-resident-ctl.sh"

      if ! ensure_frida_python; then
        echo "按回车退出。"
        read -r _
        exit 1
      fi
      # Force resident to use deploy-root python only (never the Downloads path).
      if [ -x "${FRIDA_VENV}/bin/python" ] \
        && "${FRIDA_VENV}/bin/python" -c "import frida, websockets" >/dev/null 2>&1; then
        FRIDA_PYTHON="${FRIDA_VENV}/bin/python"
      fi
      # Always relaunch: full DOM + menus after Dock/official launch.
      FRIDA_STRATEGY="relaunch"
      # Uninstall old resident first to ensure clean state.
      bash "$FRIDA_RESIDENT_CTL" uninstall 2>/dev/null || true
      if [ -z "${FRIDA_OBJC_BRIDGE:-}" ] && [ -f "${INSTALL_DIR}/scripts/experimental/objc.js" ]; then
        export FRIDA_OBJC_BRIDGE="${INSTALL_DIR}/scripts/experimental/objc.js"
      fi
      echo "正在安装系统常驻（监视 + relaunch）..."
      echo "  安装目录: ${INSTALL_DIR}"
      echo "  Python: ${FRIDA_PYTHON}"
      echo "  语言:   ${LANG_CODE}"
      echo "  端口:   ${FRIDA_PORT}"
      echo "  方式:   点官方图标后替换为 Frida 启动（网页+菜单可汉化，可能闪一下）"
      echo "  日志:   $HOME/Library/Logs/claude-frida-zh/"
      echo "  说明:   常驻只依赖 ${INSTALL_DIR}，可删除下载目录"
      echo
      echo "说明：常驻进程本身不先打开 Claude；请用 Dock/官方图标启动，监视器会自动接管。"
      echo
      set +e
      bash "$FRIDA_RESIDENT_CTL" install "${INSTALL_DIR}" "${FRIDA_PYTHON}" "${LANG_CODE}" "${FRIDA_PORT}" "${FRIDA_STRATEGY}"
      STATUS=$?
      set -e
      echo
      if [ "$STATUS" -eq 0 ]; then
        echo "系统常驻已启用。"
        echo "正在启动 Claude Desktop..."
        open -a "Claude"
        # 关闭终端窗口
        osascript -e 'tell application "Terminal" to close front window' &>/dev/null || true
        exit 0
      else
        echo "系统常驻安装失败（退出码 $STATUS）。"
        echo "可查看: $HOME/Library/Logs/claude-frida-zh/"
      fi
      echo "按回车退出。"
      read -r _
      exit "$STATUS"
      ;;
    n|N|no|NO|No)
      INSTALL_DIR="${INSTALL_DIR:-$HOME/.claude-zh}"
      # Try deployed ctl first, fall back to project dir
      _CTL="${INSTALL_DIR}/scripts/experimental/frida-zh-resident-ctl.sh"
      if [ ! -f "$_CTL" ]; then
        _CTL="$FRIDA_RESIDENT_CTL"
      fi
      if [ -f "$_CTL" ]; then
        chmod +x "$_CTL" 2>/dev/null || true
        set +e
        bash "$_CTL" uninstall
        STATUS=$?
        set -e
      else
        # Minimal fallback uninstall without ctl script
        LABEL="com.claude-desktop-zh-cn.frida-zh"
        PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        pkill -f "frida_launch_zh.py" 2>/dev/null || true
        pkill -f "frida-zh-resident-ctl.sh watch" 2>/dev/null || true
        pkill -9 -f "frida-helper" 2>/dev/null || true
        if [ -d "$HOME/.cache/frida" ]; then
          rm -rf "$HOME/.cache/frida"
          echo "已清理 Frida 缓存: $HOME/.cache/frida"
        fi
        echo "已尝试卸载系统常驻（无 ctl 脚本，走内置回退）。"
        STATUS=0
      fi
      # Clean up deployed directory
      if [ -d "${INSTALL_DIR}" ]; then
        rm -rf "${INSTALL_DIR}"
        echo "已清理部署目录: ${INSTALL_DIR}"
      fi
      # Also clear Frida helper cache when using ctl uninstall (ctl does it; double-safe).
      if [ -d "$HOME/.cache/frida" ]; then
        rm -rf "$HOME/.cache/frida"
        echo "已清理 Frida 缓存: $HOME/.cache/frida"
      fi
      echo
      echo "按回车退出。"
      read -r _
      exit "${STATUS:-0}"
      ;;
  esac

  # --- One-shot foreground launch (default) ---
  if ! ensure_frida_python; then
    echo "按回车退出。"
    read -r _
    exit 1
  fi

  echo "Frida 运行时汉化启动（仅本次前台）"
  echo "  Python: $FRIDA_PYTHON"
  echo "  语言:   $LANG_CODE"
  echo "  启动器: $FRIDA_LAUNCHER"
  echo
  echo "说明："
  echo "  - 不写磁盘 app.asar；不复制 Claude.app 到其他路径"
  echo "  - 默认自动对本机官方包做 Frida 调试重签名（仅签名；app.asar 字节不变）"
  echo "  - 退出时会校验 ASAR_UNCHANGED=yes"
  echo "  - 复用客户端原有 userdata（3p 走 Claude-3p，在线走 Claude）"
  echo "  - 按 Ctrl+C 结束本次运行"
  echo "  - 系统常驻：再选 [3] → Y 安装 / N 卸载"
  echo

  if [ -z "${FRIDA_OBJC_BRIDGE:-}" ] && [ -f "$DIR/scripts/experimental/objc.js" ]; then
    export FRIDA_OBJC_BRIDGE="$DIR/scripts/experimental/objc.js"
  fi

  set +e
  "$FRIDA_PYTHON" "$FRIDA_LAUNCHER" --lang "$LANG_CODE" --port "$FRIDA_PORT" "$@"
  STATUS=$?
  set -e

  echo
  if [ "$STATUS" -eq 0 ]; then
    echo "Frida 启动已结束。"
  else
    echo "Frida 启动退出码: $STATUS"
  fi
  echo "按回车退出。"
  read -r _
  exit "$STATUS"
fi

NEEDS_SUDO=1
if [ "$ACTION" = "sync-skills" ] || [ "$ACTION" = "unsync-skills" ]; then
  NEEDS_SUDO=0
fi
if [ "$DRY_RUN" -eq 1 ]; then
  NEEDS_SUDO=0
fi

if [ "$(id -u)" -ne 0 ] && [ "$NEEDS_SUDO" -eq 1 ]; then
  # Clean up frida resident before restore (runs as current user, not root)
  if [ "$ACTION" = "restore" ]; then
    LABEL="com.claude-desktop-zh-cn.frida-zh"
    PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
    if [ -f "$PLIST" ]; then
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      launchctl unload "$PLIST" 2>/dev/null || true
      rm -f "$PLIST"
      echo "已卸载系统常驻 frida-zh。"
    fi
    pkill -f "frida_launch_zh.py" 2>/dev/null || true
    pkill -f "frida-zh-resident-ctl.sh watch" 2>/dev/null || true
    pkill -9 -f "frida-helper" 2>/dev/null || true
    if [ -d "$HOME/.claude-zh" ]; then
      rm -rf "$HOME/.claude-zh"
      echo "已清理部署目录: $HOME/.claude-zh"
    fi
    if [ -d "$HOME/.cache/frida" ]; then
      rm -rf "$HOME/.cache/frida"
      echo "已清理 Frida 缓存: $HOME/.cache/frida"
    fi
  fi
  echo "需要管理员权限来替换 /Applications/Claude.app。"
  echo "请按提示输入这台 Mac 的登录密码。"
  echo
  if [ "$ACTION" = "restore" ]; then
    sudo "$PYTHON" "$PATCHER" --user-home "$HOME" --restore --launch "$@"
  elif [ "$ACTION" = "disable-updates" ]; then
    sudo "$PYTHON" "$PATCHER" --user-home "$HOME" --set-auto-updates disabled "$@"
  elif [ "$ACTION" = "enable-updates" ]; then
    sudo "$PYTHON" "$PATCHER" --user-home "$HOME" --set-auto-updates enabled "$@"
  else
    sudo "$PYTHON" "$PATCHER" --user-home "$HOME" --lang "$LANG_CODE" --launch ${SKIP_ASAR_ARG:+"$SKIP_ASAR_ARG"} "$@"
  fi
  STATUS=$?
  echo
  echo "按回车退出。"
  read -r _
  exit "$STATUS"
fi

USER_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  USER_HOME="$("$PYTHON" -c 'import pwd, sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$SUDO_USER" 2>/dev/null || true)"
  if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    USER_HOME="$(eval echo "~$SUDO_USER")"
  fi
fi

if [ "$ACTION" = "restore" ]; then
  # Also remove frida resident LaunchAgent if present
  LABEL="com.claude-desktop-zh-cn.frida-zh"
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    pkill -f "frida_launch_zh.py" 2>/dev/null || true
    pkill -f "frida-zh-resident-ctl.sh watch" 2>/dev/null || true
    pkill -9 -f "frida-helper" 2>/dev/null || true
    echo "已卸载系统常驻 frida-zh。"
  fi
  # Clean up deployed directory
  if [ -d "$HOME/.claude-zh" ]; then
    rm -rf "$HOME/.claude-zh"
    echo "已清理部署目录: $HOME/.claude-zh"
  fi
  if [ -d "$HOME/.cache/frida" ]; then
    rm -rf "$HOME/.cache/frida"
    echo "已清理 Frida 缓存: $HOME/.cache/frida"
  fi
  "$PYTHON" "$PATCHER" --user-home "$USER_HOME" --restore --launch "$@"
elif [ "$ACTION" = "disable-updates" ]; then
  "$PYTHON" "$PATCHER" --user-home "$USER_HOME" --set-auto-updates disabled "$@"
elif [ "$ACTION" = "enable-updates" ]; then
  "$PYTHON" "$PATCHER" --user-home "$USER_HOME" --set-auto-updates enabled "$@"
elif [ "$ACTION" = "sync-skills" ]; then
  "$PYTHON" "$PATCHER" --user-home "$USER_HOME" --sync-cc-switch-skills "$@"
elif [ "$ACTION" = "unsync-skills" ]; then
  "$PYTHON" "$PATCHER" --user-home "$USER_HOME" --unsync-cc-switch-skills "$@"
else
  "$PYTHON" "$PATCHER" --user-home "$USER_HOME" --lang "$LANG_CODE" --launch ${SKIP_ASAR_ARG:+"$SKIP_ASAR_ARG"} "$@"
fi

echo
echo "完成。按回车退出。"
read -r _
