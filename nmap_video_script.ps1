#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    nmap demo lab on Hyper-V: nmap1..nmap4  (Secure Boot always OFF)
    Actions: Create | Checkpoint | Export | Reset | Start | Stop | Status

.NOTES
    ISO: newest ubuntu-26.04*.iso in D:\isos (prefers a live-server ISO). Override with -IsoPath.
    Recommended order:
      1. Create  -> install Ubuntu on each VM, set hostnames, install tools (checklist printed)
      2. Stop
      3. Checkpoint -CheckpointName "01-os-installed"   (VMs off, optional)
      4. start VMs, install tools, Stop
      5. Checkpoint -CheckpointName "02-tools-ready"    (VMs off)
      6. Export                                         (full backup, VMs powered off)
      7. Start, get demo-ready
      8. Checkpoint -CheckpointName "03-demo-ready"     (VMs running, captures memory)
      9. Record. Between takes: Reset -CheckpointName "03-demo-ready"
     10. .\nmap-teardown.ps1
#>
[CmdletBinding()]
param(
    # What to do to the whole set of lab VMs (nmap1..nmap4). Required.
    [Parameter(Mandatory)]
    [ValidateSet('Create','Checkpoint','Export','Reset','Start','Stop','Status')]
    [string]$Action,

    [string]$CheckpointName,                           # required for Checkpoint and Reset
    [string]$IsoFolder  = 'D:\isos',                   # folder searched for the Ubuntu ISO
    [string]$IsoPattern = 'ubuntu-26.04*.iso',         # wildcard filter for ISO file names
    [string]$IsoPath,                                  # optional explicit ISO; skips auto-discovery
    [string]$SwitchName = 'Default Switch',            # gives you <host>.mshome.net DNS
    [string]$VmRoot     = 'C:\HyperV\nmap',            # VM config + VHDX files live under here, one folder per VM
    [string]$ExportRoot = 'C:\HyperV\Exports\nmap'     # Export action writes full VM backups here
)

$ErrorActionPreference = 'Stop'   # make any failing cmdlet terminate the script instead of continuing silently
$Prefix = 'nmap'
# VM name -> role description. [ordered] keeps the VMs processed in nmap1..nmap4 order.
$Roles  = [ordered]@{
    "${Prefix}1" = 'scanner (run nmap here)'
    "${Prefix}2" = 'main target (nginx + ssh)'
    "${Prefix}3" = 'extra host (dnsmasq, open UDP 53)'
    "${Prefix}4" = 'extra host (ufw firewall, filtered ports)'
}
$Names = @($Roles.Keys)   # plain list of VM names used by every action below

# Returns the full path of the ISO to install from.
function Get-DemoIso {
    # An explicit -IsoPath always wins over auto-discovery.
    if ($IsoPath) {
        if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
        return $IsoPath
    }
    # Sort: live-server ISOs first, then newest file first, so $found[0] is the best candidate.
    $found = @(Get-ChildItem -Path $IsoFolder -Filter $IsoPattern -File -ErrorAction SilentlyContinue |
        Sort-Object -Property @{Expression={$_.Name -like '*live-server*'};Descending=$true},
                              @{Expression={$_.LastWriteTime};Descending=$true})
    if (-not $found) { throw "No '$IsoPattern' found in $IsoFolder. Files there: $((Get-ChildItem $IsoFolder -Filter *.iso -ErrorAction SilentlyContinue).Name -join ', ')" }
    $found[0].FullName
}

# Shuts a VM down cleanly, waits up to 90s, and falls back to a hard power-off if it hangs.
function Stop-DemoVm([string]$Name) {
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') { return }   # already off, nothing to do
    Stop-VM -Name $Name -Force -ErrorAction SilentlyContinue       # graceful shutdown via integration services
    $deadline = (Get-Date).AddSeconds(90)   # poll every 3s until Off or timeout
    while ((Get-VM -Name $Name).State -ne 'Off' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    if ((Get-VM -Name $Name).State -ne 'Off') {
        Write-Warning "$Name did not shut down gracefully; turning it off."
        Stop-VM -Name $Name -TurnOff -Force
    }
}

# Main dispatcher: runs the block matching -Action.
switch ($Action) {

    # Build all four VMs from scratch and boot them from the Ubuntu ISO.
    'Create' {
        $iso = Get-DemoIso
        Write-Host "Using ISO: $iso" -ForegroundColor Cyan
        # Fail early if the network switch is missing, before creating anything.
        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { throw "Virtual switch '$SwitchName' not found." }

        foreach ($Name in $Names) {
            # Idempotent: leave existing VMs untouched so re-running Create is safe.
            if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Write-Warning "$Name already exists - skipping."; continue }
            $dir = Join-Path $VmRoot $Name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            # Gen 2 VM, 2 GB RAM, new 25 GB dynamic VHDX, attached to the chosen switch.
            New-VM -Name $Name -Generation 2 -MemoryStartupBytes 2GB `
                   -NewVHDPath (Join-Path $dir "$Name.vhdx") -NewVHDSizeBytes 25GB `
                   -Path $VmRoot -SwitchName $SwitchName | Out-Null

            # No auto checkpoints; Standard checkpoints (include memory state); keep snapshot files with the VM;
            # don't auto-start with the host; shut down gracefully when the host shuts down.
            Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard `
                   -SnapshotFileLocation $dir -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
            Set-VMProcessor -VMName $Name -Count 2
            Set-VMFirmware  -VMName $Name -EnableSecureBoot Off        # Secure Boot is always disabled on lab VMs
            # Verify the setting actually took effect rather than trusting the previous command.
            if ((Get-VMFirmware -VMName $Name).SecureBoot -ne 'Off') { throw "Secure Boot is still enabled on $Name" }
            # Lets the host copy files into the guest (Copy-VMFile).
            Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'

            # Attach the installer ISO and make the DVD drive the first boot device.
            Add-VMDvdDrive -VMName $Name -Path $iso
            Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMDvdDrive -VMName $Name)
            Start-VM -Name $Name
            Write-Host "Created and started $Name (Secure Boot off) - $($Roles[$Name])" -ForegroundColor Green
        }

        # Manual follow-up: the OS install and package setup happen inside the guests, not via this script.
        Write-Host "`nNEXT: connect to each VM (vmconnect localhost <name>) and install Ubuntu, then on each guest run:" -ForegroundColor Cyan
        foreach ($n in $Names) { Write-Host "  $n : sudo hostnamectl set-hostname $n" }
        Write-Host @"

  nmap1 : sudo apt update && sudo apt install -y nmap
  nmap2 : sudo apt update && sudo apt install -y nginx openssh-server
  nmap3 : sudo apt update && sudo apt install -y dnsmasq openssh-server
  nmap4 : sudo apt update && sudo apt install -y ufw openssh-server
          then: sudo ufw default deny incoming && sudo ufw allow 22/tcp && sudo ufw --force enable

  Then verify DNS from the host:  .\nmap-lab.ps1 -Action Status   (nmap1.mshome.net ... nmap4.mshome.net)
"@
    }

    # Take a named checkpoint on every VM (do it while all are in the same state, all off or all running).
    'Checkpoint' {
        if (-not $CheckpointName) { throw 'Use -CheckpointName "<name>"' }
        foreach ($Name in $Names) {
            Checkpoint-VM -Name $Name -SnapshotName $CheckpointName
            Write-Host "Checkpoint '$CheckpointName' created on $Name" -ForegroundColor Green
        }
    }

    # Full portable backup of every VM (config + disks + checkpoints) to $ExportRoot.
    'Export' {
        New-Item -ItemType Directory -Path $ExportRoot -Force | Out-Null
        foreach ($Name in $Names) { Stop-DemoVm $Name }       # export from a clean, powered-off state
        foreach ($Name in $Names) {
            $target = Join-Path $ExportRoot $Name
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }   # replace older export
            Export-VM -Name $Name -Path $ExportRoot
            Write-Host "Exported $Name -> $target" -ForegroundColor Green
        }
        Write-Host "`nTo restore from an export later: Import-VM -Path '$ExportRoot\<name>\<name>\Virtual Machines\<guid>.vmcx' -Copy -GenerateNewId" -ForegroundColor Cyan
        Write-Host "(or use Hyper-V Manager > Import Virtual Machine)"
    }

    # Roll every VM back to a checkpoint (used between recording takes) and make sure it is running.
    'Reset' {
        if (-not $CheckpointName) { throw 'Use -CheckpointName "<name>"' }
        foreach ($Name in $Names) {
            Restore-VMCheckpoint -VMName $Name -Name $CheckpointName -Confirm:$false   # no prompt
            # A checkpoint taken while off restores to Off, so start it; a running one restores to Running.
            if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
            Write-Host "$Name restored to '$CheckpointName'" -ForegroundColor Green
        }
    }

    # Power on / gracefully power off all lab VMs.
    'Start' { foreach ($Name in $Names) { if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name } } }
    'Stop'  { foreach ($Name in $Names) { Stop-DemoVm $Name } }

    # Summary table, then per-VM IPv4 address, DNS resolution check, and checkpoint list.
    'Status' {
        Get-VM -Name $Names | Format-Table Name, State, CPUUsage, @{n='MemoryGB';e={[math]::Round($_.MemoryAssigned/1GB,1)}}, Uptime -AutoSize
        foreach ($Name in $Names) {
            $snaps = Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue
            # Keep only IPv4 addresses (adapters also report IPv6).
            $ips   =(Get-VMNetworkAdapter -VMName $Name).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
            # Confirms the Default Switch's mshome.net DNS can resolve the guest's hostname.
            $dns   = try { (Resolve-DnsName "$Name.mshome.net" -Type A -ErrorAction Stop).IPAddress -join ',' } catch { 'not resolving' }
            Write-Host ("{0,-9} IP: {1,-16} DNS({0}.mshome.net): {2,-16} Checkpoints: {3}" -f $Name, ($ips -join ','), $dns, (($snaps.Name) -join ', '))
        }
    }
}
