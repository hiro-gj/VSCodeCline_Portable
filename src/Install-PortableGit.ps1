# MinGit is Git for Windows without the GUI; no installer or administrator needed.
function Install-PortableGit {
    $gitRoot = Join-Path $data 'tools\git'
    $gitExe = Join-Path $gitRoot 'cmd\git.exe'
    if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
        Initialize-NetworkConfig
        Write-Host '[設定] ポータブル Git (MinGit) を導入しています...'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'VSCode-Portable-Launcher/1.0' } -TimeoutSec 30
        $arch = (Get-PortableCodeArchitecture $code).Arch
        $suffix = switch ($arch) { 'arm64' { 'arm64' } 'x64' { '64-bit' } 'x86' { '32-bit' } default { throw "未対応の Git アーキテクチャ: $arch" } }
        $asset = $release.assets | Where-Object { $_.name -match ('^MinGit-[0-9.]+-' + $suffix + '\.zip$') } | Select-Object -First 1
        if (-not $asset -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'SHA-256 付きの公式 MinGit ZIP が見つかりません。' }
        $expectedHash = $Matches[1]
        $archive = Join-Path $data ('tmp\' + $asset.name)
        Save-UrlToFile $asset.browser_download_url $archive 'ポータブル Git をダウンロードしています'
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) { throw 'MinGit の SHA-256 検証に失敗しました。' }
        $stage = Join-Path $data ('tmp\git-' + [guid]::NewGuid().ToString('N'))
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
        Write-PortableJson (Join-Path $gitRoot 'portable-install.json') @{ version = $version; sha256 = $expectedHash; asset = $asset.name }
    }
    $version = & $gitExe --version
    if ($LASTEXITCODE -ne 0) { throw "ポータブル Git を実行できません: $gitExe" }
    Write-Host "[Git] $version"
}

function Set-PortableGitEnvironment($Info) {
    $gitCmd = Join-Path $data 'tools\git\cmd'
    if (-not (Test-Path -LiteralPath (Join-Path $gitCmd 'git.exe') -PathType Leaf)) { throw 'ポータブル Git が導入されていません。' }
    $Info.EnvironmentVariables['PATH'] = $gitCmd + ';' + $Info.EnvironmentVariables['PATH']
}