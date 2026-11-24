# MinGit is Git for Windows without the GUI; no installer or administrator needed.
function Install-PortableGit([object]$TargetRelease = $null, [string]$LocalZipPath = '', [switch]$Force) {
    $gitRoot = Join-Path $data 'tools\git'
    $gitExe = Join-Path $gitRoot 'cmd\git.exe'
    if ($Force -or -not [string]::IsNullOrWhiteSpace($LocalZipPath) -or -not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
        $archive = $null
        $expectedHash = ''
        $assetName = ''
        if (-not [string]::IsNullOrWhiteSpace($LocalZipPath)) {
            if (-not (Test-Path -LiteralPath $LocalZipPath -PathType Leaf)) {
                throw "指定された MinGit ZIP が見つかりません: $LocalZipPath"
            }
            Write-Host "[設定] ローカル ZIP からポータブル Git (MinGit) を導入／更新しています..."
            $archive = $LocalZipPath
            $assetName = Split-Path -Leaf $LocalZipPath
            $expectedHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
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
            $archive = Join-Path $data ('tmp\' + $assetName)
            if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) {
                Save-UrlToFile $asset.browser_download_url $archive 'ポータブル Git をダウンロードしています'
            }
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) { throw 'MinGit の SHA-256 検証に失敗しました。' }
        }
        $stage = Join-Path $data ('tmp\git-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-ZipArchiveFast $archive $stage
            $stagedExe = Join-Path $stage 'cmd\git.exe'
            if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) { throw "MinGit の展開内容が不正です: $stage" }
            $version = & $stagedExe --version
            if ($LASTEXITCODE -ne 0) { throw 'MinGit の動作確認に失敗しました。' }
            [void][IO.Directory]::CreateDirectory($gitRoot)
            # Copy also repairs an interrupted install; cmd/git.exe is copied last.
            foreach ($item in (Get-ChildItem -LiteralPath $stage | Where-Object Name -ne 'cmd')) {
                Copy-Item -LiteralPath $item.FullName -Destination $gitRoot -Recurse -Force
            }
            Copy-Item -LiteralPath (Join-Path $stage 'cmd') -Destination $gitRoot -Recurse -Force
            Write-PortableJson (Join-Path $gitRoot 'portable-install.json') @{ version = ([string]($version | Select-Object -First 1)).Trim(); sha256 = $expectedHash.ToLowerInvariant(); asset = $assetName }
        }
        finally {
            if (Test-Path -LiteralPath $stage) {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $version = & $gitExe --version
    if ($LASTEXITCODE -ne 0) { throw "ポータブル Git を実行できません: $gitExe" }
    Write-Host "[Git] $version"
    Initialize-PortableGitConfig
    Initialize-PortableSshShims
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
    if (-not (Test-Path -LiteralPath (Join-Path $gitUsrBin 'ssh.exe') -PathType Leaf)) { return }

    [void][IO.Directory]::CreateDirectory($paths.ToolsBinDir)
    Set-PortableRestrictedDirectoryAcl $paths.SshDir
    $knownHosts = Join-Path $paths.SshDir 'known_hosts'
    if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
        [IO.File]::WriteAllText($knownHosts, '', (New-Object Text.UTF8Encoding($false)))
    }

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
}

function Initialize-PortableGitConfig {
    $paths = Get-PortableIsolationPaths
    [void][IO.Directory]::CreateDirectory($paths.Home)
    [void][IO.Directory]::CreateDirectory($paths.GitStateRoot)
    Set-PortableRestrictedDirectoryAcl $paths.GcmDpapiStore

    if (-not (Test-Path -LiteralPath $paths.GitGlobalConfig -PathType Leaf)) {
        [IO.File]::WriteAllText($paths.GitGlobalConfig, '', (New-Object Text.UTF8Encoding($false)))
    }

    # MinGit 内の既存システム gitconfig を探索し、ホスト Program Files への [include] パス行のみ除外
    $candidates = @(
        (Join-Path $paths.GitRoot 'etc\gitconfig')
        (Join-Path $paths.GitRoot 'ucrt64\etc\gitconfig')
        (Join-Path $paths.GitRoot 'mingw64\etc\gitconfig')
        (Join-Path $paths.GitRoot 'clangarm64\etc\gitconfig')
        (Join-Path $paths.GitRoot 'mingw32\etc\gitconfig')
    )
    $baseLines = New-Object Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            foreach ($line in ([IO.File]::ReadAllLines($candidate, [Text.Encoding]::UTF8))) {
                if ($line -match '^\s*path\s*=\s*[A-Za-z]:[/\\]Program Files') { continue }
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
    $gitCmd = Join-Path $data 'tools\git\cmd'
    if (-not (Test-Path -LiteralPath (Join-Path $gitCmd 'git.exe') -PathType Leaf)) { throw 'ポータブル Git が導入されていません。' }
    $toolsBin = Join-Path $data 'tools\bin'
    $prefix = if (Test-Path -LiteralPath $toolsBin -PathType Container) { $gitCmd + ';' + $toolsBin } else { $gitCmd }
    $Info.EnvironmentVariables['PATH'] = $prefix + ';' + $Info.EnvironmentVariables['PATH']
}