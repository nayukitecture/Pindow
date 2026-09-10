# Redeploy script for PinWindow.ahk.
# Run this after editing PinWindow.ahk in this folder (Google Drive).
# It compiles the script into a standalone exe (with a Per-Monitor-V2 DPI
# manifest baked in, required for correct behavior across monitors with
# different DPI scaling), deploys it to local disk, and restarts it.
# The local exe is always the one actually executed.

$ErrorActionPreference = "Stop"

$SourceScript   = Join-Path $PSScriptRoot "PinWindow.ahk"
$ManifestFile   = Join-Path $PSScriptRoot "PinWindow.manifest"
$ProdDir        = Join-Path $env:LOCALAPPDATA "PinWindow"
$ProdExe        = Join-Path $ProdDir "PinWindow.exe"
$Ahk2Exe        = Join-Path $env:LOCALAPPDATA "Programs\AutoHotkey\Compiler\Ahk2Exe.exe"
$Base           = Join-Path $env:LOCALAPPDATA "Programs\AutoHotkey\v2\AutoHotkey64.exe"

if (-not (Test-Path $SourceScript)) { throw "Source script not found: $SourceScript" }
if (-not (Test-Path $ManifestFile)) { throw "Manifest not found: $ManifestFile" }
if (-not (Test-Path $Ahk2Exe))      { throw "Ahk2Exe.exe not found: $Ahk2Exe" }
if (-not (Test-Path $Base))         { throw "AutoHotkey64.exe not found: $Base" }

New-Item -ItemType Directory -Force -Path $ProdDir | Out-Null

# Stop any running instance before overwriting the exe (a running exe's file is locked).
Get-Process -Name "PinWindow" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

$compileArgs = @('/in', "`"$SourceScript`"", '/out', "`"$ProdExe`"", '/base', "`"$Base`"", '/silent', 'verbose')
$p = Start-Process -FilePath $Ahk2Exe -ArgumentList $compileArgs -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0) { throw "Ahk2Exe compile failed with exit code $($p.ExitCode)" }
if (-not (Test-Path $ProdExe)) { throw "Compile reported success but output exe is missing: $ProdExe" }

# Bake the Per-Monitor-V2 DPI manifest into the compiled exe, replacing the default one.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PinWindowResUpdater {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);
}
"@ -ErrorAction SilentlyContinue

$manifestBytes = [System.IO.File]::ReadAllBytes($ManifestFile)
$RT_MANIFEST = [IntPtr]24
$MANIFEST_ID = [IntPtr]1
$h = [PinWindowResUpdater]::BeginUpdateResource($ProdExe, $false)
if ($h -eq [IntPtr]::Zero) { throw "BeginUpdateResource failed" }
if (-not [PinWindowResUpdater]::UpdateResource($h, $RT_MANIFEST, $MANIFEST_ID, 0, $manifestBytes, $manifestBytes.Length)) { throw "UpdateResource failed" }
if (-not [PinWindowResUpdater]::EndUpdateResource($h, $false)) { throw "EndUpdateResource failed" }

Start-Process -FilePath $ProdExe

Write-Output "Compiled and deployed to: $ProdExe"
Write-Output "PinWindow restarted."
