# ============================================================
# Show-UpdateMenu.ps1
# メインメニュー [6] アップデート管理サブメニュー
# ============================================================

function Show-UpdateMenu {
    while ($true) {
        $vsMeta = Get-VSCodeMetadata $root
        $vsLabel = if ($vsMeta.Version) { "$($vsMeta.Version) ($($vsMeta.Arch) / $($vsMeta.Quality))" } else { '不明' }
        $clineVer = Get-InstalledExtensionVersion $clineExtensionId
        $clineLabel = if ($clineVer) { $clineVer } else { '未インストール' }
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '  アップデート管理 (VSCode ポータブル本体 / Cline)'
        Write-Host '============================================================'
        Write-Host "  現在の VSCode : $vsLabel"
        Write-Host "  現在の Cline  : $clineLabel"
        Write-Host "  保護データ    : $data （設定・拡張機能・Cline履歴は保持）"
        Write-Host '------------------------------------------------------------'
        Write-Host '  [1] 最新バージョンの確認 (オンラインチェックのみ)'
        Write-Host '  [2] VSCode & Cline をまとめてオンラインアップデート'
        Write-Host '  [3] VSCode 本体のみオンラインアップデート'
        Write-Host '  [4] Cline (および他の拡張機能) をオンラインアップデート'
        Write-Host '  [5] ローカルファイル (.zip / .vsix) からオフライン更新'
        Write-Host '  [0] メインメニューに戻る'
        $sub = (Read-Host '番号を入力してください [Enter=0]').Trim()
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub -eq '0') { return }
        try {
            switch ($sub) {
                '1' { [void](Show-UpdateStatus); Wait-Menu }
                '2' { Update-AllOnline; Wait-Menu }
                '3' { [void](Update-VSCodeOnline $null); Wait-Menu }
                '4' { [void](Update-ClineOnline -PrefetchedVersion '' -AskOtherExtensions); Wait-Menu }
                '5' { Install-FromLocalPackage; Wait-Menu }
                default { Write-Host '[注意] 0～5 の番号を入力してください。' }
            }
        }
        catch {
            Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
            Wait-Menu
        }
    }
}
