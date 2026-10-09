param([switch]$StartAtLogin)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) { throw '64-bit Windows 10 22H2 or Windows 11 is required.' }
if ([Environment]::OSVersion.Version.Build -lt 19045) { throw 'Windows 10 22H2 or Windows 11 is required.' }
$source = $PSScriptRoot
if (-not (Test-Path (Join-Path $source 'BoringNotch.exe'))) {
    $source = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts/electron/BoringNotch-win32-x64'
}
if (-not (Test-Path (Join-Path $source 'BoringNotch.exe'))) { throw 'Build first with windows/Scripts/Build.ps1 or extract the complete Windows ZIP.' }
$destination = Join-Path $env:LOCALAPPDATA 'Programs/BoringNotch'
$exe = Join-Path $destination 'BoringNotch.exe'
# Only stop a previous copy installed in our own application directory.
$installedHelper = Join-Path $destination 'resources/native/BoringWindowsHelper.exe'
$ownedProcesses = Get-Process BoringNotch,BoringWindowsHelper -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -or $_.Path -eq $installedHelper }
foreach ($ownedProcess in $ownedProcesses) {
    Stop-Process -InputObject $ownedProcess -ErrorAction SilentlyContinue
    if (-not $ownedProcess.WaitForExit(5000)) { throw 'The previous installed copy is still closing. Run setup again after it exits.' }
}
New-Item $destination -ItemType Directory -Force | Out-Null
if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) { Copy-Item (Join-Path $source '*') $destination -Recurse -Force }
$hostExe = Join-Path $destination 'resources/native/BoringWindowsHelper.exe'
if (-not (Test-Path $hostExe)) { throw 'The Windows native helper is missing. Extract the complete ZIP.' }
$manifest = Join-Path $destination 'com.boringnotch.local.octave.json'
$manifestJson = @{ name='com.boringnotch.local.octave'; description='Boring Notch Octave Windows bridge'; path=$hostExe; type='stdio'; allowed_origins=@('chrome-extension://ckcfhbbgdlpnbcbdgjmcaophnkhnlkae/') } | ConvertTo-Json
[IO.File]::WriteAllText($manifest, $manifestJson, [Text.UTF8Encoding]::new($false))
foreach ($browser in @('BraveSoftware/Brave-Browser','Google/Chrome','Microsoft/Edge')) {
    $key = 'HKCU:\Software\' + $browser.Replace('/','\') + '\NativeMessagingHosts\com.boringnotch.local.octave'
    New-Item $key -Force | Out-Null
    Set-Item $key $manifest
}
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Boring Notch Octave.lnk'))
$shortcut.TargetPath = $exe; $shortcut.WorkingDirectory = $destination; $shortcut.Save()
$uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BoringNotch'
New-Item $uninstall -Force | Out-Null
$properties = @{
    DisplayName = 'Boring Notch Octave'; DisplayVersion = '1.0.0'; Publisher = 'Vedanth Jadhav / TheBoredTeam'
    InstallLocation = $destination; DisplayIcon = $exe
    UninstallString = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $destination 'Uninstall.ps1') + '"')
}
foreach ($property in $properties.GetEnumerator()) { New-ItemProperty $uninstall -Name $property.Key -Value $property.Value -PropertyType String -Force | Out-Null }
New-ItemProperty $uninstall -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty $uninstall -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
if ($StartAtLogin) {
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item $run -Force | Out-Null
    New-ItemProperty $run -Name BoringNotch -Value ('"'+$exe+'" --background') -PropertyType String -Force | Out-Null
}
if ($StartAtLogin) { Start-Process $exe -ArgumentList '--enable-startup' } else { Start-Process $exe }
Write-Host "Installed to $destination without administrator privileges."
Write-Host "For Octave: load $destination\octave-brave-extension in Brave's extensions page (Developer mode)."
