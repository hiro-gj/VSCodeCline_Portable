# ============================================================
# Common-Helpers.ps1
# 共通 UI 対話・ネイティブ引数エスケープ関数群
# ============================================================

function Confirm-Action([string]$Message) {
    return (Read-Host "$Message [y/N]") -ieq 'y'
}

function Wait-Menu {
    [void](Read-Host 'Enter キーでメニューに戻ります')
}

$script:PortableProgressStageId    = 10
$script:PortableProgressProcessId  = 11
$script:PortableProgressDownloadId = 12
$script:PortableProgressExtractId  = 13
$script:PortableProgressCheckId    = 14
$script:PortableStageActive        = $false
$script:PortableStageActivity      = 'ポータブル環境を準備しています（処理段階の目安）'
$script:ActiveProgressIds          = New-Object 'Collections.Generic.HashSet[int]'
$script:SavedConsoleOutputEncoding = $null
$script:PortableProgressHandler    = $null

function Initialize-PortableConsoleEncoding {
    $script:SavedConsoleOutputEncoding = $null
    try {
        if ([Console]::IsOutputRedirected) {
            $script:SavedConsoleOutputEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
            return
        }
        $curCp = [Console]::OutputEncoding.CodePage
        if ($curCp -in @(932, 936, 949, 950)) { return }
        $candidateCps = @(
            [Globalization.CultureInfo]::CurrentUICulture.TextInfo.ANSICodePage,
            [Globalization.CultureInfo]::InstalledUICulture.TextInfo.ANSICodePage,
            932
        )
        foreach ($cp in $candidateCps) {
            if ($cp -in @(932, 936, 949, 950)) {
                $enc = [Text.Encoding]::GetEncoding([int]$cp)
                $script:SavedConsoleOutputEncoding = [Console]::OutputEncoding
                [Console]::OutputEncoding = $enc
                return
            }
        }
    }
    catch {}
}

function Restore-PortableConsoleEncoding {
    if ($null -ne $script:SavedConsoleOutputEncoding) {
        try { [Console]::OutputEncoding = $script:SavedConsoleOutputEncoding } catch {}
        $script:SavedConsoleOutputEncoding = $null
    }
}

function Test-PortableProgressEnabled {
    if ($env:PORTABLE_NONINTERACTIVE -eq '1') { return $false }
    if ($ProgressPreference -eq 'SilentlyContinue') { return $false }
    if ($env:PORTABLE_FORCE_PROGRESS -eq '1') { return $true }
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) { return $false }
        if ($Host.Name -ne 'ConsoleHost' -or $null -eq $Host.UI -or $null -eq $Host.UI.RawUI) { return $false }
        $null = $Host.UI.RawUI.WindowSize
        return $true
    }
    catch {
        return $false
    }
}

function Format-PortableProgressText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = [regex]::Replace($Text, '\x1B\[[0-9;?]*[ -/]*[@-~]', '')
    $clean = [regex]::Replace($clean, '[\x00-\x1F\x7F]+', ' ')
    return $clean.Trim()
}

function Write-PortableProgress(
    [int]$Id,
    [string]$Activity,
    [string]$Status,
    [int]$PercentComplete = -1,
    [int]$ParentId = -1
) {
    if (-not (Test-PortableProgressEnabled)) { return }
    $safeActivity = Format-PortableProgressText $Activity
    if ([string]::IsNullOrWhiteSpace($safeActivity)) { $safeActivity = '処理中' }
    $safeStatus = Format-PortableProgressText $Status
    if ([string]::IsNullOrWhiteSpace($safeStatus)) { $safeStatus = '...' }

    $params = @{
        Id              = $Id
        Activity        = $safeActivity
        Status          = $safeStatus
        PercentComplete = if ($PercentComplete -lt 0) { -1 } else { [Math]::Max(0, [Math]::Min(100, $PercentComplete)) }
    }
    $effectiveParent = if ($ParentId -ge 0) {
        $ParentId
    } elseif ($script:PortableStageActive -and $Id -ne $script:PortableProgressStageId) {
        $script:PortableProgressStageId
    } else {
        -1
    }
    if ($effectiveParent -ge 0) {
        $params['ParentId'] = $effectiveParent
    }
    [void]$script:ActiveProgressIds.Add($Id)
    if ($null -ne $script:PortableProgressHandler) {
        & $script:PortableProgressHandler @params
        return
    }
    Write-Progress @params
}

function Complete-PortableProgress([int]$Id, [string]$Activity = '完了') {
    if ($null -ne $script:ActiveProgressIds -and -not $script:ActiveProgressIds.Remove($Id)) {
        return
    }
    if (-not (Test-PortableProgressEnabled)) { return }
    $safeActivity = Format-PortableProgressText $Activity
    if ([string]::IsNullOrWhiteSpace($safeActivity)) { $safeActivity = '完了' }
    if ($null -ne $script:PortableProgressHandler) {
        & $script:PortableProgressHandler -Id $Id -Activity $safeActivity -Completed
        return
    }
    Write-Progress -Id $Id -Activity $safeActivity -Completed
}

function Complete-AllPortableProgress {
    foreach ($id in @(
        $script:PortableProgressCheckId,
        $script:PortableProgressExtractId,
        $script:PortableProgressDownloadId,
        $script:PortableProgressProcessId,
        $script:PortableProgressStageId
    )) {
        if ($null -ne $id) {
            try { Complete-PortableProgress -Id $id -Activity '完了' } catch {}
        }
    }
    if ($null -ne $script:ActiveProgressIds) {
        foreach ($restId in @($script:ActiveProgressIds)) {
            try { Complete-PortableProgress -Id $restId -Activity '完了' } catch {}
        }
        $script:ActiveProgressIds.Clear()
    }
    $script:PortableStageActive = $false
}

function Write-PortableStage([int]$Step, [string]$Message, [int]$TotalSteps = 7) {
    $script:PortableStageActive = $true
    $safeMessage = Format-PortableProgressText $Message
    Write-Host "[起動中... $Step/$TotalSteps] $safeMessage"
    $pct = [int][Math]::Min(100, [Math]::Round(($Step * 100.0) / [Math]::Max(1, $TotalSteps)))
    Write-PortableProgress -Id $script:PortableProgressStageId -Activity $script:PortableStageActivity -Status "[$Step/$TotalSteps] $safeMessage" -PercentComplete $pct
}

function Complete-PortableStage {
    try {
        Complete-PortableProgress -Id $script:PortableProgressStageId -Activity $script:PortableStageActivity
    }
    finally {
        $script:PortableStageActive = $false
    }
}

function Step-PortableProcessStreams([hashtable]$State, [int]$FinalWaitMs = 0) {
    while ($null -ne $State.OutTask) {
        if (-not $State.OutTask.IsCompleted) {
            if ($FinalWaitMs -le 0 -or -not $State.OutTask.Wait($FinalWaitMs)) { break }
        }
        $line = $State.OutTask.GetAwaiter().GetResult()
        if ($null -eq $line) { $State.OutTask = $null; break }
        if ($State.CaptureStdout) {
            $State.OutLines.Add($line)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host (Format-PortableProgressText $line)
        }
        $State.OutTask = $State.Process.StandardOutput.ReadLineAsync()
    }
    while ($null -ne $State.ErrTask) {
        if (-not $State.ErrTask.IsCompleted) {
            if ($FinalWaitMs -le 0 -or -not $State.ErrTask.Wait($FinalWaitMs)) { break }
        }
        $eline = $State.ErrTask.GetAwaiter().GetResult()
        if ($null -eq $eline) { $State.ErrTask = $null; break }
        if (-not [string]::IsNullOrWhiteSpace($eline)) {
            Write-Host (Format-PortableProgressText $eline)
        }
        $State.ErrTask = $State.Process.StandardError.ReadLineAsync()
    }
}

function Wait-PortableProcess($Process, [string]$Activity, [switch]$PassThruStandardOutput) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $hasOut = [bool]$Process.StartInfo.RedirectStandardOutput
    $hasErr = [bool]$Process.StartInfo.RedirectStandardError
    $streamState = @{
        Process       = $Process
        CaptureStdout = [bool]$PassThruStandardOutput
        OutLines      = if ($PassThruStandardOutput) { New-Object Collections.Generic.List[string] } else { $null }
        OutTask       = if ($hasOut) { $Process.StandardOutput.ReadLineAsync() } else { $null }
        ErrTask       = if ($hasErr) { $Process.StandardError.ReadLineAsync() } else { $null }
    }
    try {
        Write-PortableProgress -Id $script:PortableProgressProcessId -Activity $Activity -Status '起動中／処理中... 0 秒経過' -PercentComplete -1
        while (-not $Process.WaitForExit(250)) {
            Step-PortableProcessStreams -State $streamState -FinalWaitMs 0
            Write-PortableProgress -Id $script:PortableProgressProcessId -Activity $Activity -Status ("起動中／処理中... {0:N0} 秒経過" -f $watch.Elapsed.TotalSeconds) -PercentComplete -1
        }
        Step-PortableProcessStreams -State $streamState -FinalWaitMs 2000
    }
    finally {
        Complete-PortableProgress -Id $script:PortableProgressProcessId -Activity $Activity
    }
    if ($PassThruStandardOutput) {
        return ($streamState.OutLines -join [Environment]::NewLine)
    }
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows argument quoting: preserve spaces, quotes and trailing backslashes.
    return '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}

function ConvertTo-ExtendedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -match '^[A-Za-z]:\\') { return '\\?\' + $full }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $full.Substring(2) }
    return $full
}

function Get-PortableFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead((ConvertTo-ExtendedPath $Path))
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Test-PortableHardLinkSupport([string]$DirectoryPath) {
    [void][IO.Directory]::CreateDirectory($DirectoryPath)
    $fullDir  = [IO.Path]::GetFullPath($DirectoryPath)
    $rootPath = [IO.Path]::GetPathRoot($fullDir)
    if ($rootPath -and $rootPath -match '^[A-Za-z]:\\$') {
        try {
            $volume = New-Object IO.DriveInfo ($rootPath)
            if ($volume.DriveFormat -in @('exFAT', 'FAT32', 'FAT')) {
                return $false
            }
        }
        catch {}
    }

    $probeBase = Join-Path $fullDir ('.hl-probe-' + $PID + '-' + [guid]::NewGuid().ToString('N'))
    $probeSrc  = $probeBase + '.src'
    $probeLink = $probeBase + '.lnk'
    try {
        [IO.File]::WriteAllText($probeSrc, '', (New-Object Text.UTF8Encoding($false)))
        $null = New-Item -ItemType HardLink -Path $probeLink -Value $probeSrc -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $probeLink) { Remove-Item -LiteralPath $probeLink -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $probeSrc)  { Remove-Item -LiteralPath $probeSrc  -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PortableIsolationPaths {
    $portableHome = Join-Path $data 'home'
    $clineRoot    = if ($cline) { $cline } else { Join-Path $portableHome '.cline' }
    $appDataRoot  = Join-Path $data 'appdata'
    $gitStateRoot = Join-Path $data 'git'
    $toolsBin     = Join-Path $data 'tools\bin'
    $gitRoot      = Join-Path $data 'tools\git'
    return [pscustomobject]@{
        Home                = $portableHome
        HomeAppDataRoaming  = Join-Path $portableHome 'AppData\Roaming'
        HomeAppDataLocal    = Join-Path $portableHome 'AppData\Local'
        HomeAppDataLocalLow = Join-Path $portableHome 'AppData\LocalLow'
        SshDir              = Join-Path $portableHome '.ssh'
        GitGlobalConfig     = Join-Path $portableHome '.gitconfig'
        NpmUserConfig       = Join-Path $portableHome '.npmrc'
        XdgConfigHome       = Join-Path $portableHome '.config'
        XdgDataHome         = Join-Path $portableHome '.local\share'
        XdgStateHome        = Join-Path $portableHome '.local\state'
        XdgCacheHome        = Join-Path $portableHome '.cache'
        GhConfigDir         = Join-Path $portableHome '.config\gh'
        DocumentsDir        = Join-Path $portableHome 'Documents'
        DownloadsDir        = Join-Path $portableHome 'Downloads'
        DesktopDir          = Join-Path $portableHome 'Desktop'
        AppDataRoaming      = Join-Path $appDataRoot 'Roaming'
        AppDataLocal        = Join-Path $appDataRoot 'Local'
        AppDataLocalLow     = Join-Path $appDataRoot 'LocalLow'
        TmpDir              = Join-Path $data 'tmp'
        NpmCacheDir         = Join-Path $data 'tmp\npm-cache'
        ClineDir            = $clineRoot
        ClineDataDir        = Join-Path $clineRoot 'data'
        ClineRulesDir       = Join-Path $clineRoot 'rules'
        GitStateRoot        = $gitStateRoot
        GitSystemConfig     = Join-Path $gitStateRoot 'system.gitconfig'
        GcmDpapiStore       = Join-Path $gitStateRoot 'gcm-dpapi'
        GitRoot             = $gitRoot
        GitCmdDir           = Join-Path $gitRoot 'cmd'
        GitSshExe           = Join-Path $gitRoot 'usr\bin\ssh.exe'
        ToolsBinDir         = $toolsBin
    }
}

function Ensure-PortableProfileDirectories($Paths = $null) {
    $p = if ($Paths) { $Paths } else { Get-PortableIsolationPaths }
    foreach ($dir in @(
        $p.Home
        $p.HomeAppDataRoaming
        $p.HomeAppDataLocal
        $p.HomeAppDataLocalLow
        $p.DocumentsDir
        $p.DownloadsDir
        $p.DesktopDir
        $p.AppDataRoaming
        $p.AppDataLocal
        $p.AppDataLocalLow
        $p.TmpDir
    )) {
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            [void][IO.Directory]::CreateDirectory($dir)
        }
    }
}

function Set-PortableRestrictedDirectoryAcl([string]$TargetPath) {
    [void][IO.Directory]::CreateDirectory($TargetPath)
    $fullTarget = [IO.Path]::GetFullPath($TargetPath)
    $rootPath   = [IO.Path]::GetPathRoot($fullTarget)
    # UNC パス等の非ドライブレター環境では DriveInfo 例外を避けてスキップ
    if (-not $rootPath -or $rootPath -notmatch '^[A-Za-z]:\\$') { return }
    $volume = New-Object IO.DriveInfo ($rootPath)
    if ($volume.DriveFormat -ine 'NTFS') { return }

    try {
        $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid      = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $adminsSid      = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

        $dirItem = Get-Item -LiteralPath $fullTarget
        $acl = $dirItem.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $acl.SetAccessRuleProtection($true, $false) # 継承を遮断し明示ルールのみ保持
        $rights  = [Security.AccessControl.FileSystemRights]::FullControl
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $prop    = [Security.AccessControl.PropagationFlags]::None
        $allow   = [Security.AccessControl.AccessControlType]::Allow

        foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            [void]$acl.RemoveAccessRule($rule)
        }

        foreach ($sid in @($currentUserSid, $systemSid, $adminsSid)) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $rights, $inherit, $prop, $allow)
            $acl.AddAccessRule($rule)
        }
        $dirItem.SetAccessControl($acl)
    }
    catch {
        Write-Warning "ディレクトリ ACL の制限適用をスキップしました: $fullTarget ($($_.Exception.Message))"
    }
}

function Get-LocalEdgeExecutablePath {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($baseDir in @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles,
        $env:ProgramW6432,
        $script:HostLocalAppData,
        $env:LOCALAPPDATA
    )) {
        if (-not [string]::IsNullOrWhiteSpace($baseDir)) {
            $candidates.Add((Join-Path $baseDir 'Microsoft\Edge\Application\msedge.exe'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        $sysRoot = $env:SystemDrive.TrimEnd('\') + '\'
        $candidates.Add((Join-Path $sysRoot 'Program Files (x86)\Microsoft\Edge\Application\msedge.exe'))
        $candidates.Add((Join-Path $sysRoot 'Program Files\Microsoft\Edge\Application\msedge.exe'))
    }
    foreach ($regPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
        try {
            if (Test-Path -LiteralPath $regPath) {
                $regKey = Get-Item -LiteralPath $regPath -ErrorAction SilentlyContinue
                if ($regKey) {
                    $val = $regKey.GetValue('')
                    if ($val) { $candidates.Add(([string]$val).Trim().Trim('"')) }
                }
            }
        } catch {}
    }
    foreach ($regUpdatePath in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    )) {
        try {
            if (Test-Path -LiteralPath $regUpdatePath) {
                $regKey = Get-Item -LiteralPath $regUpdatePath -ErrorAction SilentlyContinue
                if ($regKey) {
                    $loc = $regKey.GetValue('location')
                    if ($loc) { $candidates.Add((Join-Path ([string]$loc).Trim() 'msedge.exe')) }
                }
            }
        } catch {}
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (([IO.Path]::GetFileName($full) -ieq 'msedge.exe') -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                return $full
            }
        } catch {}
    }
    return $null
}

function Set-PortableChildEnvironment(
    [Diagnostics.ProcessStartInfo]$Info,
    [hashtable]$ExtraEnvironment = @{},
    [switch]$IncludeGitPath
) {
    $paths = Get-PortableIsolationPaths
    Ensure-PortableProfileDirectories $paths

    # 1. ホスト環境からの汚染・外部参照を招く環境変数を除去
    foreach ($key in @($Info.EnvironmentVariables.Keys)) {
        if ($key -like 'VSCODE_*' -or
            $key -like 'CLINE_*' -or
            $key -like 'GIT_*' -or
            $key -like 'GCM_*' -or
            $key -like 'NPM_CONFIG_*' -or
            $key -in @(
                'ELECTRON_RUN_AS_NODE',
                'SSH_AUTH_SOCK',
                'SSH_AGENT_PID',
                'GH_CONFIG_DIR',
                'XDG_CONFIG_HOME',
                'XDG_DATA_HOME',
                'XDG_STATE_HOME',
                'XDG_CACHE_HOME',
                'PLAYWRIGHT_BROWSERS_PATH',
                'OneDrive',
                'OneDriveConsumer',
                'OneDriveCommercial'
            )) {
            $Info.EnvironmentVariables.Remove($key)
        }
    }

    # 2. ホーム・AppData・XDG・一時フォルダを展開済みフォルダ（VSCode\data 配下）へ固定
    $Info.EnvironmentVariables['USERPROFILE']     = $paths.Home
    $Info.EnvironmentVariables['HOME']            = $paths.Home
    if ($paths.Home -match '^([A-Za-z]:)(\\.*)$') {
        $Info.EnvironmentVariables['HOMEDRIVE'] = $Matches[1]
        $Info.EnvironmentVariables['HOMEPATH']  = $Matches[2]
    }
    else {
        $Info.EnvironmentVariables.Remove('HOMEDRIVE')
        $Info.EnvironmentVariables.Remove('HOMEPATH')
    }
    $Info.EnvironmentVariables['APPDATA']         = $paths.AppDataRoaming
    $Info.EnvironmentVariables['LOCALAPPDATA']    = $paths.AppDataLocal
    $Info.EnvironmentVariables['XDG_CONFIG_HOME'] = $paths.XdgConfigHome
    $Info.EnvironmentVariables['XDG_DATA_HOME']   = $paths.XdgDataHome
    $Info.EnvironmentVariables['XDG_STATE_HOME']  = $paths.XdgStateHome
    $Info.EnvironmentVariables['XDG_CACHE_HOME']  = $paths.XdgCacheHome
    $Info.EnvironmentVariables['TEMP']            = $paths.TmpDir
    $Info.EnvironmentVariables['TMP']             = $paths.TmpDir
    $Info.EnvironmentVariables['TMPDIR']          = $paths.TmpDir

    # 3. Cline 保存先の明示固定
    $Info.EnvironmentVariables['CLINE_DIR']       = $paths.ClineDir
    $Info.EnvironmentVariables['CLINE_DATA_DIR']  = $paths.ClineDataDir

    # 4. Git / SSH / GitHub 認証情報のポータブル閉じ込め（DPAPI 暗号化ストア採用・平文保存禁止）
    $credStore = if ($env:PORTABLE_GIT_CREDENTIAL_STORE -in @('dpapi', 'cache', 'none')) {
        $env:PORTABLE_GIT_CREDENTIAL_STORE.ToLowerInvariant()
    } else {
        'dpapi'
    }
    $Info.EnvironmentVariables['GIT_CONFIG_GLOBAL']    = $paths.GitGlobalConfig
    $Info.EnvironmentVariables['GIT_CONFIG_SYSTEM']    = $paths.GitSystemConfig
    $Info.EnvironmentVariables['GCM_CREDENTIAL_STORE'] = $credStore
    $Info.EnvironmentVariables['GCM_DPAPI_STORE_PATH'] = $paths.GcmDpapiStore
    $Info.EnvironmentVariables['GH_CONFIG_DIR']        = $paths.GhConfigDir
    if (Test-Path -LiteralPath $paths.GitSshExe -PathType Leaf) {
        $Info.EnvironmentVariables['GIT_SSH'] = $paths.GitSshExe
    }

    # 5. npm 設定・キャッシュの閉じ込め
    $Info.EnvironmentVariables['npm_config_cache']           = $paths.NpmCacheDir
    $Info.EnvironmentVariables['npm_config_userconfig']      = $paths.NpmUserConfig
    $Info.EnvironmentVariables['npm_config_update_notifier'] = 'false'
    $Info.EnvironmentVariables['PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD'] = '1'
    $Info.EnvironmentVariables['PORTABLE_ENV_INITIALIZED'] = '1'

    if ($IncludeGitPath) {
        Set-PortableGitEnvironment $Info
    }

    foreach ($k in $ExtraEnvironment.Keys) {
        $Info.EnvironmentVariables[$k] = [string]$ExtraEnvironment[$k]
    }
}
