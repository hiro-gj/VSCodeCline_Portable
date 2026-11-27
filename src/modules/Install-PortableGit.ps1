# MinGit is Git for Windows without the GUI; no installer or administrator needed.
function Install-PortableGit([object]$TargetRelease = $null, [string]$LocalZipPath = '', [switch]$Force) {
    $gitRoot = Join-Path $data 'tools\git'
    $gitExe  = Join-Path $gitRoot 'cmd\git.exe'
    $explicitInstall = ($Force.IsPresent -or -not [string]::IsNullOrWhiteSpace($LocalZipPath))

    if ($explicitInstall -or -not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
        $archive = $null
        $expectedHash = ''
        $assetName = ''
        $fallbackVersionLabel = ''
        if (-not [string]::IsNullOrWhiteSpace($LocalZipPath)) {
            if (-not (Test-Path -LiteralPath $LocalZipPath -PathType Leaf)) {
                throw "指定された MinGit ZIP が見つかりません: $LocalZipPath"
            }
            Write-Host '[設定] ローカル ZIP からポータブル Git (MinGit) を導入／更新しています...'
            $archive = $LocalZipPath
            $assetName = Split-Path -Leaf $LocalZipPath
            $expectedHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            $fallbackVersionLabel = $assetName
        }
        else {
            Initialize-NetworkConfig
            Write-Host '[設定] ポータブル Git (MinGit) を導入／更新しています...'
            $release = if ($TargetRelease) { $TargetRelease } else {
                Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'VSCode-Portable-Launcher/1.0' } -TimeoutSec 30
            }
            $arch = (Get-PortableCodeArchitecture $code).Arch
            $suffix = switch ($arch) { 'arm64' { 'arm64' } 'x64' { '64-bit' } 'x86' { '32-bit' } default { throw "未対応の Git アーキテクチャ: $arch" } }
            $asset = $release.assets | Where-Object { $_.name -match ('^MinGit-[0-9.]+-' + $suffix + '\.zip$') } | Select-Object -First 1
            if (-not $asset -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'SHA-256 付きの公式 MinGit ZIP が見つかりません。' }
            $expectedHash = $Matches[1]
            $assetName = [string]$asset.name
            $fallbackVersionLabel = if ($release.tag_name) { ([string]$release.tag_name).Trim() -replace '^[vV]', '' } else { $assetName }
            $archive = Join-Path $data ('tmp\' + $assetName)
            if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) {
                Save-UrlToFile $asset.browser_download_url $archive 'ポータブル Git をダウンロードしています'
            }
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) { throw 'MinGit の SHA-256 検証に失敗しました。' }
        }

        $stage = Join-Path $data ('tmp\git-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-ZipArchiveFast $archive $stage 'ポータブル Git (MinGit) を展開中...'
            $stagedExe = Join-Path $stage 'cmd\git.exe'
            if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) { throw "MinGit の展開内容が不正です: $stage" }
            $stageProbe = Invoke-GitExecutableProbe -GitExePath $stagedExe -MaxAttempts 3 -RetryDelayMs 400
            if (-not $stageProbe.Success) {
                $canStagePlaceOnPolicyBlock = ($stageProbe.IsPolicyBlocked -and (Test-TrustedExecutableSignature $stagedExe))
                if (-not $canStagePlaceOnPolicyBlock) {
                    throw "MinGit の動作確認に失敗しました ($($stageProbe.DiagnosticMessage))"
                }
                Write-Host "[注意] 展開した MinGit はこの PC のセキュリティポリシーにより実行制限されていますが、署名・整合性確認済みのためファイル配置を継続します ($($stageProbe.DiagnosticMessage))" -ForegroundColor Yellow
            }
            $recordedVer = if ($stageProbe.Success -and $stageProbe.Version) { $stageProbe.Version } else { "git version $fallbackVersionLabel" }
            [void][IO.Directory]::CreateDirectory($gitRoot)
            foreach ($item in (Get-ChildItem -LiteralPath $stage | Where-Object Name -ne 'cmd')) {
                Copy-Item -LiteralPath $item.FullName -Destination $gitRoot -Recurse -Force
            }
            Copy-Item -LiteralPath (Join-Path $stage 'cmd') -Destination $gitRoot -Recurse -Force
            Write-PortableJson (Join-Path $gitRoot 'portable-install.json') @{
                version = $recordedVer
                sha256  = $expectedHash.ToLowerInvariant()
                asset   = $assetName
            }
        }
        finally {
            if (Test-Path -LiteralPath $stage) {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Resolve-PortableGitRuntime
    Initialize-PortableGitConfig
    Initialize-PortableSshShims
}

function Repair-PortableGitFromCachedArchive {
    $gitRoot    = Join-Path $data 'tools\git'
    $markerPath = Join-Path $gitRoot 'portable-install.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try {
        $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $asset  = if ($marker.asset)  { ([string]$marker.asset).Trim() }  else { '' }
        $sha    = if ($marker.sha256) { ([string]$marker.sha256).Trim() } else { '' }
        if (-not $asset -or $sha -notmatch '^[a-fA-F0-9]{64}$') { return $false }
        $safeLeaf = [IO.Path]::GetFileName($asset)
        if ($safeLeaf -cne $asset) { return $false }
        $cachedZip = Join-Path $data ('tmp\' + $safeLeaf)
        if (-not (Test-Path -LiteralPath $cachedZip -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $cachedZip -Algorithm SHA256).Hash -ine $sha) { return $false }

        $stage = Join-Path $data ('tmp\git-repair-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-ZipArchiveFast $cachedZip $stage 'ポータブル Git キャッシュから修復展開中...'
            $stagedExe = Join-Path $stage 'cmd\git.exe'
            if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) { return $false }
            $probe = Invoke-GitExecutableProbe -GitExePath $stagedExe -MaxAttempts 2 -RetryDelayMs 400
            if (-not $probe.Success) { return $false }
            [void][IO.Directory]::CreateDirectory($gitRoot)
            foreach ($item in (Get-ChildItem -LiteralPath $stage | Where-Object Name -ne 'cmd')) {
                Copy-Item -LiteralPath $item.FullName -Destination $gitRoot -Recurse -Force
            }
            Copy-Item -LiteralPath (Join-Path $stage 'cmd') -Destination $gitRoot -Recurse -Force
            return $true
        }
        finally {
            if (Test-Path -LiteralPath $stage) {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        return $false
    }
}

function Resolve-PortableGitRuntime {
    $paths  = Get-PortableIsolationPaths
    $gitExe = Join-Path $paths.GitCmdDir 'git.exe'
    $probe  = Invoke-GitExecutableProbe -GitExePath $gitExe -MaxAttempts 3 -RetryDelayMs 400

    if ($probe.Success) {
        $sshOk   = Test-SshExecutableRunnable $paths.GitSshExe
        $sshMode = if ($sshOk) { 'Portable' } elseif (Get-LocalOpenSshDirectory) { 'System' } else { 'None' }
        $script:PortableGitState = [pscustomobject]@{
            Mode        = 'Portable'
            GitExe      = $gitExe
            GitCmdDir   = $paths.GitCmdDir
            Version     = $probe.Version
            SshMode     = $sshMode
            Diagnostic  = ''
            PolicyBlock = $false
        }
        Write-Host "[Git] $($probe.Version)"
        return
    }

    $hostGit = Get-LocalGitExecutablePath
    $sysSsh  = Get-LocalOpenSshDirectory
    $sshMode = if ($sysSsh) { 'System' } else { 'None' }

    if ($hostGit) {
        $script:PortableGitState = [pscustomobject]@{
            Mode        = 'Host'
            GitExe      = $hostGit.Path
            GitCmdDir   = $hostGit.CmdDir
            Version     = $hostGit.Version
            SshMode     = $sshMode
            Diagnostic  = $probe.DiagnosticMessage
            PolicyBlock = [bool]$probe.IsPolicyBlocked
        }
        Write-Host "[注意] ポータブル Git の実行がブロックまたは失敗しました ($($probe.DiagnosticMessage))。" -ForegroundColor Yellow
        Write-Host "[Git] ホスト PC の Git へ自動フォールバックしました: $($hostGit.Version) ($($hostGit.Path)) （設定・認証情報は VSCode\data 配下に分離されます）" -ForegroundColor Green
        return
    }

    if (Repair-PortableGitFromCachedArchive) {
        $reProbe = Invoke-GitExecutableProbe -GitExePath $gitExe -MaxAttempts 2 -RetryDelayMs 400
        if ($reProbe.Success) {
            $sshOk2   = Test-SshExecutableRunnable $paths.GitSshExe
            $sshMode2 = if ($sshOk2) { 'Portable' } elseif ($sysSsh) { 'System' } else { 'None' }
            $script:PortableGitState = [pscustomobject]@{
                Mode        = 'Portable'
                GitExe      = $gitExe
                GitCmdDir   = $paths.GitCmdDir
                Version     = $reProbe.Version
                SshMode     = $sshMode2
                Diagnostic  = ''
                PolicyBlock = $false
            }
            Write-Host "[修復] キャッシュ済み MinGit アーカイブからポータブル Git を再展開し復旧しました: $($reProbe.Version)" -ForegroundColor Green
            return
        }
    }

    $script:PortableGitState = [pscustomobject]@{
        Mode        = 'Unavailable'
        GitExe      = ''
        GitCmdDir   = ''
        Version     = ''
        SshMode     = $sshMode
        Diagnostic  = $probe.DiagnosticMessage
        PolicyBlock = [bool]$probe.IsPolicyBlocked
    }

    if ($env:PORTABLE_REQUIRE_GIT -eq '1') {
        throw "ポータブル Git を実行できません: $gitExe ($($probe.DiagnosticMessage))"
    }

    Write-Host "[警告] ポータブル Git を実行できず、ホスト PC 上にも利用可能な Git が見つかりませんでした ($($probe.DiagnosticMessage))。" -ForegroundColor Yellow
    if ($probe.IsPolicyBlocked) {
        Write-Host '  -> Windows セキュリティのコード整合性ポリシー（Smart App Control / WDAC 等）によるブロックが検出されました。' -ForegroundColor Yellow
        Write-Host '  -> [対処1] 別 PC への初回接続直後の一時的な評価保留の場合は、PC を再起動すると解消する場合があります。' -ForegroundColor Yellow
        Write-Host '  -> [対処2] 組織ポリシーでリムーバブル領域が制限されている場合は、ホスト PC に公式 Git for Windows を導入すると次回起動時から自動連携されます。' -ForegroundColor Yellow
    }
    Write-Host '  -> Git 機能を除き、ポータブル版 VSCode / Cline / Playwright MCP の起動を継続します。' -ForegroundColor Yellow
}

function Update-GitOnline([object]$PrefetchedRelease) {
    $curGit = Get-InstalledPortableGitInfo
    $rel = if ($PrefetchedRelease) { $PrefetchedRelease } else {
        Write-Host 'GitHub 公式リリースへポータブル Git (MinGit) の最新バージョンを確認しています...'
        Get-LatestPortableGitRelease
    }
    $curLabel = if ($curGit) { $curGit.Version } else { '未インストール' }
    Write-Host "  ポータブル Git : 現在 $curLabel -> 最新 $($rel.Version)"
    $sameHash = ($curGit -and $curGit.Sha256 -and $rel.Sha256 -and ($curGit.Sha256 -ieq $rel.Sha256))
    $cmp = if ($curGit) { Compare-VersionString $curGit.ComparableVersion $rel.ComparableVersion } else { -1 }
    if (-not $curGit) {
        if (-not (Confirm-Action "ポータブル Git ($($rel.Version)) をインストールしますか？")) { return $false }
    }
    elseif ($sameHash -or $cmp -ge 0) {
        Write-Host '  -> ポータブル Git は既に最新バージョンです。' -ForegroundColor Green
        if (-not (Confirm-Action 'ポータブル Git を強制再インストールしますか？')) { return $false }
    }
    else {
        if (-not (Confirm-Action "ポータブル Git を $curLabel から $($rel.Version) へアップデートしますか？")) { return $false }
    }
    if (-not (Wait-PortableCodeClosed -Required $false)) {
        Write-Host '[中止] ポータブル Git の更新をキャンセルしました。'
        return $false
    }
    Install-PortableGit -TargetRelease $rel.RawRelease -Force
    Initialize-Portable
    $afterGit = Get-InstalledPortableGitInfo
    $afterLabel = if ($afterGit) { $afterGit.Version } else { $rel.Version }
    Write-Host "[完了] ポータブル Git バージョン: $afterLabel" -ForegroundColor Green
    return $true
}

function Initialize-PortableSshShims {
    $paths = Get-PortableIsolationPaths
    $gitUsrBin = Join-Path $paths.GitRoot 'usr\bin'
    $usePortableSsh = if ($null -ne $script:PortableGitState) {
        ($script:PortableGitState.SshMode -eq 'Portable')
    } else {
        (Test-Path -LiteralPath (Join-Path $gitUsrBin 'ssh.exe') -PathType Leaf)
    }
    $sysSshDir = if (-not $usePortableSsh) { Get-LocalOpenSshDirectory } else { $null }
    if (-not $usePortableSsh -and -not $sysSshDir) { return }

    [void][IO.Directory]::CreateDirectory($paths.ToolsBinDir)
    Set-PortableRestrictedDirectoryAcl $paths.SshDir
    foreach ($sshFile in @('known_hosts', 'config')) {
        $targetFile = Join-Path $paths.SshDir $sshFile
        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
            [IO.File]::WriteAllText($targetFile, '', (New-Object Text.UTF8Encoding($false)))
        }
    }

    if ($usePortableSsh) {
        foreach ($tool in @('ssh', 'ssh-keygen', 'scp', 'sftp', 'ssh-add', 'ssh-agent')) {
            $exePath = Join-Path $gitUsrBin ($tool + '.exe')
            if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { continue }
            $shimPath = Join-Path $paths.ToolsBinDir ($tool + '.cmd')
            $shimContent = (@(
                '@echo off'
                'setlocal'
                'for %%I in ("%~dp0..\..\home") do set "HOME=%%~fI"'
                'set "USERPROFILE=%HOME%"'
                ('"%~dp0..\git\usr\bin\' + $tool + '.exe" %*')
            ) -join "`r`n") + "`r`n"
            if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf) -or [IO.File]::ReadAllText($shimPath, [Text.Encoding]::UTF8) -cne $shimContent) {
                [IO.File]::WriteAllText($shimPath, $shimContent, (New-Object Text.UTF8Encoding($false)))
            }
        }
        $gitSshShim = Join-Path $paths.ToolsBinDir 'git-ssh.cmd'
        if (Test-Path -LiteralPath $gitSshShim -PathType Leaf) {
            Remove-Item -LiteralPath $gitSshShim -Force -ErrorAction SilentlyContinue
        }
        return
    }

    # システム署名済み OpenSSH (%SystemRoot%\System32\OpenSSH) フォールバックシム（ホスト .ssh 参照遮断付き）
    foreach ($tool in @('ssh', 'ssh-keygen', 'scp', 'sftp', 'ssh-add', 'ssh-agent')) {
        $sysExe = Join-Path $sysSshDir ($tool + '.exe')
        if (-not (Test-Path -LiteralPath $sysExe -PathType Leaf)) { continue }
        $shimPath = Join-Path $paths.ToolsBinDir ($tool + '.cmd')
        $lines = New-Object Collections.Generic.List[string]
        $lines.Add('@echo off')
        $lines.Add('setlocal')
        $lines.Add('for %%I in ("%~dp0..\..\home") do set "HOME=%%~fI"')
        $lines.Add('set "USERPROFILE=%HOME%"')
        if ($tool -in @('ssh', 'scp', 'sftp')) {
            $lines.Add('set "PORTABLE_SSH_DIR=%HOME:\=/%/.ssh"')
            $lines.Add(('"%SystemRoot%\System32\OpenSSH\' + $tool + '.exe" -F "%PORTABLE_SSH_DIR%/config" -o "UserKnownHostsFile=%PORTABLE_SSH_DIR%/known_hosts" -o "GlobalKnownHostsFile=NUL" %*'))
        }
        else {
            $lines.Add(('"%SystemRoot%\System32\OpenSSH\' + $tool + '.exe" %*'))
        }
        $shimContent = ($lines -join "`r`n") + "`r`n"
        if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf) -or [IO.File]::ReadAllText($shimPath, [Text.Encoding]::UTF8) -cne $shimContent) {
            [IO.File]::WriteAllText($shimPath, $shimContent, (New-Object Text.UTF8Encoding($false)))
        }
    }

    $gitSshPath = Join-Path $paths.ToolsBinDir 'git-ssh.cmd'
    $gitSshContent = (@(
        '@echo off'
        'setlocal'
        'for %%I in ("%~dp0..\..\home") do set "HOME=%%~fI"'
        'set "USERPROFILE=%HOME%"'
        'set "PORTABLE_SSH_DIR=%HOME:\=/%/.ssh"'
        '"%SystemRoot%\System32\OpenSSH\ssh.exe" -F "%PORTABLE_SSH_DIR%/config" -o "UserKnownHostsFile=%PORTABLE_SSH_DIR%/known_hosts" -o "GlobalKnownHostsFile=NUL" %*'
    ) -join "`r`n") + "`r`n"
    if (-not (Test-Path -LiteralPath $gitSshPath -PathType Leaf) -or [IO.File]::ReadAllText($gitSshPath, [Text.Encoding]::UTF8) -cne $gitSshContent) {
        [IO.File]::WriteAllText($gitSshPath, $gitSshContent, (New-Object Text.UTF8Encoding($false)))
    }
}

function Initialize-PortableGitConfig {
    $paths = Get-PortableIsolationPaths
    [void][IO.Directory]::CreateDirectory($paths.Home)
    [void][IO.Directory]::CreateDirectory($paths.GitStateRoot)
    Set-PortableRestrictedDirectoryAcl $paths.GcmDpapiStore

    if (-not (Test-Path -LiteralPath $paths.GitGlobalConfig -PathType Leaf)) {
        [IO.File]::WriteAllText($paths.GitGlobalConfig, '', (New-Object Text.UTF8Encoding($false)))
    }

    $rootsToSearch = New-Object Collections.Generic.List[string]
    $rootsToSearch.Add($paths.GitRoot)
    if ($null -ne $script:PortableGitState -and $script:PortableGitState.Mode -eq 'Host' -and $script:PortableGitState.GitCmdDir) {
        $hostGitRoot = Split-Path -LiteralPath $script:PortableGitState.GitCmdDir
        if ($hostGitRoot) { $rootsToSearch.Add($hostGitRoot) }
    }

    $candidates = New-Object Collections.Generic.List[string]
    foreach ($gRoot in $rootsToSearch) {
        foreach ($sub in @('etc\gitconfig', 'ucrt64\etc\gitconfig', 'mingw64\etc\gitconfig', 'clangarm64\etc\gitconfig', 'mingw32\etc\gitconfig')) {
            $candidates.Add((Join-Path $gRoot $sub))
        }
    }

    $baseLines = New-Object Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            foreach ($line in ([IO.File]::ReadAllLines($candidate, [Text.Encoding]::UTF8))) {
                if ($line -match '^\s*path\s*=\s*[A-Za-z]:[/\\]') { continue }
                $baseLines.Add($line)
            }
            break
        }
    }
    $baseLines.Add('[http]')
    $baseLines.Add("`tsslVerify = true")
    $baseLines.Add('[credential]')
    $baseLines.Add("`thelper =")
    $baseLines.Add("`thelper = manager")
    $baseLines.Add("`tcredentialStore = dpapi")

    $content = ($baseLines -join "`r`n") + "`r`n"
    if (-not (Test-Path -LiteralPath $paths.GitSystemConfig -PathType Leaf) -or
        [IO.File]::ReadAllText($paths.GitSystemConfig, [Text.Encoding]::UTF8) -cne $content) {
        [IO.File]::WriteAllText($paths.GitSystemConfig, $content, (New-Object Text.UTF8Encoding($false)))
    }
}

function Set-PortableGitEnvironment($Info) {
    $toolsBin = Join-Path $data 'tools\bin'
    $hasToolsBin = Test-Path -LiteralPath $toolsBin -PathType Container

    if ($null -ne $script:PortableGitState) {
        $prefixParts = New-Object Collections.Generic.List[string]
        if ($script:PortableGitState.Mode -in @('Portable', 'Host') -and
            -not [string]::IsNullOrWhiteSpace($script:PortableGitState.GitCmdDir) -and
            (Test-Path -LiteralPath (Join-Path $script:PortableGitState.GitCmdDir 'git.exe') -PathType Leaf)) {
            $prefixParts.Add($script:PortableGitState.GitCmdDir)
        }
        if ($hasToolsBin) {
            $prefixParts.Add($toolsBin)
        }
        if ($prefixParts.Count -gt 0) {
            $Info.EnvironmentVariables['PATH'] = ($prefixParts -join ';') + ';' + $Info.EnvironmentVariables['PATH']
        }
        return
    }

    # PortableGitState 未評価時の後方互換動作（単体テスト直接呼び出し等）
    $gitCmd = Join-Path $data 'tools\git\cmd'
    if (-not (Test-Path -LiteralPath (Join-Path $gitCmd 'git.exe') -PathType Leaf)) { throw 'ポータブル Git が導入されていません。' }
    $prefix = if ($hasToolsBin) { $gitCmd + ';' + $toolsBin } else { $gitCmd }
    $Info.EnvironmentVariables['PATH'] = $prefix + ';' + $Info.EnvironmentVariables['PATH']
}