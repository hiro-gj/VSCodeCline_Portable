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
$script:PortableGitState              = $null
$script:PortableGitProbeHandler       = $null
$script:PortableSignatureCheckHandler = $null

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

function Test-CodeIntegrityBlockedCode([int]$ExitCode = 0, [int]$Win32ErrorCode = 0) {
    $policyExitCodes = @(
        -1058471934, # 0xC0E90002 STATUS_SYSTEM_INTEGRITY_POLICY_VIOLATION
        -1058471935, # 0xC0E90001 STATUS_DYNAMIC_CODE_BLOCKED
        -1073740760, # 0xC0000428 STATUS_INVALID_IMAGE_HASH
        -1073741790  # 0xC0000022 STATUS_ACCESS_DENIED
    )
    $policyWin32Codes = @(
        4551, # ERROR_SYSTEM_INTEGRITY_POLICY_VIOLATION
        1260, # ERROR_ACCESS_DISABLED_BY_POLICY
        577,  # ERROR_INVALID_IMAGE_HASH
        225   # ERROR_VIRUS_INFECTED
    )
    return (($ExitCode -in $policyExitCodes) -or ($Win32ErrorCode -in $policyWin32Codes))
}

function Format-ExecutableBlockDiagnostic([int]$ExitCode = 0, [int]$Win32ErrorCode = 0, [string]$ErrorMessage = '') {
    $parts = New-Object Collections.Generic.List[string]
    if ($ExitCode -ne 0) {
        $hex = ('0x{0:X8}' -f ([uint32][BitConverter]::ToUInt32([BitConverter]::GetBytes($ExitCode), 0)))
        $parts.Add("ExitCode=$hex ($ExitCode)")
    }
    if ($Win32ErrorCode -ne 0) {
        $parts.Add("Win32Error=$Win32ErrorCode")
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $parts.Add((Format-PortableProgressText $ErrorMessage))
    }
    if ($parts.Count -eq 0) { return '不明な実行エラー' }
    return ($parts -join ' / ')
}

function Test-TrustedExecutableSignature([string]$FilePath) {
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $false
    }
    if ($null -ne $script:PortableSignatureCheckHandler) {
        return [bool](& $script:PortableSignatureCheckHandler $FilePath)
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $FilePath -ErrorAction Stop
        return ($null -ne $sig -and $sig.Status -eq [Management.Automation.SignatureStatus]::Valid)
    }
    catch {
        return $false
    }
}

function Invoke-GitExecutableProbe(
    [string]$GitExePath,
    [int]$MaxAttempts = 1,
    [int]$RetryDelayMs = 400,
    [int]$TimeoutMs = 10000
) {
    if ($null -ne $script:PortableGitProbeHandler) {
        return (& $script:PortableGitProbeHandler $GitExePath $MaxAttempts)
    }
    if ([string]::IsNullOrWhiteSpace($GitExePath) -or -not (Test-Path -LiteralPath $GitExePath -PathType Leaf)) {
        return [pscustomobject]@{
            Success           = $false
            Version           = ''
            ExitCode          = -1
            Win32ErrorCode    = 2
            IsPolicyBlocked   = $false
            DiagnosticMessage = "実行ファイルが見つかりません: $GitExePath"
        }
    }

    $paths = Get-PortableIsolationPaths
    Ensure-PortableProfileDirectories $paths
    $attempts = [Math]::Max(1, $MaxAttempts)
    $lastResult = $null

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName               = $GitExePath
        $psi.Arguments              = '--version'
        $psi.WorkingDirectory       = $paths.TmpDir
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
        $psi.EnvironmentVariables['HOME']                = $paths.Home
        $psi.EnvironmentVariables['USERPROFILE']         = $paths.Home
        $psi.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
        $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
        $psi.EnvironmentVariables['TEMP']                = $paths.TmpDir
        $psi.EnvironmentVariables['TMP']                 = $paths.TmpDir

        $proc = $null
        try {
            $proc = [Diagnostics.Process]::Start($psi)
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                try { $proc.Kill() } catch {}
                $lastResult = [pscustomobject]@{
                    Success           = $false
                    Version           = ''
                    ExitCode          = -1
                    Win32ErrorCode    = 1460
                    IsPolicyBlocked   = $false
                    DiagnosticMessage = "git --version がタイムアウトしました (${TimeoutMs}ms)"
                }
            }
            else {
                [void]$proc.WaitForExit()
                $stdout = if ($outTask.Wait(2000)) { [string]$outTask.Result } else { '' }
                $stderr = if ($errTask.Wait(2000)) { [string]$errTask.Result } else { '' }
                $code   = [int]$proc.ExitCode
                $verLine = ($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
                if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace($verLine)) {
                    return [pscustomobject]@{
                        Success           = $true
                        Version           = ([string]$verLine).Trim()
                        ExitCode          = 0
                        Win32ErrorCode    = 0
                        IsPolicyBlocked   = $false
                        DiagnosticMessage = ''
                    }
                }
                $blocked = Test-CodeIntegrityBlockedCode -ExitCode $code -Win32ErrorCode 0
                $lastResult = [pscustomobject]@{
                    Success           = $false
                    Version           = ''
                    ExitCode          = $code
                    Win32ErrorCode    = 0
                    IsPolicyBlocked   = $blocked
                    DiagnosticMessage = Format-ExecutableBlockDiagnostic -ExitCode $code -Win32ErrorCode 0 -ErrorMessage $stderr
                }
            }
        }
        catch {
            $baseEx = $_.Exception.GetBaseException()
            $win32Code = if ($baseEx -is [ComponentModel.Win32Exception]) { [int]$baseEx.NativeErrorCode } else { 0 }
            $blocked = Test-CodeIntegrityBlockedCode -ExitCode 0 -Win32ErrorCode $win32Code
            $lastResult = [pscustomobject]@{
                Success           = $false
                Version           = ''
                ExitCode          = 0
                Win32ErrorCode    = $win32Code
                IsPolicyBlocked   = $blocked
                DiagnosticMessage = Format-ExecutableBlockDiagnostic -ExitCode 0 -Win32ErrorCode $win32Code -ErrorMessage $baseEx.Message
            }
        }
        finally {
            if ($null -ne $proc) { $proc.Dispose() }
        }

        if ($attempt -lt $attempts) {
            Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
        }
    }

    return $lastResult
}

function Test-SshExecutableRunnable([string]$SshExePath, [int]$TimeoutMs = 5000) {
    if ([string]::IsNullOrWhiteSpace($SshExePath) -or -not (Test-Path -LiteralPath $SshExePath -PathType Leaf)) {
        return $false
    }
    if ($null -ne $script:PortableGitProbeHandler) {
        $mock = & $script:PortableGitProbeHandler $SshExePath 1
        return [bool]($null -ne $mock -and $mock.Success)
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName               = $SshExePath
    $psi.Arguments              = '-V'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = $null
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
            return $false
        }
        return ($proc.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Get-LocalGitExecutablePath {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($baseDir in @(
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $script:HostLocalAppData
    )) {
        if (-not [string]::IsNullOrWhiteSpace($baseDir)) {
            $candidates.Add((Join-Path $baseDir 'Git\cmd\git.exe'))
            $candidates.Add((Join-Path $baseDir 'Programs\Git\cmd\git.exe'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        $sysRoot = $env:SystemDrive.TrimEnd('\') + '\'
        $candidates.Add((Join-Path $sysRoot 'Program Files\Git\cmd\git.exe'))
        $candidates.Add((Join-Path $sysRoot 'Program Files (x86)\Git\cmd\git.exe'))
    }
    foreach ($regPath in @(
        'HKLM:\SOFTWARE\GitForWindows',
        'HKLM:\SOFTWARE\WOW6432Node\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows'
    )) {
        try {
            if (Test-Path -LiteralPath $regPath) {
                $rk = Get-Item -LiteralPath $regPath -ErrorAction SilentlyContinue
                if ($rk) {
                    $inst = $rk.GetValue('InstallPath')
                    if ($inst) { $candidates.Add((Join-Path ([string]$inst).Trim().Trim('"') 'cmd\git.exe')) }
                }
            }
        } catch {}
    }
    foreach ($appReg in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\git.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\git.exe'
    )) {
        try {
            if (Test-Path -LiteralPath $appReg) {
                $rk = Get-Item -LiteralPath $appReg -ErrorAction SilentlyContinue
                if ($rk) {
                    $val = $rk.GetValue('')
                    if ($val) { $candidates.Add(([string]$val).Trim().Trim('"')) }
                }
            }
        } catch {}
    }
    foreach ($vsBase in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($vsBase)) { continue }
        $vsRoot = Join-Path $vsBase 'Microsoft Visual Studio'
        if (Test-Path -LiteralPath $vsRoot -PathType Container) {
            foreach ($found in (Get-ChildItem -LiteralPath $vsRoot -Directory -ErrorAction SilentlyContinue)) {
                foreach ($ed in (Get-ChildItem -LiteralPath $found.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $candidates.Add((Join-Path $ed.FullName 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\Git\cmd\git.exe'))
                }
            }
        }
    }
    $rawHostPath = if ($script:HostPath) { $script:HostPath } else { $env:PATH }
    if (-not [string]::IsNullOrWhiteSpace($rawHostPath)) {
        foreach ($entry in ($rawHostPath -split ';')) {
            $trimmed = $entry.Trim().Trim('"')
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and [IO.Path]::IsPathRooted($trimmed)) {
                $candidates.Add((Join-Path $trimmed 'git.exe'))
            }
        }
    }

    $portablePrefix = ([IO.Path]::GetFullPath($root)).TrimEnd('\') + '\'
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($cand in $candidates) {
        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
        try {
            $full = [IO.Path]::GetFullPath($cand)
            if (-not $seen.Add($full)) { continue }
            if ([IO.Path]::GetFileName($full) -ine 'git.exe') { continue }
            if ($full.StartsWith($portablePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            if (-not (Test-TrustedExecutableSignature $full)) { continue }
            $probe = Invoke-GitExecutableProbe -GitExePath $full -MaxAttempts 1
            if ($probe.Success) {
                return [pscustomobject]@{
                    Path    = $full
                    CmdDir  = Split-Path -LiteralPath $full
                    Version = $probe.Version
                }
            }
        } catch {}
    }
    return $null
}

function Get-LocalOpenSshDirectory {
    $sysBase = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) { $env:SystemRoot } else { $env:WINDIR }
    if ([string]::IsNullOrWhiteSpace($sysBase)) { return $null }
    $sshDir = Join-Path $sysBase 'System32\OpenSSH'
    $sshExe = Join-Path $sshDir 'ssh.exe'
    if (-not (Test-Path -LiteralPath $sshExe -PathType Leaf)) { return $null }
    if (-not (Test-TrustedExecutableSignature $sshExe)) { return $null }
    return $sshDir
}

function Get-PortableEffectiveSshCommandPath($Paths = $null) {
    $p = if ($Paths) { $Paths } else { Get-PortableIsolationPaths }
    if ($null -ne $script:PortableGitState) {
        if ($script:PortableGitState.SshMode -eq 'Portable' -and (Test-Path -LiteralPath $p.GitSshExe -PathType Leaf)) {
            return $p.GitSshExe
        }
        if ($script:PortableGitState.SshMode -eq 'System') {
            $shim = Join-Path $p.ToolsBinDir 'git-ssh.cmd'
            if (Test-Path -LiteralPath $shim -PathType Leaf) { return $shim }
        }
        if ($script:PortableGitState.SshMode -eq 'None') {
            return $null
        }
    }
    if (Test-Path -LiteralPath $p.GitSshExe -PathType Leaf) {
        return $p.GitSshExe
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
    $effectiveSsh = Get-PortableEffectiveSshCommandPath $paths
    if ($effectiveSsh) {
        $Info.EnvironmentVariables['GIT_SSH'] = $effectiveSsh
    }
    else {
        $Info.EnvironmentVariables.Remove('GIT_SSH')
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
