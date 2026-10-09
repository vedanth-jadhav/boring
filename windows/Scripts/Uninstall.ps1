# Personal settings and shelf files are retained at %LOCALAPPDATA%\BoringNotch.
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:LOCALAPPDATA 'Programs/BoringNotch'
$exe = Join-Path $destination 'BoringNotch.exe'
$installedHelper = Join-Path $destination 'resources/native/BoringWindowsHelper.exe'
$ownedProcesses = Get-Process BoringNotch,BoringWindowsHelper -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -or $_.Path -eq $installedHelper }
foreach ($ownedProcess in $ownedProcesses) {
    Stop-Process -InputObject $ownedProcess -ErrorAction SilentlyContinue
    if (-not $ownedProcess.WaitForExit(5000)) { throw 'The previous installed copy is still closing. Run setup again after it exits.' }
}
foreach ($browser in @('BraveSoftware/Brave-Browser','Google/Chrome','Microsoft/Edge')) {
    $key = 'HKCU:\Software\' + $browser.Replace('/','\') + '\NativeMessagingHosts\com.boringnotch.local.octave'
    if (Test-Path $key) {
        if ((Get-Item $key).GetValue('') -eq (Join-Path $destination 'com.boringnotch.local.octave.json')) { Remove-Item $key }
    }
}
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ((Get-ItemProperty $run -Name BoringNotch -ErrorAction SilentlyContinue).BoringNotch -like ('"' + $exe + '"*')) { Remove-ItemProperty $run -Name BoringNotch -ErrorAction SilentlyContinue }
$uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BoringNotch'
if ((Get-ItemProperty $uninstall -ErrorAction SilentlyContinue).InstallLocation -eq $destination) { Remove-Item $uninstall -Recurse }

Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Boring Notch Octave.lnk') -ErrorAction SilentlyContinue
if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
Write-Host 'Uninstalled. Your settings and shelf copies were retained.'
