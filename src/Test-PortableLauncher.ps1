# Run with Windows PowerShell 5.1; no external test framework required.
$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
foreach ($name in @('Common-Helpers.ps1', 'Install-PortableEnvironment.ps1', 'Set-PortableJapanese.ps1', 'Install-PortableGit.ps1')) {
    . (Join-Path $sourceRoot $name)
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('portable-tests-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $sandbox 'data'
$root = $sandbox
$code = Join-Path $root 'Code.exe'
try {
    $extension = Join-Path $data 'extensions\ms-ceintl.vscode-language-pack-ja-1.0.0'
    [void][IO.Directory]::CreateDirectory((Join-Path $extension 'translations'))
    [IO.File]::WriteAllText((Join-Path $extension 'translations\main.i18n.json'), '{}')
    Write-PortableJson (Join-Path $extension 'package.json') @{
        name = 'vscode-language-pack-ja'; publisher = 'MS-CEINTL'; version = '1.0.0'
        __metadata = @{ id = 'test-uuid' }
        contributes = @{ localizations = @(@{ languageId = 'ja'; localizedLanguageName = 'Japanese'; translations = @(@{ id = 'vscode'; path = './translations/main.i18n.json' }) }) }
    }
    function Get-InstalledExtensionVersion { return '1.0.0' }
    Set-PortableJapanese
    $cachePath = Join-Path $data 'user-data\languagepacks.json'
    $cache = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
    Assert ($cache.ja.translations.vscode -eq (Join-Path $extension 'translations\main.i18n.json')) 'Fresh install: incorrect translation path'
    Assert ($cache.ja.extensions[0].extensionIdentifier.uuid -eq 'test-uuid') 'UUID lost'
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $expected = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes('test-uuid1.0.0')))).Replace('-', '').ToLowerInvariant() }
    finally { $md5.Dispose() }
    Assert ($cache.ja.hash -eq $expected) 'Incorrect VS Code cache hash'
    Set-PortableProperty $cache 'fr' ([pscustomobject]@{ label = 'Keep me' })
    $cache.ja.translations.vscode = 'Z:\old-drive\main.i18n.json'
    Write-PortableJson $cachePath $cache
    Set-PortableJapanese
    $cache = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
    Assert ($cache.fr.label -eq 'Keep me') 'Other language was overwritten'
    Assert (Test-Path -LiteralPath $cache.ja.translations.vscode) 'Drive relocation was not repaired'
    $before = [IO.File]::ReadAllText($cachePath)
    Set-PortableJapanese
    Assert ([IO.File]::ReadAllText($cachePath) -ceq $before) 'Cache preparation is not idempotent'
    Write-Host '[PASS] Japanese cache: fresh install, hash, drive relocation, preservation, idempotency'

    # Verify the real ZIP extraction/copy/hash logic without an Internet download.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixture = Join-Path $sandbox 'git-fixture'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'cmd'))
    [IO.File]::WriteAllText((Join-Path $fixture 'cmd\git.exe'), 'fixture')
    $zip = Join-Path $sandbox 'fixture.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($fixture, $zip)
    $script:fixtureHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    function Initialize-NetworkConfig {}
    function Get-PortableCodeArchitecture { return @{ Arch = 'x64' } }
    function Invoke-RestMethod {
        return @{ assets = @(@{ name = 'MinGit-1.2.3-64-bit.zip'; digest = 'sha256:' + $script:fixtureHash; browser_download_url = 'https://fixture.invalid/git.zip' }) }
    }
    . (Join-Path $sourceRoot 'Update-VSCodeOnline.ps1')
    # Restore only the downloader mock after loading the real ZIP helper.
    function Save-UrlToFile($Url, $DestinationPath) {
        [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $DestinationPath))
        [IO.File]::Copy($zip, $DestinationPath, $true)
    }
    # Intercept native execution in this test; the live smoke test uses git.exe.
    function git.exe { $global:LASTEXITCODE = 0; return 'git version fixture' }
    $installText = (Get-Command Install-PortableGit).Definition
    $installText = $installText.Replace('& $stagedExe --version', 'git.exe --version').Replace('& $gitExe --version', 'git.exe --version')
    $install = [scriptblock]::Create($installText)
    & $install
    Assert (Test-Path -LiteralPath (Join-Path $data 'tools\git\cmd\git.exe')) 'Git was not installed'
    $info = New-Object Diagnostics.ProcessStartInfo
    $originalPath = $env:PATH
    Set-PortableGitEnvironment $info
    Assert ($info.EnvironmentVariables['PATH'].StartsWith((Join-Path $data 'tools\git\cmd') + ';')) 'Child PATH was not configured'
    Assert ($env:PATH -ceq $originalPath) 'Parent PATH was changed'
    function Invoke-RestMethod { throw 'An existing installation must not access the network' }
    & $install
    $data = Join-Path $sandbox 'bad-hash-data'
    function Invoke-RestMethod { return @{ assets = @(@{ name = 'MinGit-1.2.3-64-bit.zip'; digest = 'sha256:' + ('0' * 64); browser_download_url = 'https://fixture.invalid/git.zip' }) } }
    $rejected = $false
    try { & $install } catch { $rejected = $_.Exception.Message -like '*SHA-256*' }
    Assert $rejected 'Invalid Git hash was not rejected'
    Assert (-not (Test-Path -LiteralPath (Join-Path $data 'tools\git\cmd\git.exe'))) 'Invalid Git archive was installed'
    Write-Host '[PASS] Git: ZIP install, child-only PATH, offline reuse, SHA-256 rejection'
}
finally {
    # The target is the unique sandbox created above, never an application folder.
    if ($sandbox -and (Split-Path -Leaf $sandbox) -like 'portable-tests-*') {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}