#!/usr/bin/env bash
# Claude Desktop（Linux，官方 deb 包安装）中文补丁安装/卸载脚本
# 推荐从项目根目录的 install-linux.sh 进入（带菜单）；也可直接调用：
#   ./scripts/install_linux.sh install [zh-CN|zh-TW|zh-HK]   安装（默认 zh-CN）
#   ./scripts/install_linux.sh uninstall                      恢复原样
# 说明:
#   - 需要 sudo 权限写入 Claude Desktop 安装目录（默认 /usr/lib/claude-desktop）
#   - 会修改 app.asar（在线 claude.ai 页面 DOM 汉化 + 锁定 locale），并安装语言资源、
#     注册语言白名单、写入用户 locale 配置；修改前自动备份，卸载时还原
#   - Claude Desktop 更新后需重新运行本脚本

set -euo pipefail

APP_RES="${CLAUDE_RESOURCES:-/usr/lib/claude-desktop/resources}"
APP_DIR="$(dirname "$APP_RES")"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$REPO_DIR/resources"
BACKUP_DIR="$RES_DIR/.zh-cn-backups-linux"
ACTION="${1:-install}"
LANG_CODE="${2:-zh-CN}"

case "$LANG_CODE" in
  zh-CN) SUFFIX="zh-CN" ;;
  zh-TW) SUFFIX="zh-TW" ;;
  zh-HK) SUFFIX="zh-HK" ;;
  *) echo "不支持的语言: $LANG_CODE（可选 zh-CN / zh-TW / zh-HK）"; exit 1 ;;
esac

FRONTEND_SRC="$RES_DIR/frontend-$SUFFIX.json"
DESKTOP_SRC="$RES_DIR/desktop-$SUFFIX.json"

BASE_LIST='"en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'
LABEL_PATCH=';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁體中文（香港）":t==="zh-TW"?"繁體中文（台灣）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'

die() { echo "错误: $*" >&2; exit 1; }

[ -d "$APP_RES" ] || die "未找到 Claude Desktop 资源目录 $APP_RES（可用 CLAUDE_RESOURCES 环境变量指定）"
[ "$(id -u)" -eq 0 ] && die "请以普通用户运行本脚本（需要时会自动调用 sudo）"

# 关闭正在运行的 Claude Desktop：只匹配安装目录下的进程（主程序、各子进程、
# crashpad、cowork helper）。不能用 pkill -f "claude-desktop"：-f 匹配完整命令行，
# 本项目目录名 claude-desktop-zh-cn 也会被命中，从绝对路径运行时会误杀本脚本自身
# 或打开该目录的编辑器。
APP_PROC_PATTERN="^$(printf '%s' "$APP_DIR" | sed 's/[][\.*^$()+?{}|]/\\&/g')/"
if pgrep -f "$APP_PROC_PATTERN" >/dev/null 2>&1; then
  echo "Claude Desktop 正在运行，尝试关闭…"
  pkill -f "$APP_PROC_PATTERN" || true
  sleep 2
fi

find_bundle_files() {
  grep -rlF "$BASE_LIST" "$APP_RES/ion-dist" 2>/dev/null | grep -v '\.zh-orig' || true
}

app_version() {
  cat "$APP_DIR/version" 2>/dev/null \
    || dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null \
    || echo "unknown"
}

# 应用升级后，deb 会替换 app.asar 和前端 bundle，但 *.zh-orig 备份会残留为
# 旧版本文件。若拿旧备份重打补丁，会把旧版程序装回去。因此备份时记录版本号，
# 版本不一致就丢弃全部旧备份，从当前（升级后全新的）文件重新备份。
discard_stale_backups() {
  local cur_ver stored_ver
  cur_ver="$(app_version)"
  stored_ver="$(cat "$APP_RES/.zh-orig-version" 2>/dev/null || echo "")"
  if [ "$stored_ver" != "$cur_ver" ]; then
    if find "$APP_RES" -name "*.zh-orig*" -print -quit 2>/dev/null | grep -q .; then
      echo "检测到应用版本变化（$stored_ver -> $cur_ver），丢弃旧版本备份"
      sudo find "$APP_RES" -name "*.zh-orig*" -delete
    fi
    # 防呆：版本变化后当前 app.asar 应是未打补丁的原版
    if grep -q "__claudeZhOnlineLocaleMain" "$APP_RES/app.asar" 2>/dev/null; then
      die "当前 app.asar 已含补丁但没有对应版本的原始备份，请先重装 claude-desktop deb 包再运行本脚本"
    fi
  fi
  echo "$cur_ver" | sudo tee "$APP_RES/.zh-orig-version" >/dev/null
}

merge_json() {
  # merge_json <base.json> <overlay.json> <out.json>  — base 为当前版本英文文件，overlay 覆盖同名 key
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
base_p, overlay_p, out_p = sys.argv[1:4]
base = json.load(open(base_p))
overlay = json.load(open(overlay_p))
merged = dict(base)
for k, v in overlay.items():
    if k in merged:
        merged[k] = v
json.dump(merged, open(out_p, "w"), ensure_ascii=False, indent=2)
PY
}

install() {
  command -v python3 >/dev/null || die "需要 python3"
  [ -f "$FRONTEND_SRC" ] || die "缺少 $FRONTEND_SRC"
  [ -f "$DESKTOP_SRC" ] || die "缺少 $DESKTOP_SRC"

  local ts stamp_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  stamp_dir="$BACKUP_DIR/$ts"
  mkdir -p "$stamp_dir"
  local tmp; tmp="$(mktemp -d)"

  discard_stale_backups

  echo "[1/5] 生成语言文件（与当前版本英文合并，新增 key 保留英文）"
  merge_json "$APP_RES/ion-dist/i18n/en-US.json" "$FRONTEND_SRC" "$tmp/frontend.json"
  merge_json "$APP_RES/en-US.json" "$DESKTOP_SRC" "$tmp/desktop.json"
  # overrides：en-US 无此文件时，用任一现有语言的 overrides 作为 key 模板，
  # 值取合并后的翻译（有中文用中文，没有保留英文原文）
  local ov_template=""
  for cand in "$APP_RES/ion-dist/i18n/en-US.overrides.json" "$APP_RES"/ion-dist/i18n/*.overrides.json; do
    [ -f "$cand" ] && { ov_template="$cand"; break; }
  done
  if [ -n "$ov_template" ]; then
    python3 - "$ov_template" "$tmp/frontend.json" "$tmp/overrides.json" <<'PY'
import json, sys
tpl_p, merged_p, out_p = sys.argv[1:4]
tpl = json.load(open(tpl_p))
merged = json.load(open(merged_p))
out = {k: merged[k] for k in tpl if k in merged}
json.dump(out, open(out_p, "w"), ensure_ascii=False, indent=2)
PY
  fi

  echo "[2/5] 安装语言文件到 $APP_RES（需要 sudo）"
  sudo install -m 644 "$tmp/frontend.json" "$APP_RES/ion-dist/i18n/$SUFFIX.json"
  sudo install -m 644 "$tmp/desktop.json" "$APP_RES/$SUFFIX.json"
  [ -f "$tmp/overrides.json" ] && sudo install -m 644 "$tmp/overrides.json" "$APP_RES/ion-dist/i18n/$SUFFIX.overrides.json"

  echo "[3/5] 注册语言白名单并注入语言名称补丁"
  local patched=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$f.zh-orig" ]; then
      sudo cp -a "$f" "$f.zh-orig"
      cp -a "$f" "$stamp_dir/$(basename "$f")"
    fi
    sudo python3 - "$f" "$SUFFIX" "$BASE_LIST" "$LABEL_PATCH" <<'PY'
import sys
path, lang, base_list, label_patch = sys.argv[1:5]
s = open(path, encoding="utf-8").read()
needle = "[" + base_list
if needle + ',"' + lang + '"' not in s:
    s = s.replace(needle, needle + ',"' + lang + '"')
if "__claudeZhLabelPatch" not in s:
    s += "\n" + label_patch
open(path, "w", encoding="utf-8").write(s)
PY
    patched=$((patched+1))
    echo "  已修补: $(basename "$f")"
  done < <(find_bundle_files)
  [ "$patched" -gt 0 ] || die "未找到语言白名单，Claude Desktop 版本可能已变化，请更新本项目"

  echo "[4/5] 修补 app.asar（在线 claude.ai 页面 DOM 中文化 + locale 锁定）"
  if [ ! -f "$APP_RES/app.asar.zh-orig" ]; then
    sudo cp -a "$APP_RES/app.asar" "$APP_RES/app.asar.zh-orig"
  fi
  # 始终基于原始 asar 重打补丁，保证脚本可重复运行
  cp "$APP_RES/app.asar.zh-orig" "$tmp/app.asar"
  python3 "$REPO_DIR/scripts/patch_linux_asar.py" "$tmp/app.asar" "$SUFFIX" "$APP_RES"
  sudo install -m 644 "$tmp/app.asar" "$APP_RES/app.asar"

  echo "[5/5] 写入用户配置 locale=$SUFFIX"
  python3 - "$HOME/.config/Claude/config.json" "$SUFFIX" <<'PY'
import json, sys, os
path, lang = sys.argv[1:3]
cfg = {}
if os.path.exists(path):
    cfg = json.load(open(path))
cfg["locale"] = lang
json.dump(cfg, open(path, "w"), ensure_ascii=False, indent="\t")
PY
  rm -rf "$tmp"
  echo
  echo "完成！请重新打开 Claude Desktop。如未生效，在左下角账号菜单选择 Language -> 中文。"
  echo "备份位于: $stamp_dir 及各 bundle 旁的 *.zh-orig 文件"
}

uninstall() {
  echo "[1/4] 移除语言文件"
  for lang in zh-CN zh-TW zh-HK; do
    sudo rm -f "$APP_RES/ion-dist/i18n/$lang.json" "$APP_RES/ion-dist/i18n/$lang.overrides.json" "$APP_RES/$lang.json"
  done
  echo "[2/4] 还原前端 bundle"
  local restored=0
  while IFS= read -r orig; do
    [ -n "$orig" ] || continue
    sudo mv "$orig" "${orig%.zh-orig}"
    restored=$((restored+1))
    echo "  已还原: $(basename "${orig%.zh-orig}")"
  done < <(find "$APP_RES/ion-dist" -name "*.zh-orig" 2>/dev/null)
  [ "$restored" -eq 0 ] && echo "  未找到 *.zh-orig 备份（可能已还原或从未安装）"
  echo "[3/4] 还原 app.asar"
  if [ -f "$APP_RES/app.asar.zh-orig" ]; then
    sudo mv "$APP_RES/app.asar.zh-orig" "$APP_RES/app.asar"
    echo "  已还原: app.asar"
  else
    echo "  未找到 app.asar.zh-orig（可能已还原或从未安装）"
  fi
  sudo rm -f "$APP_RES/.zh-orig-version"
  echo "[4/4] 重置用户 locale 为 en-US"
  python3 - "$HOME/.config/Claude/config.json" <<'PY'
import json, sys, os
path = sys.argv[1]
if os.path.exists(path):
    cfg = json.load(open(path))
    cfg["locale"] = "en-US"
    json.dump(cfg, open(path, "w"), ensure_ascii=False, indent="\t")
PY
  echo "完成！请重新打开 Claude Desktop。"
}

case "$ACTION" in
  install) install ;;
  uninstall) uninstall ;;
  *) echo "用法: $0 install [zh-CN|zh-TW|zh-HK] | uninstall"; exit 1 ;;
esac
