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

function Write-PortableStage([int]$Step, [string]$Message) {
    Write-Host "[起動中... $Step/7] $Message"
    Write-Progress -Id 10 -Activity 'ポータブル環境を準備しています（処理段階の目安）' -Status $Message -PercentComplete ([int](100 * $Step / 7))
}

function Wait-PortableProcess($Process, [string]$Activity) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $Process.WaitForExit(250)) {
            Write-Progress -Id 11 -Activity $Activity -Status ("起動中／処理中... {0:N0} 秒経過" -f $watch.Elapsed.TotalSeconds) -PercentComplete -1
        }
    }
    finally { Write-Progress -Id 11 -Activity $Activity -Completed }
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows argument quoting: preserve spaces, quotes and trailing backslashes.
    return '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}

function Get-PortableIsolationPaths {
    $portableHome = Join-Path $data 'home'
    $clineRoot    = if ($cline) { $cline } else { Join-Path $portableHome '.cline' }
    $appDataRoot  = Join-Path $data 'appdata'
    $gitStateRoot = Join-Path $data 'git'
    $toolsBin     = Join-Path $data 'tools\bin'
    $gitRoot      = Join-Path $data 'tools\git'
    return [pscustomobject]@{
        Home             = $portableHome
        SshDir           = Join-Path $portableHome '.ssh'
        GitGlobalConfig  = Join-Path $portableHome '.gitconfig'
        NpmUserConfig    = Join-Path $portableHome '.npmrc'
        XdgConfigHome    = Join-Path $portableHome '.config'
        XdgDataHome      = Join-Path $portableHome '.local\share'
        XdgStateHome     = Join-Path $portableHome '.local\state'
        XdgCacheHome     = Join-Path $portableHome '.cache'
        GhConfigDir      = Join-Path $portableHome '.config\gh'
        DocumentsDir     = Join-Path $portableHome 'Documents'
        AppDataRoaming   = Join-Path $appDataRoot 'Roaming'
        AppDataLocal     = Join-Path $appDataRoot 'Local'
        AppDataLocalLow  = Join-Path $appDataRoot 'LocalLow'
        TmpDir           = Join-Path $data 'tmp'
        NpmCacheDir      = Join-Path $data 'tmp\npm-cache'
        ClineDir         = $clineRoot
        ClineDataDir     = Join-Path $clineRoot 'data'
        ClineRulesDir    = Join-Path $clineRoot 'rules'
        GitStateRoot     = $gitStateRoot
        GitSystemConfig  = Join-Path $gitStateRoot 'system.gitconfig'
        GcmDpapiStore    = Join-Path $gitStateRoot 'gcm-dpapi'
        GitRoot          = $gitRoot
        GitCmdDir        = Join-Path $gitRoot 'cmd'
        GitSshExe        = Join-Path $gitRoot 'usr\bin\ssh.exe'
        ToolsBinDir      = $toolsBin
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

function Set-PortableChildEnvironment(
    [Diagnostics.ProcessStartInfo]$Info,
    [hashtable]$ExtraEnvironment = @{},
    [switch]$IncludeGitPath
) {
    $paths = Get-PortableIsolationPaths

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
    $Info.EnvironmentVariables['npm_config_cache']      = $paths.NpmCacheDir
    $Info.EnvironmentVariables['npm_config_userconfig'] = $paths.NpmUserConfig
    $Info.EnvironmentVariables['PORTABLE_ENV_INITIALIZED'] = '1'

    if ($IncludeGitPath) {
        Set-PortableGitEnvironment $Info
    }

    foreach ($k in $ExtraEnvironment.Keys) {
        $Info.EnvironmentVariables[$k] = [string]$ExtraEnvironment[$k]
    }
}
