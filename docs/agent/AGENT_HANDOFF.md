# Claude Desktop 汉化补丁 - Agent 交接文档

## 项目状态
- 版本：v1.2.2
- 发布包：/tmp/claude-zh-cn-release.zip
- 测试：121/121 通过

## 运行方式
- 开发：`internal/`
- 发布：`_internal/`

## 常用命令
- 测试：`PYTHONDONTWRITEBYTECODE=1 python3 -m pytest internal/tools/test_patch_behaviors.py -q`
- 构建：`python3 internal/tools/build-release.py`
- Smoke：`/mnt/c/Windows/System32/cmd.exe /C "安装中文补丁.bat --smoke-e2e"`
