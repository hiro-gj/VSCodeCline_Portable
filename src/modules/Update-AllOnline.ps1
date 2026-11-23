# ============================================================
# Update-AllOnline.ps1
# アップデート管理 [2] VSCode & Cline をまとめてオンラインアップデート
# ============================================================

function Update-AllOnline {
    $status = Show-UpdateStatus
    if (-not $status.VSCodeNeedsUpd -and -not $status.ClineNeedsUpd) {
        Write-Host 'VSCode 本体・Cline ともに最新バージョンです。' -ForegroundColor Green
        if (Confirm-Action '他の導入済み拡張機能（日本語パック等）の更新チェックのみ実行しますか？') {
            if (Wait-PortableCodeClosed -Required $false) {
                Invoke-PortableCodeCli @('--update-extensions')
                Write-Host '[完了] 拡張機能の更新チェックが完了しました。' -ForegroundColor Green
            }
        }
        return
    }
    if (-not (Confirm-Action '検出されたアップデートを適用しますか？（data・Cline 設定は保持されます）')) { return }
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
    if ($status.ClineNeedsUpd) {
        Write-Host 'Cline を最新バージョンへ更新しています...'
        Invoke-PortableCodeCli @('--install-extension', $clineExtensionId, '--force')
        $afterVer = Get-InstalledExtensionVersion $clineExtensionId
        Write-Host "[完了] Cline バージョン: $afterVer" -ForegroundColor Green
    }
    if (Confirm-Action '他の導入済み拡張機能（日本語パック等）も更新チェックしますか？') {
        Invoke-PortableCodeCli @('--update-extensions')
        Write-Host '[完了] 拡張機能の更新チェックが完了しました。' -ForegroundColor Green
    }
}
