@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "PORTABLE_LAUNCH_SELF=%~f0"
set "PORTABLE_LAUNCH_ARGS=%*"
call :RUN_EMBEDDED_POWERSHELL
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo [ERROR] Portable launcher failed. Exit code: %RESULT%
    if not defined PORTABLE_NONINTERACTIVE pause
)
endlocal & exit /b %RESULT%

:RUN_EMBEDDED_POWERSHELL
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $text=[IO.File]::ReadAllText($env:PORTABLE_LAUNCH_SELF,[Text.Encoding]::UTF8); $parts=[regex]::Split($text,'(?m)^# POWERSHELL_PAYLOAD\r?$'); if($parts.Count -ne 2){throw 'Embedded PowerShell payload not found'}; & ([scriptblock]::Create($parts[1])); exit 0 } catch { Write-Host $_ -ForegroundColor Red; exit 1 }"
exit /b %ERRORLEVEL%

# POWERSHELL_PAYLOAD
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$OpenPaths
)

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$ErrorActionPreference = 'Stop'

# 通常版からの設定引き継ぎ（Copy-Optional.ps1）・ローカル Edge 検出用にホスト環境変数を退避
$script:HostUserProfile  = $env:USERPROFILE
$script:HostAppData      = $env:APPDATA
$script:HostLocalAppData = $env:LOCALAPPDATA

$sourceRoot  = Split-Path -LiteralPath $env:PORTABLE_LAUNCH_SELF
$modulesRoot = Join-Path $sourceRoot 'modules'
$root        = [IO.Path]::GetFullPath((Join-Path $sourceRoot '..\VSCode'))
$code        = Join-Path $root 'Code.exe'
$data        = Join-Path $root 'data'
$cline       = Join-Path $data 'home\.cline'
$clineExtensionId = 'saoudrizwan.claude-dev'

# Add-Type (csc.exe) の一時ファイルがホスト %TEMP% へ書き出されるのを防ぐため先行設定
$portableTmp = Join-Path $data 'tmp'
[void][IO.Directory]::CreateDirectory($portableTmp)
$env:TEMP = $portableTmp
$env:TMP  = $portableTmp

Write-Host '[起動中...] ポータブル環境を確認しています。初回はダウンロードに時間がかかります。'
# Read raw batch arguments as data, never as PowerShell source code.
if ($env:PORTABLE_LAUNCH_ARGS) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PortableArguments {
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr pointer);
    public static string[] Parse(string raw) {
        int count;
        IntPtr pointer = CommandLineToArgvW("launcher " + raw, out count);
        if (pointer == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            string[] result = new string[count - 1];
            for (int i = 1; i < count; i++)
                result[i - 1] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, i * IntPtr.Size));
            return result;
        } finally { LocalFree(pointer); }
    }
}
"@
    $OpenPaths = [PortableArguments]::Parse($env:PORTABLE_LAUNCH_ARGS)
}

function Set-PortableLauncherShortcut {
    $launcherPath = [IO.Path]::GetFullPath($env:PORTABLE_LAUNCH_SELF)
    $shortcutDir = Split-Path -LiteralPath $sourceRoot
    $shortcutPath = Join-Path $shortcutDir 'Start-VSCodeCline_Portable.cmd - 起動.lnk'
    $relativeLauncher = Join-Path (Split-Path -Leaf $sourceRoot) (Split-Path -Leaf $launcherPath)
    $cmdTemplate = '%SystemRoot%\System32\cmd.exe'
    $expectedCmdPath = [Environment]::ExpandEnvironmentVariables($cmdTemplate)
    $arguments = '/d /c ""' + $relativeLauncher + '" --menu"'
    $iconLocation = '%SystemRoot%\System32\imageres.dll,-68'
    $description = "Portable launcher (relative target: .\$relativeLauncher)"
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $hasExpString = $false
        if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
            $header = [IO.File]::ReadAllBytes($shortcutPath)
            if ($header.Length -ge 0x18) {
                $hasExpString = (([BitConverter]::ToUInt32($header, 0x14) -band 0x200) -ne 0)
            }
        }
        if ((Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and
            $hasExpString -and
            $shortcut.TargetPath -ieq $expectedCmdPath -and
            $shortcut.Arguments -ceq $arguments -and
            $shortcut.WorkingDirectory -eq '' -and
            $shortcut.WindowStyle -eq 1 -and
            $shortcut.IconLocation -ieq $iconLocation -and
            $shortcut.Description -ceq $description) { return }

        $shortcut.TargetPath = $cmdTemplate
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = ''
        $shortcut.WindowStyle = 1
        $shortcut.IconLocation = $iconLocation
        $shortcut.Description = $description
        $shortcut.Save()
        Write-Host "[設定] 起動ショートカットを作成／更新しました: $shortcutPath"
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

$portableScriptFiles = @(
    'Common-Helpers.ps1'
    'Get-PortableMetadata.ps1'
    'Initialize-Portable.ps1'
    'Start-Portable.ps1'
    'Copy-Optional.ps1'
    'Show-UpdateStatus.ps1'
    'Update-VSCodeOnline.ps1'
    'Update-ClineOnline.ps1'
    'Install-FromLocalPackage.ps1'
    'Update-AllOnline.ps1'
    'Show-UpdateMenu.ps1'
    'Show-MainMenu.ps1'
    'Install-PortableEnvironment.ps1'
    'Set-PortableJapanese.ps1'
    'Install-PortableGit.ps1'
)

try {
    foreach ($scriptFile in $portableScriptFiles) {
        $scriptPath = Join-Path $modulesRoot $scriptFile
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "必要なスクリプトファイルが見つかりません: $scriptPath"
        }
        . ([scriptblock]::Create([IO.File]::ReadAllText($scriptPath, [Text.Encoding]::UTF8)))
    }

    $setupOnly = $OpenPaths -contains '--setup-only'
    $showMenu = $OpenPaths -contains '--menu'
    $OpenPaths = @($OpenPaths | Where-Object { $_ -notin @('--setup-only', '--menu') })
    Set-PortableLauncherShortcut
    Install-PortableEnvironment
    if ($setupOnly) { exit 0 }
    if ($showMenu) {
        Show-MainMenu
    }
    else {
        Start-Portable $OpenPaths
    }
}
catch {
    Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
