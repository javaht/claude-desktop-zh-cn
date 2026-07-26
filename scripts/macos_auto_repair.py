#!/usr/bin/env python3
"""Root-owned launchd controller that reapplies the bundled patch after an update."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import pwd
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import patch_claude_zh_cn as patcher


STATE_PATH = patcher.AUTO_REPAIR_ROOT / "state.json"
FAILURE_RETRY_SECONDS = 6 * 60 * 60
LOG_ROTATE_BYTES = 1024 * 1024
CLAUDE_BUNDLE_ID = "com.anthropic.claudefordesktop"
QUIT_WAIT_SECONDS = 20


def log(message: str) -> None:
    stamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"[{stamp}] {message}", flush=True)


def rotate_log_if_needed() -> None:
    """Keep the launchd-managed log bounded: rename to .old once it exceeds the cap.

    launchd already holds the log open for this run, so output keeps flowing to
    the rotated file; the next launch recreates a fresh auto-repair.log.
    """
    try:
        log_path = patcher.AUTO_REPAIR_LOG
        if log_path.stat().st_size >= LOG_ROTATE_BYTES:
            log_path.replace(log_path.with_suffix(log_path.suffix + ".old"))
    except FileNotFoundError:
        pass
    except OSError as exc:
        log(f"Log rotation skipped: {exc}")


def load_object(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as f:
            value = json.load(f)
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise SystemExit(f"Expected a JSON object: {path}")
    return value


def save_object(path: Path, value: dict[str, Any]) -> None:
    patcher.save_json(path, value)
    os.chmod(path, 0o600)
    os.chown(path, 0, 0)


def validate_config(value: dict[str, Any], path: Path) -> dict[str, Any]:
    if value.get("schema") != 1:
        raise SystemExit(f"Unsupported auto-repair config schema in {path}")
    if value.get("language") not in {"zh-CN", "zh-TW", "zh-HK"}:
        raise SystemExit(f"Invalid auto-repair language in {path}")
    if value.get("mode") not in {"full", "safe"}:
        raise SystemExit(f"Invalid auto-repair mode in {path}")

    app = Path(str(value.get("app", "")))
    user_home = Path(str(value.get("userHome", "")))
    if not app.is_absolute() or not user_home.is_absolute():
        raise SystemExit(f"Auto-repair paths must be absolute in {path}")
    if not patcher.path_is_within(app.resolve(), Path("/Applications").resolve()):
        raise SystemExit(f"Refusing to auto-repair an app outside /Applications: {app}")
    return value


def claude_is_running(app: Path) -> bool:
    # Match by bundle path prefix instead of the bare name "Claude" so an
    # unrelated process that happens to share the name never triggers a relaunch.
    # macOS pgrep cannot read the Electron main process's argv (it falls back to
    # a truncated comm), so `pgrep -x Claude` misses it entirely; the app's
    # helper children (renderer/GPU/crashpad) always run from inside the bundle
    # with readable argv, so a path-prefix match reliably detects a running app.
    # ^ anchors to argv[0]: only processes launched from inside the bundle
    # match, not unrelated commands whose arguments mention the path.
    bundle_prefix = "^" + re.escape(str(app.resolve() / "Contents") + "/")
    result = subprocess.run(
        ["/usr/bin/pgrep", "-f", bundle_prefix],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def quit_claude_for_user(app: Path, user_home: Path) -> bool:
    """Ask the user's GUI session to quit Claude; return True once it is gone.

    This daemon runs in the system launchd domain, where a bare osascript has
    no route to the user's Aqua session and the quit AppleEvent silently fails
    (-600/-1743). Delivering it via `launchctl asuser` fixes the bootstrap
    namespace; TCC may still deny Automation for root, so the caller must
    treat a lingering process as "patch on disk, effective on next launch".
    """
    if not claude_is_running(app):
        return True
    try:
        uid = user_home.stat().st_uid
        user_name = pwd.getpwuid(uid).pw_name
    except Exception as exc:
        log(f"Cannot determine user for quitting Claude: {exc}")
        return False
    env = os.environ.copy()
    env["HOME"] = str(user_home)
    env["USER"] = user_name
    env["LOGNAME"] = user_name
    subprocess.run(
        [
            "/bin/launchctl",
            "asuser",
            str(uid),
            "/usr/bin/osascript",
            "-e",
            f'tell application id "{CLAUDE_BUNDLE_ID}" to quit',
        ],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    deadline = time.time() + QUIT_WAIT_SECONDS
    while time.time() < deadline:
        if not claude_is_running(app):
            return True
        time.sleep(1)
    return not claude_is_running(app)


def launch_for_user(app: Path, user_home: Path) -> None:
    try:
        uid = user_home.stat().st_uid
        user_name = pwd.getpwuid(uid).pw_name
    except Exception as exc:
        log(f"Cannot determine user for relaunch: {exc}")
        return
    env = os.environ.copy()
    env["HOME"] = str(user_home)
    env["USER"] = user_name
    env["LOGNAME"] = user_name
    subprocess.run(
        ["/bin/launchctl", "asuser", str(uid), "/usr/bin/open", "-a", str(app)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def app_is_settled(app: Path) -> bool:
    watched = [app / "Contents/Info.plist", app / patcher.APP_ASAR_REL]
    try:
        newest = max(path.stat().st_mtime for path in watched)
    except FileNotFoundError:
        return False
    return time.time() - newest >= patcher.AUTO_REPAIR_SETTLE_SECONDS


def failure_is_backed_off(state: dict[str, Any], fingerprint: dict[str, Any], release: str) -> bool:
    if state.get("failedFingerprint") != fingerprint or state.get("patchRelease") != release:
        return False
    try:
        failed_at = float(state.get("failedAt", 0))
    except (TypeError, ValueError):
        return False
    return time.time() - failed_at < FAILURE_RETRY_SECONDS


def run_once(config_path: Path) -> int:
    config = validate_config(load_object(config_path), config_path)
    app = Path(config["app"])
    user_home = Path(config["userHome"])
    language = str(config["language"])
    mode = str(config["mode"])
    release = patcher.get_patch_release()

    if not app.exists():
        log(f"Claude.app is temporarily absent; waiting for the updater: {app}")
        return 0
    if patcher.patch_is_current(app, language, mode):
        if STATE_PATH.exists():
            STATE_PATH.unlink()
        return 0
    try:
        fingerprint = patcher.get_app_fingerprint(app)
    except (Exception, SystemExit) as exc:
        log(f"Claude.app is not readable yet; waiting for the official updater: {exc}")
        return 0
    state = load_object(STATE_PATH)
    if failure_is_backed_off(state, fingerprint, release):
        log("The same Claude build already failed compatibility checks; retry is backed off")
        return 0
    if state.get("observedFingerprint") != fingerprint:
        save_object(
            STATE_PATH,
            {
                "observedFingerprint": fingerprint,
                "observedAt": time.time(),
                "patchRelease": release,
            },
        )
        log("Observed a new Claude build; waiting for one unchanged observation before repair")
        return 0
    try:
        observed_at = float(state.get("observedAt", 0))
    except (TypeError, ValueError):
        observed_at = 0
    if time.time() - observed_at < patcher.AUTO_REPAIR_SETTLE_SECONDS or not app_is_settled(app):
        log("Claude.app is not settled yet; waiting for the official updater to finish")
        return 0

    was_running = claude_is_running(app)
    quit_ok = True
    if was_running:
        quit_ok = quit_claude_for_user(app, user_home)
        if quit_ok:
            log("Claude was quit from the user session for the repair")
        else:
            log(
                "Claude is still running (Automation may be denied for root); "
                "patching on disk anyway - the repair takes effect on the next launch"
            )
    command = [
        sys.executable,
        str(Path(patcher.__file__).resolve()),
        "--app",
        str(app),
        "--user-home",
        str(user_home),
        "--lang",
        language,
        "--maintenance-run",
        "--no-auto-repair",
    ]
    if mode == "safe":
        command.append("--skip-asar-patch")

    log(
        f"Detected an unpatched Claude update "
        f"{fingerprint['identity'].get('version')} ({fingerprint['identity'].get('build')}); repairing"
    )
    result = subprocess.run(command, check=False)
    if was_running and quit_ok:
        # Only relaunch when the old instance actually quit; `open -a` against
        # a still-running app would merely focus the unpatched instance.
        launch_for_user(app, user_home)
    if result.returncode == 0:
        if STATE_PATH.exists():
            STATE_PATH.unlink()
        marker = patcher.read_patch_marker(app) or {}
        repaired_mode = marker.get("mode")
        if repaired_mode in {"full", "safe"} and repaired_mode != mode:
            config["mode"] = repaired_mode
            save_object(config_path, config)
            log(f"Compatibility fallback changed the maintained patch mode to {repaired_mode}")
        if was_running and not quit_ok:
            log(
                "Automatic Chinese patch repair completed on disk; "
                "it takes effect after Claude restarts"
            )
        else:
            log("Automatic Chinese patch repair completed")
        return 0

    save_object(
        STATE_PATH,
        {
            "observedFingerprint": fingerprint,
            "observedAt": observed_at or time.time(),
            "failedFingerprint": fingerprint,
            "patchRelease": release,
            "failedAt": time.time(),
            "exitCode": result.returncode,
        },
    )
    log(f"Automatic repair failed with exit code {result.returncode}; the official app was kept")
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Maintain the Claude Desktop Chinese patch after updates")
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()

    rotate_log_if_needed()
    patcher.AUTO_REPAIR_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with patcher.AUTO_REPAIR_LOCK.open("a+", encoding="utf-8") as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Another repair process is already running")
            return 0
        return run_once(args.config)


if __name__ == "__main__":
    raise SystemExit(main())
