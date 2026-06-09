!macro NSIS_HOOK_PREUNINSTALL
  DetailPrint "正在恢复官方 Claude Desktop 文件..."
  ClearErrors
  ; productName is the installer/display name; the bundled exe still follows the shared package name.
  nsExec::ExecToStack '"$INSTDIR\claude-desktop-zh-cn.exe" --cli-action restore_patch'
  Pop $0
  Pop $1
  ${If} $0 != 0
    MessageBox MB_ICONSTOP|MB_OK "恢复官方 Claude Desktop 失败，已中止卸载。请先恢复官方文件后再卸载补丁程序。$\r$\n$\r$\n退出码: $0$\r$\n输出: $1"
    Abort
  ${EndIf}
!macroend
