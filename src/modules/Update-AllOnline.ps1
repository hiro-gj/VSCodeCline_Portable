# ============================================================
# Update-AllOnline.ps1
# アップデート管理 [2] VSCode / Cline / Playwright MCP / Git をまとめてオンラインアップデート
# ============================================================

function Update-AllOnline {
    $status = Show-UpdateStatus
    $anyNeedsUpd = ($status.VSCodeNeedsUpd -or $status.ClineNeedsUpd -or $status.McpNeedsUpd -or $status.GitNeedsUpd)
    if (-not $anyNeedsUpd) {
        Write-Host 'VSCode 本体・Cline・Playwright MCP・ポータブル Git はすべて最新バージョンです。' -ForegroundColor Green
        if (Confirm-Action '他の導入済み拡張機能（日本語パック等）の更新チェックのみ実行しますか？') {
            if (Wait-PortableCodeClosed -Required $false) {
                Invoke-PortableCodeCli @('--update-extensions')
                Initialize-Portable
                if ((Get-Command Set-PortableJapanese -ErrorAction SilentlyContinue) -and (Get-InstalledExtensionVersion 'MS-CEINTL.vscode-language-pack-ja')) {
                    Set-PortableJapanese
                }
                Write-Host '[完了] 拡張機能の更新チェックが完了しました。' -ForegroundColor Green
            }
        }
        return
    }
    if (-not (Confirm-Action '検出されたアップデートをすべて適用しますか？（data・Cline 設定は保持されます）')) { return }
    if ($status.VSCodeNeedsUpd) {
        if (-not (Wait-PortableCodeClosed -Required $true)) {
            Write-Host '[中止] アップデートをキャンセルしました。'
            return
        }
        Initialize-Portable
        $cur = Get-VSCodeMetadata $root
        $rel = $status.VSCodeRelease
        $dlZip = Save-VSCodeReleasePackage -CurrentInfo $cur -Release $rel
        $ok = Install-VSCodeFromZip -ZipPath $dlZip -ExpectedSha256 $rel.Sha256
        if (-not $ok) { return }
    }
    else {
        if (-not (Wait-PortableCodeClosed -Required $false)) { return }
    }
    if ($status.GitNeedsUpd -and $status.GitRelease) {
        Write-Host 'ポータブル Git (MinGit) を最新バージョンへ更新しています...'
        Install-PortableGit -TargetRelease $status.GitRelease.RawRelease -Force
        $afterGit = Get-InstalledPortableGitInfo
        Write-Host "[完了] ポータブル Git バージョン: $($afterGit.Version)" -ForegroundColor Green
    }
    if ($status.ClineNeedsUpd) {
        Write-Host 'Cline を最新バージョンへ更新しています...'
        Invoke-PortableCodeCli @('--install-extension', $clineExtensionId, '--force')
        $afterVer = Get-InstalledExtensionVersion $clineExtensionId
        Write-Host "[完了] Cline バージョン: $afterVer" -ForegroundColor Green
    }
    if ($status.McpNeedsUpd -and $status.McpRelease) {
        Write-Host 'Playwright MCP と専用 Chromium を最新バージョンへ更新しています...'
        [void](Install-PortablePlaywrightMcp -TargetVersion $status.McpRelease.Version -Force -VerifyAfterSwap)
        $afterMcp = Get-InstalledPlaywrightMcpVersion
        Write-Host "[完了] Playwright MCP バージョン: $afterMcp" -ForegroundColor Green
    }
    if (Confirm-Action '他の導入済み拡張機能（日本語パック等）も更新チェックしますか？') {
        Invoke-PortableCodeCli @('--update-extensions')
        Write-Host '[完了] 拡張機能の更新チェックが完了しました。' -ForegroundColor Green
    }
    Initialize-Portable
    if ((Get-Command Set-PortableJapanese -ErrorAction SilentlyContinue) -and (Get-InstalledExtensionVersion 'MS-CEINTL.vscode-language-pack-ja')) {
        Set-PortableJapanese
    }
}
