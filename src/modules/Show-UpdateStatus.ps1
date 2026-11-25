# ============================================================
# Show-UpdateStatus.ps1
# アップデート管理 [1] 最新バージョンの確認 (オンライン照会・プロキシ初期化)
# ============================================================

function Initialize-NetworkConfig {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {}
    $proxyUrl = $env:HTTPS_PROXY
    if (-not $proxyUrl) { $proxyUrl = $env:HTTP_PROXY }
    if (-not $proxyUrl) {
        $settingsPath = Join-Path $data 'user-data\User\settings.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try {
                $sObj = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($sObj.'http.proxy') { $proxyUrl = [string]$sObj.'http.proxy' }
            }
            catch {}
        }
    }
    if ($proxyUrl) {
        try {
            $wp = New-Object Net.WebProxy($proxyUrl, $true)
            $wp.Credentials = [Net.CredentialCache]::DefaultCredentials
            [Net.WebRequest]::DefaultWebProxy = $wp
            return
        }
        catch {}
    }
    if ([Net.WebRequest]::DefaultWebProxy) {
        [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultCredentials
    }
}

function Get-LatestVSCodeRelease($CurrentInfo) {
    Initialize-NetworkConfig
    $ProgressPreference = 'SilentlyContinue'
    $uri = "$($CurrentInfo.UpdateUrl)/api/update/$($CurrentInfo.Platform)/$($CurrentInfo.Quality)/latest"
    $res = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'User-Agent' = 'VSCode-Portable-Launcher/1.0' } -TimeoutSec 30
    if (-not $res -or -not $res.url -or -not $res.productVersion) {
        throw "VSCode 更新情報の取得結果が不正です ($uri)"
    }
    return [pscustomobject]@{
        Version = [string]$res.productVersion
        Commit  = [string]$res.version
        Url     = [string]$res.url
        Sha256  = [string]$res.sha256hash
    }
}

function Get-LatestMarketplaceVersion([string]$ExtensionId) {
    Initialize-NetworkConfig
    $ProgressPreference = 'SilentlyContinue'
    $uri = 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery'
    $body = '{"filters":[{"criteria":[{"filterType":7,"value":"' + $ExtensionId + '"}]}],"flags":103}'
    $headers = @{
        'Accept'     = 'application/json;api-version=3.0-preview.1'
        'User-Agent' = 'VSCode-Portable-Launcher/1.0'
    }
    $res = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30
    $ext = $null
    if ($res -and $res.results -and $res.results.Count -gt 0 -and $res.results[0].extensions -and $res.results[0].extensions.Count -gt 0) {
        $ext = $res.results[0].extensions[0]
    }
    if (-not $ext -or -not $ext.versions) { return $null }
    foreach ($v in @($ext.versions)) {
        $isPre = $false
        if ($v.properties) {
            foreach ($prop in @($v.properties)) {
                if (($prop.key -eq 'Microsoft.VisualStudio.Code.PreRelease') -and ($prop.value -ieq 'true')) {
                    $isPre = $true
                    break
                }
            }
        }
        if (-not $isPre -and $v.version) { return [string]$v.version }
    }
    return [string]$ext.versions[0].version
}

function Get-LatestPlaywrightMcpRelease {
    Initialize-NetworkConfig
    $ProgressPreference = 'SilentlyContinue'
    $uri = 'https://registry.npmjs.org/@playwright/mcp/latest'
    $res = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'User-Agent' = 'VSCode-Portable-Launcher/1.0' } -TimeoutSec 30
    if (-not $res -or -not $res.version -or ([string]$res.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')) {
        throw "Playwright MCP の最新バージョン情報が不正です ($uri)"
    }
    return [pscustomobject]@{
        Version   = [string]$res.version
        Tarball   = if ($res.dist) { [string]$res.dist.tarball } else { '' }
        Integrity = if ($res.dist) { [string]$res.dist.integrity } else { '' }
    }
}

function Get-LatestPortableGitRelease {
    Initialize-NetworkConfig
    $ProgressPreference = 'SilentlyContinue'
    $uri = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $release = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'User-Agent' = 'VSCode-Portable-Launcher/1.0' } -TimeoutSec 30
    $arch = (Get-PortableCodeArchitecture $code).Arch
    $suffix = switch ($arch) { 'arm64' { 'arm64' } 'x64' { '64-bit' } 'x86' { '32-bit' } default { throw "未対応の Git アーキテクチャ: $arch" } }
    $asset = $release.assets | Where-Object { $_.name -match ('^MinGit-[0-9.]+-' + $suffix + '\.zip$') } | Select-Object -First 1
    if (-not $asset -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw 'SHA-256 付きの公式 MinGit ZIP が見つかりません。'
    }
    $sha = $Matches[1]
    $rawTag = if ($release.tag_name) { ([string]$release.tag_name).Trim() -replace '^[vV]', '' } else { ([string]$asset.name -replace '^MinGit-([0-9.]+)-.*$', '$1') }
    return [pscustomobject]@{
        Version           = $rawTag
        ComparableVersion = ConvertTo-ComparableGitVersion $rawTag
        AssetName         = [string]$asset.name
        Url               = [string]$asset.browser_download_url
        Sha256            = $sha
        RawRelease        = $release
    }
}

function Show-UpdateStatus {
    $vsCur    = Get-VSCodeMetadata $root
    $clineCur = Get-InstalledExtensionVersion $clineExtensionId
    $mcpCur   = Get-InstalledPlaywrightMcpVersion
    $gitCur   = Get-InstalledPortableGitInfo
    Write-Host 'オンラインで最新バージョンを確認しています (VSCode / Cline / Playwright MCP / Git)...'

    $vsRel = $null;    $vsErr = $null
    try { $vsRel = Get-LatestVSCodeRelease $vsCur } catch { $vsErr = $_.Exception.Message }
    $clineLatest = $null; $clineErr = $null
    try { $clineLatest = Get-LatestMarketplaceVersion $clineExtensionId } catch { $clineErr = $_.Exception.Message }
    $mcpRel = $null;   $mcpErr = $null
    try { $mcpRel = Get-LatestPlaywrightMcpRelease } catch { $mcpErr = $_.Exception.Message }
    $gitRel = $null;   $gitErr = $null
    try { $gitRel = Get-LatestPortableGitRelease } catch { $gitErr = $_.Exception.Message }

    $vsCurLabel = if ($vsCur.Version) { $vsCur.Version } else { '未検出' }
    $vsHasUpdate = $false
    if ($vsRel) {
        $vsHasUpdate = (-not $vsCur.Version) -or (-not ($vsCur.Commit -and $vsRel.Commit -and ($vsCur.Commit -ieq $vsRel.Commit)) -and ((Compare-VersionString $vsCur.Version $vsRel.Version) -lt 0))
        $vsTag = if (-not $vsCur.Version) { '[未導入・導入可]' } elseif ($vsHasUpdate) { '[アップデートあり]' } else { '[最新です]' }
        Write-Host "  VSCode 本体    : 現在 $vsCurLabel -> 最新 $($vsRel.Version) $vsTag" -ForegroundColor $(if ($vsHasUpdate) { 'Yellow' } else { 'Green' })
    }
    else {
        Write-Host "  VSCode 本体    : 現在 $vsCurLabel (更新サーバー照会失敗: $vsErr)" -ForegroundColor Yellow
    }

    $clineCurLabel = if ($clineCur) { $clineCur } else { '未インストール' }
    $clineHasUpdate = $false
    if ($clineLatest) {
        $clineHasUpdate = (-not $clineCur) -or ((Compare-VersionString $clineCur $clineLatest) -lt 0)
        $clineTag = if (-not $clineCur) { '[未導入・インストール可]' } elseif ($clineHasUpdate) { '[アップデートあり]' } else { '[最新です]' }
        Write-Host "  Cline 拡張     : 現在 $clineCurLabel -> 最新 $clineLatest $clineTag" -ForegroundColor $(if ($clineHasUpdate) { 'Yellow' } else { 'Green' })
    }
    else {
        $detail = if ($clineErr) { ": $clineErr" } else { '' }
        Write-Host "  Cline 拡張     : 現在 $clineCurLabel (Marketplace 照会失敗$detail)" -ForegroundColor Yellow
    }

    $mcpCurLabel = if ($mcpCur) { $mcpCur } else { '未インストール' }
    $mcpHasUpdate = $false
    if ($mcpRel) {
        $mcpHasUpdate = (-not $mcpCur) -or ((Compare-VersionString $mcpCur $mcpRel.Version) -lt 0)
        $mcpTag = if (-not $mcpCur) { '[未導入・インストール可]' } elseif ($mcpHasUpdate) { '[アップデートあり]' } else { '[最新です]' }
        Write-Host "  Playwright MCP : 現在 $mcpCurLabel -> 最新 $($mcpRel.Version) $mcpTag" -ForegroundColor $(if ($mcpHasUpdate) { 'Yellow' } else { 'Green' })
    }
    else {
        $detail = if ($mcpErr) { ": $mcpErr" } else { '' }
        Write-Host "  Playwright MCP : 現在 $mcpCurLabel (npm 照会失敗$detail)" -ForegroundColor Yellow
    }

    $gitCurLabel = if ($gitCur) { $gitCur.Version } else { '未インストール' }
    $gitHasUpdate = $false
    if ($gitRel) {
        $sameGitHash = ($gitCur -and $gitCur.Sha256 -and $gitRel.Sha256 -and ($gitCur.Sha256 -ieq $gitRel.Sha256))
        $gitHasUpdate = (-not $gitCur) -or (-not $sameGitHash -and ((Compare-VersionString $gitCur.ComparableVersion $gitRel.ComparableVersion) -lt 0))
        $gitTag = if (-not $gitCur) { '[未導入・インストール可]' } elseif ($gitHasUpdate) { '[アップデートあり]' } else { '[最新です]' }
        Write-Host "  ポータブル Git : 現在 $gitCurLabel -> 最新 $($gitRel.Version) $gitTag" -ForegroundColor $(if ($gitHasUpdate) { 'Yellow' } else { 'Green' })
    }
    else {
        $detail = if ($gitErr) { ": $gitErr" } else { '' }
        Write-Host "  ポータブル Git : 現在 $gitCurLabel (GitHub 照会失敗$detail)" -ForegroundColor Yellow
    }

    if (-not $vsRel -and -not $clineLatest -and -not $mcpRel -and -not $gitRel) {
        throw 'オンライン更新サーバーへ接続できませんでした。ネットワーク・プロキシ設定を確認するか、[7] ローカルファイル更新をご利用ください。'
    }
    return [pscustomobject]@{
        VSCodeRelease  = $vsRel
        VSCodeNeedsUpd = [bool]($vsRel -and $vsHasUpdate)
        ClineLatest    = $clineLatest
        ClineInstalled = $clineCur
        ClineNeedsUpd  = [bool]($clineLatest -and $clineHasUpdate)
        McpRelease     = $mcpRel
        McpInstalled   = $mcpCur
        McpNeedsUpd    = [bool]($mcpRel -and $mcpHasUpdate)
        GitRelease     = $gitRel
        GitInstalled   = $gitCur
        GitNeedsUpd    = [bool]($gitRel -and $gitHasUpdate)
    }
}
