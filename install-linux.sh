#!/usr/bin/env bash
# Claude Desktop 中文补丁 · Linux（官方 deb 包安装）入口
#
# 直接运行会显示菜单：
#   ./install-linux.sh
# 也可以跳过菜单直接调用（参数原样传给 scripts/install_linux.sh）：
#   ./install-linux.sh install [zh-CN|zh-TW|zh-HK]
#   ./install-linux.sh uninstall
#
# 环境变量：CLAUDE_ACTION=install|uninstall、CLAUDE_LANG=zh-CN|zh-TW|zh-HK
# 可跳过对应菜单；CLAUDE_ZH_SKIP_UPDATE_CHECK=1 跳过新版本检查。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$DIR/scripts/install_linux.sh"

if [ ! -f "$INSTALLER" ]; then
  echo "未找到安装脚本: $INSTALLER"
  echo "请下载或克隆完整项目后，在项目目录中运行本脚本。"
  exit 1
fi

check_release_update() {
  if [ "${CLAUDE_ZH_SKIP_UPDATE_CHECK:-0}" = "1" ] || ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  python3 - "$DIR/resources/release.json" 2>/dev/null <<'PY' || true
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

if [ "$#" -gt 0 ]; then
  exec bash "$INSTALLER" "$@"
fi

echo "Claude Desktop 中文补丁（Linux）"
echo "目录: $DIR"
echo

ACTION="${CLAUDE_ACTION:-}"
if [ -z "$ACTION" ]; then
  echo "请选择操作："
  echo "  [1] 安装中文补丁（在线页面 DOM 汉化 + 锁定中文，需要 sudo 密码）"
  echo "  [2] 恢复原样 / 卸载补丁"
  echo
  read -rp "请输入选项 [1/2，默认 1]: " action_choice || action_choice=""
  case "${action_choice:-1}" in
    2) ACTION="uninstall" ;;
    *) ACTION="install" ;;
  esac
  echo
fi

case "$ACTION" in
  restore|uninstall)
    exec bash "$INSTALLER" uninstall
    ;;
  install) ;;
  *)
    echo "无效的操作: $ACTION（可选 install / uninstall）"
    exit 1
    ;;
esac

LANG_CODE="${CLAUDE_LANG:-}"
if [ -z "$LANG_CODE" ]; then
  echo "请选择要安装的语言："
  echo "  [1] 简体中文"
  echo "  [2] 繁体中文（中国台湾）"
  echo "  [3] 繁体中文（中国香港）"
  echo
  read -rp "请输入选项 [1/2/3，默认 1]: " choice || choice=""
  case "${choice:-1}" in
    2) LANG_CODE="zh-TW" ;;
    3) LANG_CODE="zh-HK" ;;
    *) LANG_CODE="zh-CN" ;;
  esac
  echo
fi

echo "选择的语言: $LANG_CODE"
echo "运行时会关闭正在运行的 Claude Desktop，并按提示请求 sudo 密码。"
echo
exec bash "$INSTALLER" install "$LANG_CODE"
