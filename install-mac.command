#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="/usr/bin/python3"
PATCHER="$DIR/scripts/patch_claude_zh_cn.py"

if [ ! -x "$PYTHON" ]; then
  PYTHON="$(command -v python3)"
fi

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
echo "安装成功后会启用受保护的自动修复服务；Claude 更新后会自动补回汉化。"
echo

ACTION="${CLAUDE_ACTION:-}"
SKIP_ASAR_PATCH="${CLAUDE_SKIP_ASAR_PATCH:-0}"
if [ -z "$ACTION" ]; then
  echo "请选择操作："
  echo "  [1] 安装中文补丁(官方订阅与第三方api均可使用：Cowork 沙箱/工作区不可用看群公告)"
  echo "  [2] 基础兼容模式（完全不修改 app.asar；新版增强补丁不兼容时也会自动回退到此模式）"
  echo "  [3] 恢复原样 / 卸载补丁"
  echo "  [4] 自动更新设置（y=禁止自动更新，n=允许自动更新）"
  echo "  [5] 同步CC Switch skills （y=同步，n=删除之前的同步）"
  echo
  read -rp "请输入选项 [1/2/3/4/5，默认 1]: " action_choice
  case "${action_choice:-1}" in
    2) ACTION="install"; SKIP_ASAR_PATCH="1" ;;
    3) ACTION="restore" ;;
    4)
      read -rp "是否禁止自动更新？[y=禁止 / n=允许]: " update_choice
      case "$update_choice" in
        y|Y) ACTION="disable-updates" ;;
        n|N) ACTION="enable-updates" ;;
        *) echo "无效输入，请输入 y 或 n。"; exit 1 ;;
      esac
      ;;
    5)
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
  echo "请选择要安装的语言："
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
    echo "基础模式: 完全不读写 app.asar 或二进制完整性信息"
  fi
  echo
fi

NEEDS_SUDO=1
if [ "$ACTION" = "sync-skills" ] || [ "$ACTION" = "unsync-skills" ]; then
  NEEDS_SUDO=0
fi
if [ "$DRY_RUN" -eq 1 ]; then
  NEEDS_SUDO=0
fi

if [ "$(id -u)" -ne 0 ] && [ "$NEEDS_SUDO" -eq 1 ]; then
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
