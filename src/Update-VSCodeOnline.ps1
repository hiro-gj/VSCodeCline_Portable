# ============================================================
# Update-VSCodeOnline.ps1
# アップデート管理 [3] VSCode 本体のダウンロード・ZIP展開・入れ替え・ロールバック
# ============================================================

function Save-UrlToFile([string]$Url, [string]$DestinationPath, [string]$Activity) {
    Initialize-NetworkConfig
    [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $DestinationPath))
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'VSCode-Portable-Launcher/1.0'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    $success = $false
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $inStream = $resp.GetResponseStream()
        try {
            $outStream = [IO.File]::Create($DestinationPath)
            try {
                $buffer = New-Object byte[] 65536
                $received = 0L
                $sw = [Diagnostics.Stopwatch]::StartNew()
                while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $outStream.Write($buffer, 0, $read)
                    $received += $read
                    if ($sw.ElapsedMilliseconds -ge 200) {
                        $sw.Restart()
                        $mb = [Math]::Round($received / 1MB, 1)
                        if ($total -gt 0) {
                            $totalMb = [Math]::Round($total / 1MB, 1)
                            $pct = [int][Math]::Min(100, [Math]::Floor(($received * 100.0) / $total))
                            Write-Progress -Activity $Activity -Status "$mb MB / $totalMb MB ($pct%)" -PercentComplete $pct
                        }
                        else {
                            Write-Progress -Activity $Activity -Status "$mb MB 受信済み"
                        }
                    }
                }
                $success = $true
            }
            finally { $outStream.Dispose() }
        }
        finally { $inStream.Dispose() }
    }
    finally {
        Write-Progress -Activity $Activity -Completed
        $resp.Close()
        if (-not $success -and (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Expand-ZipArchiveFast([string]$ZipPath, [string]$DestinationDir) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    [void][IO.Directory]::CreateDirectory($DestinationDir)
    $destFull = ([IO.Path]::GetFullPath($DestinationDir)).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $total = $archive.Entries.Count
        $index = 0
        foreach ($entry in $archive.Entries) {
            $index++
            $targetPath = [IO.Path]::GetFullPath((Join-Path $DestinationDir $entry.FullName))
            if (-not $targetPath.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "ZIP 内に不正な相対パスが含まれています: $($entry.FullName)"
            }
            if ([string]::IsNullOrEmpty($entry.Name) -or $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                [void][IO.Directory]::CreateDirectory($targetPath)
            }
            else {
                [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $targetPath))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            }
            if (($index % 200) -eq 0 -or $index -eq $total) {
                $pct = if ($total -gt 0) { [int][Math]::Min(100, [Math]::Floor(($index * 100.0) / $total)) } else { 100 }
                Write-Progress -Activity 'VSCode アーカイブを展開中...' -Status "$index / $total ファイル ($pct%)" -PercentComplete $pct
            }
        }
    }
    finally {
        Write-Progress -Activity 'VSCode アーカイブを展開中...' -Completed
        $archive.Dispose()
    }
}

function Invoke-UpdateFileOperation([scriptblock]$Operation, [string]$Path) {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            & $Operation
            return
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            if (($cause -isnot [IO.IOException] -and $cause -isnot [UnauthorizedAccessException]) -or $attempt -eq 4) {
                throw "更新ファイルの操作に失敗しました: $Path / $($cause.Message)"
            }
            Start-Sleep -Milliseconds (300 * ($attempt + 1))
        }
    }
}

function Copy-UpdateItem([string]$Source, [string]$Destination) {
    # Do not rename extracted directories: a directory handle held by a scanner
    # can deny Directory.Move even though every file is readable/copyable.
    if (Test-Path -LiteralPath $Source -PathType Container) {
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach ($child in (Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
            Copy-UpdateItem -Source $child.FullName -Destination (Join-Path $Destination $child.Name)
        }
    }
    else {
        Invoke-UpdateFileOperation -Path $Source -Operation { [IO.File]::Copy($Source, $Destination, $false) }
    }
}

function Move-UpdateItem([string]$Source, [string]$Destination) {
    Invoke-UpdateFileOperation -Path $Source -Operation {
        if (Test-Path -LiteralPath $Source -PathType Container) { [IO.Directory]::Move($Source, $Destination) }
        else { [IO.File]::Move($Source, $Destination) }
    }
}

function Remove-UpdateItem([string]$Path) {
    Invoke-UpdateFileOperation -Path $Path -Operation {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    }
}

function Save-VSCodeReleasePackage($CurrentInfo, $Release) {
    $platform = $CurrentInfo.Platform -replace '-archive$', ''
    if ($platform -notin @('win32', 'win32-x64', 'win32-arm64') -or $Release.Version -notmatch '^\d+(?:\.\d+)+(?:-[0-9A-Za-z.-]+)?$') {
        throw '更新パッケージのプラットフォームまたはバージョンが不正です。'
    }
    $zipPath = Join-Path $root "VSCode-$platform-$($Release.Version).zip"
    if ($Release.Sha256 -and (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ieq $Release.Sha256) {
            Write-Host "SHA-256 確認済みの ZIP を再利用します: $zipPath"
            return $zipPath
        }
    }
    $partialPath = $zipPath + '.' + [guid]::NewGuid().ToString('N') + '.download'
    try {
        Write-Host "ダウンロード中: $($Release.Url)"
        Write-Host "ZIP 保存先: $zipPath （更新後も保持します）"
        Save-UrlToFile -Url $Release.Url -DestinationPath $partialPath -Activity "VSCode $($Release.Version) をダウンロード中..."
        if ($Release.Sha256 -and (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ine $Release.Sha256) {
            throw 'ダウンロードした ZIP の SHA-256 ハッシュが一致しません。本体は変更していません。'
        }
        if (Test-Path -LiteralPath $zipPath -PathType Leaf) { Remove-Item -LiteralPath $zipPath -Force }
        [IO.File]::Move($partialPath, $zipPath)
        return $zipPath
    }
    finally {
        if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
            Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-VSCodeFromZip([string]$ZipPath, [string]$ExpectedSha256) {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "指定された ZIP ファイルが見つかりません: $ZipPath"
    }
    if ($ExpectedSha256) {
        Write-Host 'SHA-256 ハッシュを検証しています...'
        $actualHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
        if ($actualHash -ine $ExpectedSha256) {
            throw "SHA-256 ハッシュが一致しません (期待値: $ExpectedSha256 / 実際: $actualHash)"
        }
    }
    Initialize-Portable
    if (-not (Wait-PortableCodeClosed -Required $true)) {
        Write-Host '[中止] VSCode 本体の更新をキャンセルしました。'
        return $false
    }
    # Never erase a backup left by an earlier, incomplete rollback.
    $workDir = Join-Path $data ('tmp\vscode-update\' + [guid]::NewGuid().ToString('N'))
    $stageDir = Join-Path $workDir 'stage'
    $backupDir = Join-Path $workDir 'backup'
    Write-Host '更新パッケージを展開・検証しています...'
    try { Expand-ZipArchiveFast -ZipPath $ZipPath -DestinationDir $stageDir }
    catch {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    $stageRoot = $null
    if (Test-Path -LiteralPath (Join-Path $stageDir 'Code.exe') -PathType Leaf) {
        $stageRoot = $stageDir
    }
    else {
        $subDirs = @(Get-ChildItem -LiteralPath $stageDir -Directory)
        if ($subDirs.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $subDirs[0].FullName 'Code.exe') -PathType Leaf)) {
            $stageRoot = $subDirs[0].FullName
        }
    }
    if (-not $stageRoot) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        throw 'ZIP 内に Code.exe が見つかりません。Windows 用 ZIP 版 (VSCode-win32-*.zip) を指定してください。'
    }
    $curInfo = Get-VSCodeMetadata $root
    $newInfo = Get-VSCodeMetadata $stageRoot
    if (-not $newInfo.Version) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        throw '展開されたアーカイブから VSCode バージョン情報 (product.json) を確認できませんでした。'
    }
    if ($curInfo.Arch -and $newInfo.Arch -and ($curInfo.Arch -ine $newInfo.Arch)) {
        if (-not (Confirm-Action "アーキテクチャが異なります (現在: $($curInfo.Arch) -> 新: $($newInfo.Arch))。続行しますか？")) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    $protected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$protected.Add('data')
    if ($env:PORTABLE_LAUNCH_SELF) {
        [void]$protected.Add((Split-Path -Leaf $env:PORTABLE_LAUNCH_SELF))
    }
    [void]$protected.Add('VSCode_Portable_README.md')
    if ($portableScriptFiles) {
        foreach ($scriptFile in $portableScriptFiles) {
            [void]$protected.Add($scriptFile)
        }
    }
    $stageItems = @(Get-ChildItem -LiteralPath $stageRoot -Force | Where-Object { -not $protected.Contains($_.Name) })
    $retireSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $stageItems) {
        if (Test-Path -LiteralPath (Join-Path $root $item.Name)) { [void]$retireSet.Add($item.Name) }
    }
    foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if (-not $protected.Contains($dir.Name) -and ($dir.Name -match '^[0-9a-f]{10}$')) {
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'resources\app\product.json') -PathType Leaf) {
                [void]$retireSet.Add($dir.Name)
            }
        }
    }
    if (-not ($stageItems | Where-Object { $_.Name -ieq 'resources' }) -and (Test-Path -LiteralPath (Join-Path $root 'resources\app\product.json') -PathType Leaf)) {
        [void]$retireSet.Add('resources')
        if (Test-Path -LiteralPath (Join-Path $root 'locales')) { [void]$retireSet.Add('locales') }
    }
    if (-not (Wait-PortableCodeClosed -Required $true)) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '[中止] VSCode 本体の更新をキャンセルしました。'
        return $false
    }
    [void][IO.Directory]::CreateDirectory($backupDir)
    $prevCwd = [Environment]::CurrentDirectory
    $movedBackup = New-Object 'Collections.Generic.List[string]'
    $installedItems = New-Object 'Collections.Generic.List[string]'
    Write-Host "VSCode 本体を入れ替えています ($($curInfo.Version) -> $($newInfo.Version))..."
    try {
        [Environment]::CurrentDirectory = $env:SystemRoot
        foreach ($name in $retireSet) {
            $src = Join-Path $root $name
            $dst = Join-Path $backupDir $name
            Move-UpdateItem -Source $src -Destination $dst
            $movedBackup.Add($name)
        }
        foreach ($item in $stageItems) {
            $src = $item.FullName
            $dst = Join-Path $root $item.Name
            # Register before copying so a partially copied directory is rolled back.
            $installedItems.Add($item.Name)
            Copy-UpdateItem -Source $src -Destination $dst
        }
        $after = Get-VSCodeMetadata $root
        if ($after.Version -ne $newInfo.Version -or ($newInfo.Commit -and $after.Commit -ine $newInfo.Commit)) {
            throw '入れ替え後の VSCode バージョン検証に失敗しました。'
        }
    }
    catch {
        $swapErr = $_
        $rollbackErrors = New-Object 'Collections.Generic.List[string]'
        for ($i = $installedItems.Count - 1; $i -ge 0; $i--) {
            $n = $installedItems[$i]
            $p = Join-Path $root $n
            try {
                Remove-UpdateItem -Path $p
            }
            catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        for ($i = $movedBackup.Count - 1; $i -ge 0; $i--) {
            $n = $movedBackup[$i]
            $b = Join-Path $backupDir $n
            $p = Join-Path $root $n
            try {
                Move-UpdateItem -Source $b -Destination $p
            }
            catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "更新に失敗し、復元も一部完了していません。VSCode は起動せず、バックアップを保全してください: $backupDir / 更新エラー: $($swapErr.Exception.Message) / 復元エラー: $($rollbackErrors -join ' / ')"
        }
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "ファイル入れ替えに失敗したため更新前の状態へ復元しました。VSCode や関連プロセスを閉じてから再実行してください。ZIP は保持されています。詳細: $($swapErr.Exception.Message)"
    }
    finally {
        [Environment]::CurrentDirectory = $prevCwd
    }
    try { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
    catch { Write-Host "[注意] 更新用一時フォルダを削除できませんでした（更新は完了）: $workDir" -ForegroundColor Yellow }
    Write-Host "[完了] VSCode 本体を $($after.Version) へアップデートしました（data・Cline データは保持されています）。" -ForegroundColor Green
    return $true
}

function Update-VSCodeOnline([object]$PrefetchedRelease) {
    $cur = Get-VSCodeMetadata $root
    $rel = if ($PrefetchedRelease) { $PrefetchedRelease } else {
        Write-Host 'Microsoft 公式サーバーへ最新バージョンを確認しています...'
        Get-LatestVSCodeRelease $cur
    }
    $sameCommit = ($cur.Commit -and $rel.Commit -and ($cur.Commit -ieq $rel.Commit))
    $cmp = Compare-VersionString $cur.Version $rel.Version
    Write-Host "  VSCode 本体 : 現在 $($cur.Version) -> 最新 $($rel.Version)"
    if ($sameCommit -or $cmp -eq 0) {
        Write-Host '  -> VSCode 本体は既に最新バージョンです。' -ForegroundColor Green
        if (-not (Confirm-Action '同じバージョンを再インストールしますか？')) { return $false }
    }
    elseif ($cmp -gt 0) {
        Write-Host '  -> 現在のバージョンの方が公開安定版より新しいです。' -ForegroundColor Yellow
        if (-not (Confirm-Action "公開版 $($rel.Version) で上書きしますか？")) { return $false }
    }
    else {
        if (-not (Confirm-Action "VSCode 本体を $($cur.Version) から $($rel.Version) へアップデートしますか？")) { return $false }
    }
    if (-not (Wait-PortableCodeClosed -Required $true)) {
        Write-Host '[中止] VSCode 本体の更新をキャンセルしました。'
        return $false
    }
    Initialize-Portable
    $dlZip = Save-VSCodeReleasePackage -CurrentInfo $cur -Release $rel
    return (Install-VSCodeFromZip -ZipPath $dlZip -ExpectedSha256 $rel.Sha256)
}
