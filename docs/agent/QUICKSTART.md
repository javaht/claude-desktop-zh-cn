# Quickstart

1. Read `AGENT_HANDOFF.md` and `README.md`.
2. Run `python3 -m py_compile scripts/patch_claude_zh_cn.py scripts/macos_auto_repair.py`.
3. Run `python3 -m unittest discover -s tests -v` and `bash -n install-mac.command`.
4. For Windows changes, require the PowerShell 5.1 parser and dynamic-layout fixture jobs in `.github/workflows/test.yml` to pass.
5. Never restore a backup without a current, identity-matching patch marker.
