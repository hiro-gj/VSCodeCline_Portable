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
        $mcpVer = Get-InstalledPlaywrightMcpVersion
        $mcpLabel = if ($mcpVer) { $mcpVer } else { '未インストール' }
        $gitInfo = Get-InstalledPortableGitInfo
        $gitLabel = if ($gitInfo) { $gitInfo.Version } else { '未インストール' }
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '  アップデート管理 (VSCode / Cline / Playwright MCP / Git)'
        Write-Host '============================================================'
        Write-Host "  現在の VSCode         : $vsLabel"
        Write-Host "  現在の Cline          : $clineLabel"
        Write-Host "  現在の Playwright MCP : $mcpLabel"
        Write-Host "  現在の ポータブル Git : $gitLabel"
        Write-Host "  保護データ            : $data （設定・拡張機能・Cline履歴は保持）"
        Write-Host '------------------------------------------------------------'
        Write-Host '  [1] 最新バージョンの確認 (オンラインチェックのみ)'
        Write-Host '  [2] すべてまとめてオンラインアップデート (VSCode / Cline / MCP / Git)'
        Write-Host '  [3] VSCode 本体のみオンラインアップデート'
        Write-Host '  [4] Cline (および他の拡張機能) をオンラインアップデート'
        Write-Host '  [5] Playwright MCP をオンラインアップデート'
        Write-Host '  [6] ポータブル Git (MinGit) をオンラインアップデート'
        Write-Host '  [7] ローカルファイル (.zip / .vsix / .tgz) からオフライン更新'
        Write-Host '  [0] メインメニューに戻る'
        $sub = (Read-Host '番号を入力してください [Enter=0]').Trim()
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub -eq '0') { return }
        try {
            switch ($sub) {
                '1' { [void](Show-UpdateStatus); Wait-Menu }
                '2' { Update-AllOnline; Wait-Menu }
                '3' { [void](Update-VSCodeOnline $null); Wait-Menu }
                '4' { [void](Update-ClineOnline -PrefetchedVersion '' -AskOtherExtensions); Wait-Menu }
                '5' { [void](Update-McpOnline $null); Wait-Menu }
                '6' { [void](Update-GitOnline $null); Wait-Menu }
                '7' { Install-FromLocalPackage; Wait-Menu }
                default { Write-Host '[注意] 0～7 の番号を入力してください。' }
            }
        }
        catch {
            Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
            Wait-Menu
        }
    }
}
