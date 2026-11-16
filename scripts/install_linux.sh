#!/usr/bin/env bash
# Claude Desktop（Linux）中文补丁安装/卸载脚本
# 推荐从项目根目录的 install-linux.sh 进入（带菜单）；也可直接调用：
#   ./scripts/install_linux.sh install [zh-CN|zh-TW|zh-HK]   安装（默认 zh-CN）
#   ./scripts/install_linux.sh uninstall                      恢复原样
#
# 支持的安装布局：
#   - 官方 deb 包：/usr/lib/claude-desktop/resources（写入时按需 sudo）
#   - claude-desktop-rpm（Fedora 等 RPM 发行版）：$CLAUDE_DESKTOP_PREFIX/lib/claude-desktop/resources
#     （默认 $HOME/.local/lib/claude-desktop/resources，无需 sudo）
#   - 其他位置：用 CLAUDE_RESOURCES 指定 resources 目录
# 未显式指定时优先采用正在运行的 Claude Desktop 所在目录，避免同机存在多份安装时改错。
#
# 说明:
#   - Claude 4.29+ 的前端在 ion-dist.asar 内；脚本解包、合并词表、注册语言白名单后重打包。
#     桌面壳层词库使用官方自带的 zh-Hans / zh-Hant，不再改写 app.asar。
#   - 原始前端备份保存在 ~/.local/state/claude-desktop-zh-cn/<版本>/，不放在应用目录内，
#     因此 claude-desktop-rpm 的目录式升级不会连带删除备份。
#   - 应用升级后需重新运行本脚本。

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER="$REPO_DIR/scripts/patch_linux_asar.py"
PREFIX="${CLAUDE_DESKTOP_PREFIX:-$HOME/.local}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/claude-desktop-zh-cn"
ACTION="${1:-install}"
LANG_CODE="${2:-zh-CN}"

case "$LANG_CODE" in
  zh-CN|zh-TW|zh-HK) ;;
  *) echo "不支持的语言: $LANG_CODE（可选 zh-CN / zh-TW / zh-HK）"; exit 1 ;;
esac

# 运行时语言代码：桌面壳层词库使用官方的 BCP-47 代码。
case "$LANG_CODE" in
  zh-CN) TARGET_LANG="zh-Hans" ;;
  *) TARGET_LANG="zh-Hant" ;;
esac

die() { echo "错误: $*" >&2; exit 1; }

running_resources() {
  local exe
  for exe in /proc/[0-9]*/exe; do
    exe="$(readlink -f "$exe" 2>/dev/null)" || continue
    case "$exe" in
      */lib/claude-desktop/claude-desktop)
        printf '%s\n' "$(dirname "$exe")/resources"
        return 0
        ;;
    esac
  done
  return 1
}

detect_resources() {
  if [ -n "${CLAUDE_RESOURCES:-}" ]; then
    APP_RES="$CLAUDE_RESOURCES"
  else
    local candidates=()
    if [ -n "${CLAUDE_DESKTOP_PREFIX:-}" ]; then
      candidates+=("$CLAUDE_DESKTOP_PREFIX/lib/claude-desktop/resources")
    fi
    local running
    if running="$(running_resources)"; then
      candidates+=("$running")
    fi
    candidates+=("$HOME/.local/lib/claude-desktop/resources" "/usr/lib/claude-desktop/resources")
    local candidate
    for candidate in "${candidates[@]}"; do
      if [ -f "$candidate/app.asar" ]; then
        APP_RES="$candidate"
        break
      fi
    done
  fi
  [ -n "${APP_RES:-}" ] || die "未找到 Claude Desktop 资源目录。已尝试 $HOME/.local/lib/claude-desktop/resources 与 /usr/lib/claude-desktop/resources；可用 CLAUDE_RESOURCES 指定。"
  [ -f "$APP_RES/app.asar" ] || die "资源目录不完整（缺 app.asar）: $APP_RES"
  APP_DIR="$(dirname "$APP_RES")"
}

app_version() {
  if [ -s "$APP_DIR/.deb-version" ]; then
    tr -d '[:space:]' < "$APP_DIR/.deb-version"
  elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null; then
    :
  else
    echo "unknown"
  fi
}

# 关闭正在运行的 Claude Desktop：只匹配安装目录下的进程（主程序、各子进程、
# crashpad、cowork helper）。不能用 pkill -f "claude-desktop"：-f 匹配完整命令行，
# 本项目目录名 claude-desktop-zh-cn 也会被命中，从绝对路径运行时会误杀本脚本自身
# 或打开该目录的编辑器。
stop_claude() {
  local pattern
  pattern="^$(printf '%s' "$APP_DIR" | sed 's/[][\.*^$()+?{}|]/\\&/g')/"
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    echo "Claude Desktop 正在运行，尝试关闭…"
    pkill -f "$pattern" || true
    sleep 2
  fi
}

check_staged_update() {
  if [ -d "$PREFIX/lib/claude-desktop.staged" ]; then
    echo "警告: 检测到待应用的新版本（$PREFIX/lib/claude-desktop.staged）。" >&2
    echo "      Claude 下次启动时会替换整个安装目录，从而覆盖本补丁。" >&2
    echo "      建议先启动一次 Claude 完成升级，再重新运行本脚本。" >&2
  fi
}

setup_privileges() {
  if [ -w "$APP_RES" ]; then
    NEED_SUDO=0
  else
    NEED_SUDO=1
    command -v sudo >/dev/null 2>&1 || die "没有写入权限，且系统未安装 sudo: $APP_RES"
    echo "目标目录不可写，将在需要时调用 sudo: $APP_RES"
  fi
}

privileged() {
  if [ "$NEED_SUDO" -eq 1 ]; then
    sudo "$@"
  else
    "$@"
  fi
}

detect_frontend_mode() {
  if [ -f "$APP_RES/ion-dist.asar" ]; then
    FRONTEND_MODE="asar"
  elif [ -d "$APP_RES/ion-dist" ] && find "$APP_RES/ion-dist" -name '*.js' -print -quit 2>/dev/null | grep -q .; then
    FRONTEND_MODE="directory"
  else
    die "未找到前端资源（ion-dist.asar 或 ion-dist 目录）: $APP_RES"
  fi
}

backup_frontend() {
  local version_dir="$STATE_ROOT/$VERSION"
  mkdir -p "$version_dir"

  if [ "$FRONTEND_MODE" = "asar" ]; then
    if [ ! -f "$version_dir/ion-dist.asar" ]; then
      python3 "$PATCHER" --resources "$APP_RES" --check-patched >/dev/null 2>&1 \
        && die "当前前端已含补丁，但找不到同版本的原始备份。请先用 apt 或 claude-desktop-rpm 重装 Claude Desktop，再运行本脚本。"
      echo "备份原始 ion-dist.asar（$(du -h "$APP_RES/ion-dist.asar" | cut -f1)）…"
      cp -a "$APP_RES/ion-dist.asar" "$version_dir/ion-dist.asar"
    else
      echo "复用已有原始备份: $version_dir/ion-dist.asar"
    fi
  else
    if [ ! -f "$version_dir/ion-dist.tar" ]; then
      echo "备份原始 ion-dist 目录…"
      tar -C "$APP_RES" -cf "$version_dir/ion-dist.tar" ion-dist
    else
      echo "复用已有原始备份: $version_dir/ion-dist.tar"
    fi
  fi

  printf '%s\n' "$VERSION" > "$version_dir/version"
  printf '%s\n' "$LANG_CODE" > "$version_dir/language"
}

discard_stale_state() {
  local current_dir="$STATE_ROOT/$VERSION"
  local entry
  for entry in "$STATE_ROOT"/*/; do
    [ -d "$entry" ] || continue
    [ "$(cd "$entry" && pwd)" = "$(cd "$current_dir" && pwd)" ] && continue
    echo "检测到应用版本变化，删除旧版本备份: $(basename "$entry")"
    rm -rf "$entry"
  done
}

save_config_locales() {
  local version_dir="$STATE_ROOT/$VERSION"
  mkdir -p "$version_dir"
  python3 - "$version_dir/config-locales.json" "$HOME/.config/Claude/config.json" "$HOME/.config/Claude-3p/config.json" <<'PY'
import json
import os
import sys

out_path, *configs = sys.argv[1:]
saved = {}
for path in configs:
    if not os.path.isfile(path):
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            saved[path] = json.load(handle).get("locale")
    except (OSError, json.JSONDecodeError):
        continue
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(saved, handle, ensure_ascii=False, indent=2)
PY
}

write_locale() {
  local locale="$1"
  python3 - "$locale" "$HOME/.config/Claude/config.json" "$HOME/.config/Claude-3p/config.json" <<'PY'
import json
import os
import sys

locale, *configs = sys.argv[1:]
for path in configs:
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    data["locale"] = locale
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
    print(f"已更新 locale: {path} -> {data['locale']}")
PY
}

# 注意：函数名不要用 install / uninstall。它们是系统命令名，而 privileged 会执行
# `install -m 644 ...`，同名函数会被优先解析，导致无限递归。
install_patch() {
  command -v python3 >/dev/null 2>&1 || die "需要 python3"
  [ -f "$PATCHER" ] || die "缺少 $PATCHER"

  detect_resources
  detect_frontend_mode
  setup_privileges
  VERSION="$(app_version)"
  echo "安装目录: $APP_DIR"
  echo "Claude 版本: $VERSION"
  echo "前端布局: $FRONTEND_MODE"

  [ "$(id -u)" -eq 0 ] && die "请以普通用户运行本脚本（需要时脚本会自动调用 sudo）"
  stop_claude
  check_staged_update
  discard_stale_state

  local version_dir="$STATE_ROOT/$VERSION"

  echo "[1/4] 检查并备份原始前端"
  backup_frontend
  save_config_locales

  echo "[2/4] 生成中文前端（$LANG_CODE -> $TARGET_LANG）"
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT
  mkdir -p "$tmp/resources"
  if [ "$FRONTEND_MODE" = "asar" ]; then
    cp -a "$version_dir/ion-dist.asar" "$tmp/resources/ion-dist.asar"
    python3 "$PATCHER" --resources "$tmp/resources" --lang "$LANG_CODE" --output "$tmp/ion-dist.asar"
    echo "[3/4] 安装 ion-dist.asar"
    privileged install -m 644 "$tmp/ion-dist.asar" "$APP_RES/.ion-dist.asar.zh-new"
    privileged mv -f "$APP_RES/.ion-dist.asar.zh-new" "$APP_RES/ion-dist.asar"
  else
    tar -C "$tmp" -xf "$version_dir/ion-dist.tar"
    python3 "$PATCHER" --resources "$tmp" --lang "$LANG_CODE" --output "$tmp/ion-dist-patched"
    echo "[3/4] 安装 ion-dist 目录"
    privileged rm -rf "$tmp/ion-dist.zh-new"
    privileged cp -a "$tmp/ion-dist-patched" "$APP_RES/ion-dist.zh-new"
    privileged rm -rf "$APP_RES/ion-dist"
    privileged mv "$APP_RES/ion-dist.zh-new" "$APP_RES/ion-dist"
  fi

  echo "[4/4] 写入用户配置 locale=$TARGET_LANG"
  write_locale "$TARGET_LANG"

  echo
  echo "完成！请重新打开 Claude Desktop。"
  echo "原始前端备份: $version_dir"
}

uninstall_patch() {
  detect_resources
  detect_frontend_mode
  setup_privileges
  VERSION="$(app_version)"
  stop_claude

  local version_dir="$STATE_ROOT/$VERSION"
  local restored=0

  echo "[1/3] 还原前端"
  if [ "$FRONTEND_MODE" = "asar" ] && [ -f "$version_dir/ion-dist.asar" ]; then
    privileged install -m 644 "$version_dir/ion-dist.asar" "$APP_RES/.ion-dist.asar.zh-restore"
    privileged mv -f "$APP_RES/.ion-dist.asar.zh-restore" "$APP_RES/ion-dist.asar"
    restored=1
    echo "  已还原: ion-dist.asar"
  elif [ "$FRONTEND_MODE" = "directory" ] && [ -f "$version_dir/ion-dist.tar" ]; then
    tar -C "$APP_RES" -xf "$version_dir/ion-dist.tar"
    restored=1
    echo "  已还原: ion-dist 目录"
  elif python3 "$PATCHER" --resources "$APP_RES" --check-patched >/dev/null 2>&1; then
    echo "警告: 当前前端已含补丁，但没有同版本原始备份（应用可能已升级）。" >&2
    echo "      请用 apt 或 claude-desktop-rpm 重装 Claude Desktop 以恢复官方文件。" >&2
  else
    echo "  未找到补丁备份，当前前端已是官方文件。"
  fi

  echo "[2/3] 恢复用户 locale"
  if [ -f "$version_dir/config-locales.json" ]; then
    python3 - "$version_dir/config-locales.json" "$TARGET_LANG" <<'PY'
import json
import sys

path, target = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    saved = json.load(handle)
for config, original in saved.items():
    try:
        with open(config, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        continue
    if data.get("locale") != target:
        continue
    data["locale"] = original or "en-US"
    with open(config, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
    print(f"已恢复 locale: {config} -> {data['locale']}")
PY
  else
    write_locale en-US
  fi

  echo "[3/3] 清理备份"
  rm -rf "$STATE_ROOT"/*/
  echo "完成！请重新打开 Claude Desktop。"
}

case "$ACTION" in
  install) install_patch ;;
  uninstall) uninstall_patch ;;
  *) echo "用法: $0 install [zh-CN|zh-TW|zh-HK] | uninstall"; exit 1 ;;
esac
