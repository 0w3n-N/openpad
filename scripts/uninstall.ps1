# Undo scripts\setup.ps1. Asks before removing the firewall rule or your notebook.
#   powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $env:LOCALAPPDATA 'OpenPad'

function Ask([string]$Question) {
    $reply = Read-Host "$Question [y/N]"
    return $reply -match '^[Yy]'
}

# Stop the server if it is running.
foreach ($candidate in @(@('py', '-3'), @('python'))) {
    if (Get-Command $candidate[0] -ErrorAction SilentlyContinue) {
        $pre = @($candidate | Select-Object -Skip 1)
        & $candidate[0] @pre -B (Join-Path $Root 'bin\openpad') stop 2>$null | Out-Null
        break
    }
}

$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'OpenPad.lnk'
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "Removed $lnk" }

$bin = Join-Path $Root 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -and (($userPath -split ';') -contains $bin)) {
    $newPath = (($userPath -split ';') | Where-Object { $_ -and $_ -ne $bin }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host 'Removed the openpad command from PATH.'
}

if ((Get-NetFirewallRule -Group 'OpenPad' -ErrorAction SilentlyContinue) -and
    (Ask 'Remove the OpenPad firewall rule? (Windows will ask for admin rights)')) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Remove-NetFirewallRule -Group 'OpenPad'"))
    Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
    Remove-Item (Join-Path $DataDir 'firewall') -ErrorAction SilentlyContinue
    Write-Host 'Firewall rule removed.'
}

if ((Test-Path $DataDir) -and (Ask "Delete OpenPad's data in $DataDir (synced notebooks, pairing key, certificate)? The readable PDFs in Documents\OpenPad stay.")) {
    Remove-Item -Recurse -Force $DataDir
    Write-Host "Deleted $DataDir"
}

Write-Host 'Done. Python (and cloudflared, if you installed it) were left installed. You can now delete the OpenPad folder.'
