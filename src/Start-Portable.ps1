# ============================================================
# Start-Portable.ps1
# メインメニュー [1]・[2] および引数指定でのポータブル版 VSCode 起動
# ============================================================

function Start-Portable([string[]]$Targets) {
    if (-not (Test-Path -LiteralPath $code -PathType Leaf)) {
        throw "Code.exe が見つかりません: $code （メニュー [6] から導入・更新できます）"
    }
    Initialize-Portable
    Write-Host '[起動中...] 日本語表示とポータブル Git を準備しています。'
    Set-PortableJapanese
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $code
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.Arguments = (@((@('--locale', 'ja') + @($Targets | Where-Object { -not [string]::IsNullOrEmpty($_) })) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    # Only the child environment is modified; never write User/Machine variables.
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -like 'VSCODE_*' -or $key -like 'CLINE_*' -or $key -eq 'ELECTRON_RUN_AS_NODE') {
            $info.EnvironmentVariables.Remove($key)
        }
    }
    $info.EnvironmentVariables['CLINE_DIR'] = $cline
    Set-PortableGitEnvironment $info
    # Electron can attach to its parent's console even after the launcher exits.
    # A console-free PowerShell broker prevents VSCode from retaining this window.
    $info.EnvironmentVariables['PORTABLE_CHILD_CODE'] = $code
    $info.EnvironmentVariables['PORTABLE_CHILD_ARGS'] = $info.Arguments
    $broker = @'
$ErrorActionPreference = 'Stop'
try {
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class PortableConsole { [DllImport("kernel32.dll")] public static extern bool FreeConsole(); }'
    [void][PortableConsole]::FreeConsole()
    $child = New-Object Diagnostics.ProcessStartInfo
    $child.FileName = $env:PORTABLE_CHILD_CODE
    $child.Arguments = $env:PORTABLE_CHILD_ARGS
    $child.WorkingDirectory = Split-Path -LiteralPath $child.FileName
    $child.UseShellExecute = $false
    [Environment]::SetEnvironmentVariable('PORTABLE_CHILD_CODE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('PORTABLE_CHILD_ARGS', $null, 'Process')
    $process = [Diagnostics.Process]::Start($child)
    try {
        if ($process.WaitForExit(3000)) { exit $process.ExitCode }
    }
    finally { $process.Dispose() }
    exit 0
}
catch { exit 1 }
'@
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($broker))
    $info.CreateNoWindow = $true
    Write-Host "Cline 設定ルート: $cline"
    Write-Host 'ポータブル版 VSCode を起動しています...'
    $process = [Diagnostics.Process]::Start($info)
    try {
        Wait-PortableProcess $process 'VS Code を起動しています'
        if ($process.ExitCode -ne 0) {
            throw "起動処理が終了コード $($process.ExitCode) で失敗しました。ログ: $data\user-data\logs"
        }
    }
    finally { $process.Dispose() }
    Write-Host '起動要求を送信しました。既存のポータブル版がある場合は、そのウィンドウが使用されます。'
}
