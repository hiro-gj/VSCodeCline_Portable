# ============================================================
# Get-PortableMetadata.ps1
# VSCode 本体・拡張機能のメタデータ取得、バージョン比較、稼働プロセス監視
# ============================================================

function Get-AppDirectory([string]$BaseRoot) {
    $codeCmd = Join-Path $BaseRoot 'bin\code.cmd'
    if (Test-Path -LiteralPath $codeCmd -PathType Leaf) {
        $cmdText = [IO.File]::ReadAllText($codeCmd, [Text.Encoding]::UTF8)
        $m = [regex]::Match($cmdText, '\.\.[\\/]([^\\/"]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js')
        if ($m.Success) {
            $candidate = Join-Path $BaseRoot ($m.Groups[1].Value + '\resources\app')
            if (Test-Path -LiteralPath (Join-Path $candidate 'product.json') -PathType Leaf) {
                return $candidate
            }
        }
    }
    $legacy = Join-Path $BaseRoot 'resources\app'
    if (Test-Path -LiteralPath (Join-Path $legacy 'product.json') -PathType Leaf) {
        return $legacy
    }
    $dirs = Get-ChildItem -LiteralPath $BaseRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($d in $dirs) {
        if ($d.Name -ieq 'data') { continue }
        $candidate = Join-Path $d.FullName 'resources\app'
        if (Test-Path -LiteralPath (Join-Path $candidate 'product.json') -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Get-PortableCodeArchitecture([string]$ExePath) {
    if (Test-Path -LiteralPath $ExePath -PathType Leaf) {
        $stream = [IO.File]::Open($ExePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $reader = New-Object IO.BinaryReader($stream)
            [void]$stream.Seek(0x3C, [IO.SeekOrigin]::Begin)
            $peOffset = $reader.ReadInt32()
            [void]$stream.Seek($peOffset + 4, [IO.SeekOrigin]::Begin)
            switch ($reader.ReadUInt16()) {
                0x8664 { return @{ Arch = 'x64'; Platform = 'win32-x64-archive' } }
                0xAA64 { return @{ Arch = 'arm64'; Platform = 'win32-arm64-archive' } }
                0x014C { return @{ Arch = 'x86'; Platform = 'win32-archive' } }
            }
        }
        catch {}
        finally { $stream.Dispose() }
    }
    if ([Environment]::Is64BitOperatingSystem) { return @{ Arch = 'x64'; Platform = 'win32-x64-archive' } }
    return @{ Arch = 'x86'; Platform = 'win32-archive' }
}

function Get-VSCodeMetadata([string]$BaseRoot) {
    $archInfo = Get-PortableCodeArchitecture (Join-Path $BaseRoot 'Code.exe')
    $appDir = Get-AppDirectory $BaseRoot
    $version = $null
    $commit = $null
    $quality = 'stable'
    $updateUrl = 'https://update.code.visualstudio.com'
    $cliJs = $null
    if ($appDir) {
        $cliJs = Join-Path $appDir 'out\cli.js'
        $productPath = Join-Path $appDir 'product.json'
        if (Test-Path -LiteralPath $productPath -PathType Leaf) {
            $product = [IO.File]::ReadAllText($productPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($product.version) { $version = [string]$product.version }
            if ($product.commit) { $commit = [string]$product.commit }
            if ($product.quality) { $quality = [string]$product.quality }
            if ($product.updateUrl) { $updateUrl = ([string]$product.updateUrl).TrimEnd('/') }
        }
        if (-not $version) {
            $pkgPath = Join-Path $appDir 'package.json'
            if (Test-Path -LiteralPath $pkgPath -PathType Leaf) {
                $pkg = [IO.File]::ReadAllText($pkgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($pkg.version) { $version = [string]$pkg.version }
            }
        }
    }
    return [pscustomobject]@{
        Version = $version; Commit = $commit; Quality = $quality; UpdateUrl = $updateUrl
        Arch = $archInfo.Arch; Platform = $archInfo.Platform; AppDir = $appDir; CliJs = $cliJs
    }
}

function Compare-VersionString([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left) -and [string]::IsNullOrWhiteSpace($Right)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($Left)) { return -1 }
    if ([string]::IsNullOrWhiteSpace($Right)) { return 1 }
    $lMatch = [regex]::Match($Left.Trim(), '^\d+(?:\.\d+)*')
    $rMatch = [regex]::Match($Right.Trim(), '^\d+(?:\.\d+)*')
    if (-not $lMatch.Success -or -not $rMatch.Success) {
        return [string]::Compare($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
    }
    $lParts = $lMatch.Value -split '\.'
    $rParts = $rMatch.Value -split '\.'
    $max = [Math]::Max($lParts.Count, $rParts.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $lv = if ($i -lt $lParts.Count) { [long]$lParts[$i] } else { 0L }
        $rv = if ($i -lt $rParts.Count) { [long]$rParts[$i] } else { 0L }
        if ($lv -lt $rv) { return -1 }
        if ($lv -gt $rv) { return 1 }
    }
    return 0
}

function Get-InstalledExtensionVersion([string]$ExtensionId) {
    $extDir = Join-Path $data 'extensions'
    if (-not (Test-Path -LiteralPath $extDir -PathType Container)) { return $null }
    $best = $null
    $manifestPath = Join-Path $extDir 'extensions.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $entries = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($entry in @($entries)) {
                if ($entry.identifier -and ($entry.identifier.id -ieq $ExtensionId) -and $entry.version) {
                    $rel = [string]$entry.relativeLocation
                    if (-not $rel -or (Test-Path -LiteralPath (Join-Path $extDir $rel) -PathType Container)) {
                        if (-not $best -or (Compare-VersionString $best ([string]$entry.version)) -lt 0) {
                            $best = [string]$entry.version
                        }
                    }
                }
            }
        }
        catch {}
    }
    if ($best) { return $best }
    foreach ($folder in (Get-ChildItem -LiteralPath $extDir -Directory -Filter "$ExtensionId-*" -ErrorAction SilentlyContinue)) {
        $pkgFile = Join-Path $folder.FullName 'package.json'
        if (Test-Path -LiteralPath $pkgFile -PathType Leaf) {
            try {
                $pkg = [IO.File]::ReadAllText($pkgFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ((($pkg.publisher + '.' + $pkg.name) -ieq $ExtensionId) -and $pkg.version) {
                    $ver = [string]$pkg.version
                    if (-not $best -or (Compare-VersionString $best $ver) -lt 0) { $best = $ver }
                }
            }
            catch {}
        }
    }
    return $best
}

function Get-RunningPortableProcesses([string]$BaseRoot) {
    $prefix = ([IO.Path]::GetFullPath($BaseRoot)).TrimEnd('\') + '\'
    $found = New-Object Collections.Generic.List[object]
    $seen = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($p in (Get-Process -Name 'Code' -ErrorAction SilentlyContinue)) {
        try {
            $pPath = $p.Path
            if ($pPath -and ([IO.Path]::GetFullPath($pPath)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                if ($seen.Add($p.Id)) { $found.Add([pscustomobject]@{ Id = $p.Id; Path = $pPath }) }
            }
        }
        catch {}
    }
    if ($found.Count -eq 0) {
        try {
            foreach ($cp in (Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Code.exe'" -ErrorAction SilentlyContinue)) {
                if ($cp.ExecutablePath -and ([IO.Path]::GetFullPath($cp.ExecutablePath)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    if ($seen.Add([int]$cp.ProcessId)) {
                        $found.Add([pscustomobject]@{ Id = [int]$cp.ProcessId; Path = $cp.ExecutablePath })
                    }
                }
            }
        }
        catch {}
    }
    return $found.ToArray()
}

function Wait-PortableCodeClosed([bool]$Required) {
    while ($true) {
        $running = @(Get-RunningPortableProcesses $root)
        if ($running.Count -eq 0) { return $true }
        Write-Host "[注意] ポータブル版 VSCode が現在起動中です ($($running.Count) プロセス稼働中)" -ForegroundColor Yellow
        if ($Required) {
            $ans = Read-Host 'すべてのポータブル版 VSCode ウィンドウを閉じてから Enter を押してください [N=中止]'
            if ($ans -ieq 'n') { return $false }
        }
        else {
            $ans = Read-Host '閉じて再確認は Enter / 起動したまま続行は C / 中止は N'
            if ($ans -ieq 'n') { return $false }
            if ($ans -ieq 'c') { return $true }
        }
    }
}
