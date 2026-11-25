# Prepare the native language-pack cache BEFORE Electron resolves its UI locale.
function Set-PortableJapanese {
    $extensionRoot = Join-Path $data 'extensions'
    $version = Get-InstalledExtensionVersion 'MS-CEINTL.vscode-language-pack-ja'
    if (-not $version) { throw '日本語パックがインストールされていません。' }
    $folder = Get-ChildItem -LiteralPath $extensionRoot -Directory -Filter 'ms-ceintl.vscode-language-pack-ja-*' |
        Where-Object {
            $manifest = Join-Path $_.FullName 'package.json'
            if (Test-Path -LiteralPath $manifest) {
                $p = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
                $p.publisher -ieq 'MS-CEINTL' -and $p.name -eq 'vscode-language-pack-ja' -and $p.version -eq $version
            }
        } | Select-Object -First 1
    if (-not $folder) { throw '日本語パックの実体が見つかりません。' }
    $package = [IO.File]::ReadAllText((Join-Path $folder.FullName 'package.json')) | ConvertFrom-Json
    $localization = $package.contributes.localizations | Where-Object languageId -eq 'ja' | Select-Object -First 1
    $translations = [ordered]@{}
    foreach ($translation in $localization.translations) {
        $path = [IO.Path]::GetFullPath((Join-Path $folder.FullName $translation.path))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "翻訳ファイルが見つかりません: $path" }
        $translations[$translation.id] = $path
    }
    if (-not $translations['vscode']) { throw 'VS Code 本体の日本語翻訳がありません。' }
    $identifier = [ordered]@{ id = 'ms-ceintl.vscode-language-pack-ja' }
    if ($package.__metadata.id) { $identifier['uuid'] = [string]$package.__metadata.id }
    $identity = if ($identifier['uuid']) { $identifier['uuid'] } else { $identifier['id'] }
    # Match VS Code's non-security cache key: MD5(identifier + version).
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity + $version)))).Replace('-', '').ToLowerInvariant() }
    finally { $md5.Dispose() }
    $cachePath = Join-Path $data 'user-data\languagepacks.json'
    $cache = if (Test-Path -LiteralPath $cachePath) { [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json } else { [pscustomobject]@{} }
    Set-PortableProperty $cache 'ja' ([ordered]@{
        hash = $hash; label = $localization.localizedLanguageName
        extensions = @(@{ extensionIdentifier = $identifier; version = $version })
        translations = $translations
    })
    Write-PortableJson $cachePath $cache
}