# ============================================================
# Update-ClineOnline.ps1
# アップデート管理 [4] Cline (および他の拡張機能) のオンライン更新・CLI実行
# ============================================================

function Invoke-PortableCodeCli([string[]]$CliArgs) {
    if (-not (Test-Path -LiteralPath $code -PathType Leaf)) {
        throw "Code.exe が見つかりません: $code"
    }
    Initialize-Portable
    $meta = Get-VSCodeMetadata $root
    if (-not $meta.CliJs -or -not (Test-Path -LiteralPath $meta.CliJs -PathType Leaf)) {
        throw "VSCode CLI スクリプトが見つかりません: $($meta.CliJs)"
    }
    $fullArgs = @($meta.CliJs, '--user-data-dir', (Join-Path $data 'user-data'), '--extensions-dir', (Join-Path $data 'extensions')) + $CliArgs
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $code
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.Arguments = (@($fullArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    Set-PortableChildEnvironment -Info $info -ExtraEnvironment @{ ELECTRON_RUN_AS_NODE = '1' }
    $proc = [Diagnostics.Process]::Start($info)
    try {
        Wait-PortableProcess $proc 'VS Code 拡張機能を処理しています'
        if ($proc.ExitCode -ne 0) {
            throw "VSCode CLI が終了コード $($proc.ExitCode) で失敗しました。"
        }
    }
    finally { $proc.Dispose() }
    Initialize-Portable
}

function Update-ClineOnline([string]$PrefetchedVersion, [switch]$AskOtherExtensions) {
    $curVer = Get-InstalledExtensionVersion $clineExtensionId
    $latestVer = $PrefetchedVersion
    if (-not $latestVer) {
        Write-Host 'Visual Studio Marketplace へ Cline の最新バージョンを確認しています...'
        try { $latestVer = Get-LatestMarketplaceVersion $clineExtensionId } catch {}
    }
    $curLabel = if ($curVer) { $curVer } else { '未インストール' }
    if ($latestVer) {
        Write-Host "  Cline 拡張  : 現在 $curLabel -> 最新 $latestVer"
    }
    else {
        Write-Host "  Cline 拡張  : 現在 $curLabel (Marketplace 事前照会スキップ)"
    }
    $doCline = $false
    if (-not $curVer) {
        $doCline = Confirm-Action "Cline ($clineExtensionId) をインストールしますか？"
    }
    elseif ($latestVer -and (Compare-VersionString $curVer $latestVer) -ge 0) {
        Write-Host '  -> Cline は既に最新バージョンです。' -ForegroundColor Green
        $doCline = Confirm-Action 'Cline を強制再インストールしますか？'
    }
    else {
        $targetLabel = if ($latestVer) { "$curVer から $latestVer へ" } else { '最新版へ' }
        $doCline = Confirm-Action "Cline を $targetLabel アップデートしますか？"
    }
    $doOthers = $false
    if ($AskOtherExtensions) {
        $doOthers = Confirm-Action '他の導入済み拡張機能（日本語パック等）もあわせて更新チェックしますか？'
    }
    if (-not $doCline -and -not $doOthers) { return $false }
    if (-not (Wait-PortableCodeClosed -Required $false)) {
        Write-Host '[中止] 拡張機能の更新をキャンセルしました。'
        return $false
    }
    if ($doCline) {
        Write-Host 'Cline をインストール／更新しています...'
        Invoke-PortableCodeCli @('--install-extension', $clineExtensionId, '--force')
        $afterVer = Get-InstalledExtensionVersion $clineExtensionId
        Write-Host "[完了] Cline バージョン: $afterVer （Cline 設定・履歴 $cline は保持されています）" -ForegroundColor Green
    }
    if ($doOthers) {
        Write-Host '導入済み拡張機能の更新を実行しています...'
        Invoke-PortableCodeCli @('--update-extensions')
        Write-Host '[完了] 拡張機能の更新チェックが完了しました。' -ForegroundColor Green
    }
    Initialize-Portable
    if ((Get-Command Set-PortableJapanese -ErrorAction SilentlyContinue) -and (Get-InstalledExtensionVersion 'MS-CEINTL.vscode-language-pack-ja')) {
        Set-PortableJapanese
    }
    return $true
}
