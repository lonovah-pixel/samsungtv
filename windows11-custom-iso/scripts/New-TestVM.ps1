<#
.SYNOPSIS
  Creates an isolated Hyper-V test VM (Generation 2: UEFI, Secure Boot, vTPM) that
  boots the built ISO. The VM uses a NEW virtual disk (VHDX) only - no physical disks.
.DESCRIPTION
  Run in an elevated Windows PowerShell on a host with Hyper-V enabled.
  The Windows installation inside the VM is done interactively (disk selection is
  intentionally not automated). Afterwards run scripts\Test-Deployment.ps1 inside the VM.
.EXAMPLE
  .\scripts\New-TestVM.ps1 -IsoPath .\output\Windows11-Pro-RU-Custom.iso -Start
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [string]$VMName = 'W11-Custom-ISO-Test',
    [string]$VMRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'work\vm'),
    [int]$MemoryGB = 8,
    [int]$ProcessorCount = 4,
    [int]$DiskGB = 96,
    [string]$SwitchName = '',
    [switch]$Start
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell module not available (enable Hyper-V and its management tools).' }
$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { throw "VM '$VMName' already exists; remove it or choose another -VMName." }
New-Item -ItemType Directory -Path $VMRoot -Force | Out-Null
$vhd = Join-Path $VMRoot "$VMName.vhdx"
if (Test-Path -LiteralPath $vhd) { throw "Disk $vhd already exists." }

$params = @{ Name = $VMName; Generation = 2; MemoryStartupBytes = ([int64]$MemoryGB * 1GB); NewVHDPath = $vhd; NewVHDSizeBytes = ([int64]$DiskGB * 1GB); Path = $VMRoot }
if ($SwitchName) { $params['SwitchName'] = $SwitchName }
$vm = New-VM @params
Set-VMProcessor -VMName $VMName -Count $ProcessorCount
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
Enable-VMTPM -VMName $VMName
$dvd = Add-VMDvdDrive -VMName $VMName -Path $IsoPath -Passthru
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd
Set-VM -VMName $VMName -CheckpointType Disabled -AutomaticCheckpointsEnabled $false

$fw = Get-VMFirmware -VMName $VMName
$sec = Get-VMSecurity -VMName $VMName
Write-Host ("VM {0}: Gen2, SecureBoot={1} ({2}), TPM={3}, RAM={4} GB, vCPU={5}, disk={6}" -f $VMName, $fw.SecureBoot, $fw.SecureBootTemplate, $sec.TpmEnabled, $MemoryGB, $ProcessorCount, $vhd)
if (-not $SwitchName) { Write-Host 'No virtual switch attached: the VM is offline (good for testing offline app install; attach a switch to test Windows Update).' -ForegroundColor Yellow }
if ($Start) { Start-VM -Name $VMName; Write-Host 'VM started. Connect with: vmconnect.exe localhost' $VMName ' (press a key to boot from DVD).' }
