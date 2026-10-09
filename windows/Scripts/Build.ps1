param([ValidateSet('Debug','Release')][string]$Configuration = 'Release', [string]$ElectronZipDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    dotnet restore Boring.Native/Boring.Native.csproj --locked-mode -r win-x64
    if ($LASTEXITCODE) { throw 'Native helper restore failed' }
    dotnet publish Boring.Native/Boring.Native.csproj -f net10.0-windows10.0.19041.0 -c $Configuration -r win-x64 --self-contained true --no-restore -o artifacts/native
    if ($LASTEXITCODE) { throw 'Windows helper build failed' }
    Push-Location electron
    try {
        npm ci
        if ($LASTEXITCODE) { throw 'Electron dependency installation failed' }
        $arguments = @('--platform=win32','--arch=x64','--out=../artifacts/electron','--overwrite','--prune=true','--asar','--extra-resource=../artifacts/native','--ignore=^/tests','--ignore=^/qa-output','--ignore=^/package-lock.json','--app-version=1.0.0','--electron-version=44.7.0','--icon=assets/icon.ico')
        if ($ElectronZipDirectory) { $arguments += '--electron-zip-dir=' + $ElectronZipDirectory }
        npx --no-install electron-packager . BoringNotch @arguments
        if ($LASTEXITCODE) { throw 'Electron Windows packaging failed' }
    } finally { Pop-Location }
    $app = 'artifacts/electron/BoringNotch-win32-x64'
    New-Item "$app/octave-brave-extension" -ItemType Directory -Force | Out-Null
    Copy-Item ../octave-brave-extension/* "$app/octave-brave-extension" -Recurse -Force
    Copy-Item ../LICENSE "$app/LICENSE-BoringNotch.txt" -Force
    Copy-Item ../THIRD_PARTY_LICENSES,README.md,QA.md,THIRD_PARTY_NOTICES.md $app -Force
    Copy-Item Licenses "$app/Licenses" -Recurse -Force
    Copy-Item Scripts/Install.ps1,Scripts/Uninstall.ps1,Scripts/Setup.cmd,Scripts/Uninstall.cmd $app -Force
    Compress-Archive -Path "$app/*" -DestinationPath artifacts/Boring-Notch-Octave-Windows-x64.zip -Force
    (Get-FileHash artifacts/Boring-Notch-Octave-Windows-x64.zip -Algorithm SHA256).Hash | Set-Content artifacts/Boring-Notch-Octave-Windows-x64.zip.sha256
    Write-Host 'Built artifacts/Boring-Notch-Octave-Windows-x64.zip (Electron UI + self-contained Windows helper)'
} finally { Pop-Location }
