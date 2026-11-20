#!/usr/bin/env bash
# Claude Desktop（Linux）中文补丁安装/卸载脚本
# 推荐从项目根目录的 install-linux.sh 进入（带菜单）；也可直接调用：
#   ./scripts/install_linux.sh install [zh-CN|zh-TW|zh-HK]   安装（默认 zh-CN）
#   ./scripts/install_linux.sh uninstall                      恢复原样
#
# 支持的安装布局：
#   - 官方 deb 包：/usr/lib/claude-desktop/resources（写入时按需 sudo）
#   - claude-desktop-rpm（https://github.com/ajithakdev/claude-desktop-rpm/，Fedora 等 RPM 发行版）：$CLAUDE_DESKTOP_PREFIX/lib/claude-desktop/resources
#     （默认 $HOME/.local/lib/claude-desktop/resources，无需 sudo）
#   - 其他位置：用 CLAUDE_RESOURCES 指定 resources 目录
# 未显式指定时优先采用正在运行的 Claude Desktop 所在目录，避免同机存在多份安装时改错。
#
# 说明:
#   - Claude 4.29+ 的前端在 ion-dist.asar 内；脚本解包、合并词表、注册语言白名单后重打包。
#     桌面壳层词库以官方 zh-Hans / zh-Hant 为基础，补全 app.asar 中的缺失译文。
#   - 以 Claude Desktop 5.x 为基准：4.x 没有 zh-Hans / zh-Hant 壳层词库，前端可汉化，
#     但菜单栏与官方账号页可能回落英文。
#   - 原始前端备份保存在 ~/.local/state/claude-desktop-zh-cn/<版本>@<安装路径摘要>/，
#     不放在应用目录内，因此 claude-desktop-rpm 的目录式升级不会连带删除备份；
#     同机存在多份安装时，各自的备份与 locale 原值互不覆盖。
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

# 状态按“版本 + 安装路径摘要”区分：同一台机器可能同时存在官方 deb 与
# claude-desktop-rpm 两份同版本安装，不能共用同一份备份或 locale 记录。
install_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$APP_RES" | sha256sum | cut -c1-12
  elif command -v cksum >/dev/null 2>&1; then
    printf '%s' "$APP_RES" | cksum | tr -s ' ' '-' | cut -c1-12
  else
    die "需要 sha256sum 或 cksum 生成安装路径摘要"
  fi
}

state_dir() {
  printf '%s/%s@%s\n' "$STATE_ROOT" "$VERSION" "$INSTALL_KEY"
}

locale_record() {
  printf '%s/locale-originals@%s.json\n' "$STATE_ROOT" "$INSTALL_KEY"
}

language_record() {
  printf '%s/language@%s\n' "$STATE_ROOT" "$INSTALL_KEY"
}

prepare_state_dir() {
  local target="$1" legacy="$STATE_ROOT/$VERSION"
  if [ -d "$legacy" ] && [ ! -e "$target" ]; then
    echo "迁移旧版备份目录: $legacy -> $target"
    mv "$legacy" "$target"
  fi
  mkdir -p "$target"
}

# 旧版把原始 locale 记录在版本目录内；版本目录随升级更换，记录会丢失，
# 因此迁移到与版本无关、按安装区分的文件。
migrate_locale_record() {
  local version_dir="$1" record legacy="$1/config-locales.json"
  record="$(locale_record)"
  if [ -f "$legacy" ] && [ ! -f "$record" ]; then
    mkdir -p "$STATE_ROOT"
    mv "$legacy" "$record"
  fi
}

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

desktop_status() {
  python3 "$PATCHER" --resources "$APP_RES" --desktop-status --desktop-state "$DESKTOP_STATE"
}

inspect_desktop() {
  DESKTOP_STATE="$STATE_ROOT/desktop@${INSTALL_KEY}.json"
  local status
  status="$(desktop_status)"
  read -r DESKTOP_STATUS DESKTOP_HASH DESKTOP_CURRENT_HASH <<< "$status"
}

check_desktop_unchanged() {
  local status
  status="$(desktop_status)"
  [ "$status" = "$DESKTOP_STATUS $DESKTOP_HASH $DESKTOP_CURRENT_HASH" ] ||
    die "操作期间 app.asar 已变化，请重试。"
}

lock_installation() {
  mkdir -p "$STATE_ROOT"
  exec {install_lock_fd}>"$STATE_ROOT/install@$INSTALL_KEY.lock"
  flock -n "$install_lock_fd" || die "该安装正在执行补丁安装或卸载: $APP_RES"
}

app_version() {
  local version=""
  if [ -s "$APP_DIR/.deb-version" ]; then
    version="$(tr -d '[:space:]' < "$APP_DIR/.deb-version")"
  elif command -v dpkg-query >/dev/null 2>&1; then
    version="$(dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || true)"
  fi
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi
  # 用状态记录中的原始摘要，让手工安装在替换壳层归档后仍能找到同一份备份。
  printf 'asar-%s\n' "${DESKTOP_HASH:0:16}"
}

# 4.x 的桌面壳层只有 zh-CN / zh-TW / zh-HK 词库，写入 zh-Hans / zh-Hant 后
# 前端是中文，但菜单栏与官方账号页会回落英文。这里提前提示，不阻止安装。
warn_unsupported_version() {
  local core="${VERSION##*:}" major
  case "$core" in
    [0-9]*) ;;
    *) return 0 ;;
  esac
  major="${core%%.*}"
  major="${major%%[!0-9]*}"
  [ -n "$major" ] || return 0
  if [ "$major" -lt 5 ]; then
    echo "警告: Claude Desktop $VERSION 低于 5.x。4.x 没有 zh-Hans / zh-Hant 壳层词库，" >&2
    echo "      前端会是中文，但菜单栏与官方账号页可能回落英文；建议升级到 5.x。" >&2
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
    if pgrep -f "$pattern" >/dev/null 2>&1; then
      die "Claude Desktop 仍在运行，请完全退出后重试。"
    fi
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

# 当前前端已被补丁修改、又没有同版本备份时不能继续：把补丁后的文件当成
# “原始文件”备份，卸载时就永远回不到官方版本了。
ensure_original_possible() {
  if python3 "$PATCHER" --resources "$APP_RES" --check-patched >/dev/null 2>&1; then
    die "当前前端已含补丁，但找不到同版本的原始备份。请先用 apt 或 claude-desktop-rpm（ajithakdev/claude-desktop-rpm）重装 Claude Desktop，再运行本脚本。"
  fi
}

backup_frontend() {
  local version_dir="$1"
  mkdir -p "$version_dir"

  if [ "$FRONTEND_MODE" = "asar" ]; then
    if [ ! -f "$version_dir/ion-dist.asar" ]; then
      ensure_original_possible
      echo "备份原始 ion-dist.asar（$(du -h "$APP_RES/ion-dist.asar" | cut -f1)）…"
      cp -a "$APP_RES/ion-dist.asar" "$version_dir/ion-dist.asar"
    else
      echo "复用已有原始备份: $version_dir/ion-dist.asar"
    fi
  else
    if [ ! -f "$version_dir/ion-dist.tar" ]; then
      ensure_original_possible
      echo "备份原始 ion-dist 目录…"
      tar -C "$APP_RES" -cf "$version_dir/ion-dist.tar" ion-dist
    else
      echo "复用已有原始备份: $version_dir/ion-dist.tar"
    fi
  fi

  printf '%s\n' "$VERSION" > "$version_dir/version"
  printf '%s\n' "$LANG_CODE" > "$version_dir/language"
}

check_desktop_origin() {
  [ "$DESKTOP_STATUS" = clean ] || return 0
  local backup status backups=()
  for backup in "$STATE_ROOT"/*@"$INSTALL_KEY"/app.asar "$STATE_ROOT/$VERSION/app.asar"; do
    [ ! -f "$backup" ] || backups+=("$backup")
  done
  if [ ! -e "$DESKTOP_STATE" ] && [ "${#backups[@]}" -eq 0 ]; then
    return 0
  fi
  # 完整的应用升级会同时换掉前端。若前端仍有补丁，就不能把无法识别的壳层当作原包。
  if ! python3 "$PATCHER" --resources "$APP_RES" --check-patched >/dev/null 2>&1; then
    return 0
  fi
  for backup in "${backups[@]}"; do
    if status="$(python3 "$PATCHER" --resources "${backup%/*}" --desktop-status)" &&
       [ "$status" = "clean $DESKTOP_HASH $DESKTOP_HASH" ]; then
      return 0
    fi
  done
  die "无法确认当前 app.asar 是原始文件还是壳层补丁。请恢复匹配的状态记录，或重装 Claude Desktop。"
}

require_desktop_backup() {
  local version_dir="$1" status
  [ -f "$version_dir/app.asar" ] || die "当前壳层已含补丁，但找不到原始 app.asar 备份。请重装 Claude Desktop。"
  status="$(python3 "$PATCHER" --resources "$version_dir" --desktop-status)"
  [ "$status" = "clean $DESKTOP_HASH $DESKTOP_HASH" ] || die "app.asar 备份与当前壳层不匹配。请重装 Claude Desktop。"
}

prepare_desktop_patch() {
  local version_dir="$1" output="$2" source="$APP_RES"
  if [ "$DESKTOP_STATUS" = patched ]; then
    require_desktop_backup "$version_dir"
    source="$version_dir"
  fi
  python3 "$PATCHER" --resources "$source" --patch-desktop --lang "$LANG_CODE" --output "$output"
  if [ -f "$output" ] && [ "$DESKTOP_STATUS" = clean ]; then
    cp -p "$APP_RES/app.asar" "$version_dir/app.asar.tmp"
    check_desktop_unchanged
    mv -f "$version_dir/app.asar.tmp" "$version_dir/app.asar"
  fi
}

replace_desktop_archive() {
  local source="$1"
  privileged install -m 644 "$source" "$APP_RES/.app.asar.zh-new"
  privileged mv -f "$APP_RES/.app.asar.zh-new" "$APP_RES/app.asar"
}

discard_stale_state() {
  local current="$1" entry name
  for entry in "$STATE_ROOT"/*/; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    # 只清理同一安装（安装路径摘要相同）的旧版本，其他安装的备份必须保留。
    case "$name" in
      *@"$INSTALL_KEY") ;;
      *) continue ;;
    esac
    [ "$(cd "$entry" && pwd)" = "$(cd "$current" && pwd)" ] && continue
    echo "检测到应用版本变化，删除旧版本备份: $name"
    rm -rf "$entry"
  done
}

save_config_locales() {
  local record
  record="$(locale_record)"
  # 只在第一次安装时记录：重复运行安装时配置里已经是 zh-Hans / zh-Hant，
  # 再“记录”一次会把补丁写入的值当成原值，卸载就无法恢复。
  if [ -f "$record" ]; then
    echo "复用已有 locale 记录: $record"
    return 0
  fi
  mkdir -p "$STATE_ROOT"
  python3 - "$record" "$HOME/.config/Claude/config.json" "$HOME/.config/Claude-3p/config.json" <<'PY'
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
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"警告: 无法更新 locale，配置无效 {path}: {exc}", file=sys.stderr)
        continue
    data["locale"] = locale
    try:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent="\t")
    except OSError as exc:
        print(f"警告: 无法写入配置 {path}: {exc}", file=sys.stderr)
        continue
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
  [ "$(id -u)" -eq 0 ] && die "请以普通用户运行本脚本（需要时脚本会自动调用 sudo）"
  INSTALL_KEY="$(install_key)"
  lock_installation
  inspect_desktop
  VERSION="$(app_version)"
  check_desktop_origin
  echo "安装目录: $APP_DIR"
  echo "Claude 版本: $VERSION"
  echo "前端布局: $FRONTEND_MODE"
  warn_unsupported_version

  stop_claude
  check_staged_update

  local version_dir
  version_dir="$(state_dir)"

  echo "[1/4] 检查备份并准备壳层词表"
  prepare_state_dir "$version_dir"
  migrate_locale_record "$version_dir"
  backup_frontend "$version_dir"
  save_config_locales

  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT
  prepare_desktop_patch "$version_dir" "$tmp/app.asar"

  echo "[2/4] 生成中文前端（$LANG_CODE -> ${TARGET_LANG}）"
  mkdir -p "$tmp/resources"
  if [ "$FRONTEND_MODE" = "asar" ]; then
    cp -a "$version_dir/ion-dist.asar" "$tmp/resources/ion-dist.asar"
    python3 "$PATCHER" --resources "$tmp/resources" --lang "$LANG_CODE" --output "$tmp/ion-dist.asar"
  else
    tar -C "$tmp" -xf "$version_dir/ion-dist.tar"
    python3 "$PATCHER" --resources "$tmp" --lang "$LANG_CODE" --output "$tmp/ion-dist-patched"
  fi

  stop_claude
  if [ -f "$tmp/app.asar" ]; then
    python3 "$PATCHER" --resources "$APP_RES" --desktop-state "$DESKTOP_STATE" \
      --record-desktop-patch "$tmp/app.asar" --expected-desktop-sha256 "$DESKTOP_CURRENT_HASH"
  else
    check_desktop_unchanged
  fi
  echo "[3/4] 安装前端和壳层词表"
  if [ "$FRONTEND_MODE" = asar ]; then
    privileged install -m 644 "$tmp/ion-dist.asar" "$APP_RES/.ion-dist.asar.zh-new"
    privileged mv -f "$APP_RES/.ion-dist.asar.zh-new" "$APP_RES/ion-dist.asar"
  else
    privileged rm -rf "$APP_RES/ion-dist.zh-new"
    privileged cp -a "$tmp/ion-dist-patched" "$APP_RES/ion-dist.zh-new"
    privileged rm -rf "$APP_RES/ion-dist"
    privileged mv "$APP_RES/ion-dist.zh-new" "$APP_RES/ion-dist"
  fi

  if [ -f "$tmp/app.asar" ]; then
    replace_desktop_archive "$tmp/app.asar"
  else
    if [ "$DESKTOP_STATUS" = patched ]; then
      # 切换到无需壳层补丁的语言时，恢复原包后再清理状态。
      replace_desktop_archive "$version_dir/app.asar"
    fi
    rm -f "$DESKTOP_STATE"
  fi

  echo "[4/4] 写入用户配置 locale=$TARGET_LANG"
  write_locale "$TARGET_LANG"
  printf '%s\n' "$LANG_CODE" > "$(language_record)"
  discard_stale_state "$version_dir"

  echo
  echo "完成！请重新打开 Claude Desktop。"
  echo "原始资源备份: $version_dir"
}

uninstall_patch() {
  detect_resources
  detect_frontend_mode
  setup_privileges
  INSTALL_KEY="$(install_key)"
  lock_installation
  inspect_desktop
  VERSION="$(app_version)"
  check_desktop_origin
  stop_claude

  local version_dir
  version_dir="$(state_dir)"
  prepare_state_dir "$version_dir"
  migrate_locale_record "$version_dir"
  if [ "$DESKTOP_STATUS" = patched ]; then
    require_desktop_backup "$version_dir"
  fi

  check_desktop_unchanged
  echo "[1/3] 还原前端和壳层词表"
  if [ "$FRONTEND_MODE" = "asar" ] && [ -f "$version_dir/ion-dist.asar" ]; then
    privileged install -m 644 "$version_dir/ion-dist.asar" "$APP_RES/.ion-dist.asar.zh-restore"
    privileged mv -f "$APP_RES/.ion-dist.asar.zh-restore" "$APP_RES/ion-dist.asar"
    echo "  已还原: ion-dist.asar"
  elif [ "$FRONTEND_MODE" = "directory" ] && [ -f "$version_dir/ion-dist.tar" ]; then
    # 先解到临时目录再整体替换：只读的 deb 安装需要提权；解包失败时也不会
    # 先删掉现有的 ion-dist。
    local restore_dir="$APP_RES/.ion-dist.zh-restore"
    privileged rm -rf "$restore_dir"
    privileged mkdir -p "$restore_dir"
    privileged tar -C "$restore_dir" -xf "$version_dir/ion-dist.tar"
    privileged rm -rf "$APP_RES/ion-dist"
    privileged mv "$restore_dir/ion-dist" "$APP_RES/ion-dist"
    privileged rm -rf "$restore_dir"
    echo "  已还原: ion-dist 目录"
  elif python3 "$PATCHER" --resources "$APP_RES" --check-patched >/dev/null 2>&1; then
    echo "警告: 当前前端已含补丁，但没有同版本原始备份（应用可能已升级）。" >&2
    echo "      请用 apt 或 claude-desktop-rpm（ajithakdev/claude-desktop-rpm）重装 Claude Desktop 以恢复官方文件。" >&2
  else
    echo "  未找到补丁备份，当前前端已是官方文件。"
  fi
  if [ "$DESKTOP_STATUS" = patched ]; then
    replace_desktop_archive "$version_dir/app.asar"
    echo "  已还原: app.asar"
  fi

  echo "[2/3] 恢复用户 locale"
  # 用安装时记录的语言，而不是卸载时的默认参数：zh-TW / zh-HK 写成 zh-Hant，
  # 若按默认 zh-CN 推导成 zh-Hans 会比对不上，locale 就不会复位。
  local installed_lang="$LANG_CODE" locale_target lang_record
  lang_record="$(language_record)"
  if [ -s "$lang_record" ]; then
    installed_lang="$(tr -d '[:space:]' < "$lang_record")"
  elif [ -s "$version_dir/language" ]; then
    installed_lang="$(tr -d '[:space:]' < "$version_dir/language")"
  fi
  case "$installed_lang" in
    zh-CN) locale_target="zh-Hans" ;;
    *) locale_target="zh-Hant" ;;
  esac
  local record
  record="$(locale_record)"
  if python3 - "$record" "$locale_target" \
      "$HOME/.config/Claude/config.json" "$HOME/.config/Claude-3p/config.json" <<'PY'
import json
import os
import sys

record_path, target, *configs = sys.argv[1:]
saved = {}
if os.path.isfile(record_path):
    try:
        with open(record_path, encoding="utf-8") as handle:
            saved = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"警告: 无法读取 locale 记录 {record_path}: {exc}", file=sys.stderr)
        saved = {}
# 安装时已存在的配置恢复原值；安装后才创建的配置也要一并检查，避免补丁
# 写入的 locale 残留在另一份配置里。
failed = False
for config in dict.fromkeys([*saved, *configs]):
    try:
        with open(config, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        continue
    except (OSError, json.JSONDecodeError) as exc:
        print(f"警告: 无法读取配置 {config}: {exc}", file=sys.stderr)
        failed = True
        continue
    if data.get("locale") != target:
        continue
    data["locale"] = saved.get(config) or "en-US"
    try:
        with open(config, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent="\t")
    except OSError as exc:
        print(f"警告: 无法写入配置 {config}: {exc}", file=sys.stderr)
        failed = True
        continue
    print(f"已恢复 locale: {config} -> {data['locale']}")
raise SystemExit(1 if failed else 0)
PY
  then
    rm -f "$record"
  else
    echo "警告: locale 未能完全恢复，保留记录: $record" >&2
  fi

  echo "[3/3] 清理备份"
  # 只清理本安装（按安装路径区分）的状态；同机其他安装的备份必须保留。
  rm -rf "$STATE_ROOT"/*@"$INSTALL_KEY"
  rm -f "$DESKTOP_STATE"
  echo "完成！请重新打开 Claude Desktop。"
}

case "$ACTION" in
  install) install_patch ;;
  uninstall) uninstall_patch ;;
  *) echo "用法: $0 install [zh-CN|zh-TW|zh-HK] | uninstall"; exit 1 ;;
esac
