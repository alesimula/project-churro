<# :
@echo off
rem Project Churro: update a Churro USB stick in place, keeping Android's data (setup, apps).
rem Windows side of tools/flash-keep-data.sh: installs usbipd-win if missing, lets you pick a USB
rem disk (never the system/boot disk), passes it through to WSL, checks it holds Googlebook OS
rem (tools/updater/buildinfo.sh), asks for confirmation and runs flash-keep-data.sh.
rem tools\grow-data.bat and tools\mount-partition.bat run this same part (FKD_ACTION).
rem Usage: tools\flash-keep-data.bat [image]   (no image: pick a .img / .img.gz from out\)
rem        set CHURRO_WSL=<distro> to use another WSL distro than Ubuntu.
setlocal
set "FKD_DIR=%~dp0"
set "FKD_IMG=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText('%~f0'))"
exit /b %errorlevel%
#>
# ---- PowerShell part (the batch lines above are a PowerShell comment) ----
# errors: Fail throws; the catch at the end reports it, the finally gives the stick back to Windows
function Fail($msg) { throw $msg }
function ToWsl($winPath) { (wsl.exe -d $distro -- wslpath -a ($winPath -replace '\\', '/')).Trim() }

$attached = $false; $busid = $null; $rc = 1
try {
$repo = (Resolve-Path (Join-Path $env:FKD_DIR '..')).Path
$distro = 'Ubuntu'; if ($env:CHURRO_WSL) { $distro = $env:CHURRO_WSL }
$grow = $env:FKD_ACTION -eq 'grow'   # tools\grow-data.bat: same disk picking, then grow-data.sh
$mount = $env:FKD_ACTION -eq 'mount' # tools\mount-partition.bat: same disk picking, then mount one
$mp = $null; $keep = $null
if ($grow -or $mount) { $img = $null } elseif ($env:FKD_IMG) { $img = (Resolve-Path $env:FKD_IMG).Path } else {
  # pick an image in out\ (churro.sh writes a .img, a compressed copy is .img.gz), newest first
  $imgs = @(Get-ChildItem (Join-Path $repo 'out') -File | Where-Object { $_.Name -match '\.img(\.gz)?$' } | Sort-Object LastWriteTime -Descending)
  if ($imgs.Count -eq 0) { Fail "no .img / .img.gz in $repo\out (or pass an image: flash-keep-data.bat <image>)" }
  $n = 0
  $imgs | ForEach-Object { $n++; [pscustomobject]@{ N = $n; Image = $_.Name; SizeGB = [math]::Round($_.Length / 1GB, 1); Written = $_.LastWriteTime } } |
    Format-Table -AutoSize | Out-Host
  $p = Read-Host 'Number of the image (Enter = 1, the newest)'
  if (-not $p) { $p = '1' }
  $i = 0; if (-not [int]::TryParse($p.Trim(), [ref]$i) -or $i -lt 1 -or $i -gt $imgs.Count) { Fail "no image number $p" }
  $img = $imgs[$i - 1].FullName
}
if ($img -and -not (Test-Path $img)) { Fail "image not found: $img" }

# 1. usbipd-win (a terminal opened before installing it doesn't have it on PATH yet)
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { $env:Path += ';C:\Program Files\usbipd-win' }
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
  Write-Host 'usbipd-win not found: installing it with winget...'
  winget install --exact --id dorssel.usbipd-win --accept-source-agreements --accept-package-agreements
  if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { Fail 'usbipd still not found: open a new terminal and run this again' }
}

# 2. candidate disks: USB only; never the system or boot disk, nor the one holding the Windows drive
$winDisks = @(Get-Partition | Where-Object { $_.DriveLetter -and ("$($_.DriveLetter):" -eq $env:SystemDrive) } | ForEach-Object { $_.DiskNumber })
$disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsSystem -and -not $_.IsBoot -and ($winDisks -notcontains $_.Number) })
if ($disks.Count -eq 0) { Fail 'no USB disk found: plug the Churro stick in (and detach it from WSL if it is still attached)' }

# the USB device a disk sits on (USB\VID_...), as usbipd knows it
function UsbParent($disk) {
  $id = (Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $disk.Number }).PNPDeviceID
  for ($i = 0; $i -lt 5 -and $id -and $id -notmatch '^USB\\VID_'; $i++) {
    $id = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent).Data
  }
  $id
}
$n = 0
$rows = foreach ($d in $disks) {
  $n++
  [pscustomobject]@{ N = $n; Disk = $d.Number; Name = $d.FriendlyName; SizeGB = [math]::Round($d.Size / 1GB, 1)
                     Partitions = $d.NumberOfPartitions; Bytes = $d.Size; Usb = (UsbParent $d) }
}
Write-Host "`nUSB disks (system/boot disks are never listed):"
$rows | Format-Table N, Disk, Name, SizeGB, Partitions -AutoSize | Out-Host
$pick = Read-Host 'Number of the Churro stick (Enter = cancel)'
if (-not $pick) { Fail 'cancelled' }
$row = $rows | Where-Object { "$($_.N)" -eq $pick.Trim() }
if (-not $row) { Fail "no disk number $pick" }

$dev = (usbipd state | ConvertFrom-Json).Devices | Where-Object { $_.InstanceId -eq $row.Usb }
if (-not $dev) { Fail "usbipd doesn't list the USB device of disk $($row.Disk) ($($row.Usb))" }
$busid = $dev.BusId

# 3. pass it through to WSL (binding needs admin once per device: a UAC prompt)
if (-not $dev.PersistedGuid) {
  Write-Host "Sharing USB device $busid with WSL (one-time, needs admin)..."
  Start-Process usbipd -Verb RunAs -Wait -ArgumentList "bind --busid $busid"
  $dev = (usbipd state | ConvertFrom-Json).Devices | Where-Object { $_.BusId -eq $busid }
  if (-not $dev.PersistedGuid) { Fail "usbipd bind --busid $busid failed or was cancelled" }
}
function WslUsbDisks { @(wsl.exe -d $distro -u root -- lsblk -dnbo NAME,SIZE,TRAN | ForEach-Object {
  $p = "$_".Trim() -split '\s+'; if ($p.Count -eq 3 -and $p[2] -eq 'usb') { "$($p[0]) $($p[1])" } }) }
wsl.exe -d $distro -u root -- modprobe -a usb-storage uas 2>$null
$before = WslUsbDisks
  # Windows must write its pending changes to the stick's drives (CHURRO-LOG) first: usbipd takes
  # the device away without that, and WSL then writes on a half-updated FAT (seen: a file deleted
  # in Windows just before, then a corrupted boot loader copy on CHURRO-LOG)
  Get-Partition -DiskNumber $row.Disk | Where-Object DriveLetter | ForEach-Object { Write-VolumeCache -DriveLetter $_.DriveLetter }
  usbipd attach --wsl --busid $busid
  if ($LASTEXITCODE -ne 0) { Fail "usbipd attach --busid $busid failed" }
  $attached = $true
  # the new USB disk in WSL with exactly this disk's size
  $sd = $null
  for ($t = 0; $t -lt 30 -and -not $sd; $t++) {
    Start-Sleep 1
    $sd = WslUsbDisks | Where-Object { $before -notcontains $_ -and $_ -eq ($_.Split(' ')[0] + " $($row.Bytes)") } | Select-Object -First 1
  }
  if (-not $sd) { Fail 'the stick did not show up in WSL (or with a different size)' }
  $sdev = '/dev/' + $sd.Split(' ')[0]
  Write-Host "Disk $($row.Disk) ($($row.Name)) is $sdev in WSL."

  # 4. it must hold Googlebook OS
  $wrepo = ToWsl $repo
  $info = wsl.exe -d $distro -u root -- bash "$wrepo/tools/updater/buildinfo.sh" $sdev
  if ($LASTEXITCODE -ne 0 -or -not ($info -match '^FINGERPRINT=')) { Fail "$sdev doesn't hold Googlebook OS (buildinfo.sh found no build): not touching it" }
  Write-Host "`nOn the stick now:"; $info | Where-Object { $_ -match '^(MODEL|RELEASE|BUILD_ID|INCREMENTAL|FINGERPRINT)=' } | ForEach-Object { "  $_" } | Out-Host
  if ($mount) {
    # 5. mount one partition in WSL and show it in Explorer (until Enter)
    $parts = @(
      @('EFI-SYSTEM',    'boot files: GRUB menu, env.cfg (extra kernel args), kernel (read-write)'),
      @('CHURRO-LOG',    'logs of the debug boot entries (read-write)'),
      @('system_a',      'Android system (read-only)'),
      @('system_ext_a',  'system_ext (read-only)'),
      @('product_a',     'product: Google apps, build.prop (read-only)'),
      @('vendor_a',      'vendor: HALs, init .rc files, SELinux policy, firmware (read-only)'),
      @('vendor_dlkm_a', 'vendor kernel modules (read-only)'),
      @('system_dlkm_a', 'GKI kernel modules (read-only)'),
      @('userdata',      "Android's data (read-only; most names are encrypted)"))
    $n = 0
    $parts | ForEach-Object { $n++; [pscustomobject]@{ N = $n; Partition = $_[0]; Contents = $_[1] } } | Format-Table -AutoSize | Out-Host
    $p = Read-Host 'Number of the partition (Enter = cancel)'
    if (-not $p) { Fail 'cancelled' }
    $i = 0; if (-not [int]::TryParse($p.Trim(), [ref]$i) -or $i -lt 1 -or $i -gt $parts.Count) { Fail "no partition number $p" }
    $name = $parts[$i - 1][0]
    $uid = "$(wsl.exe -d $distro -- id -u)".Trim()   # Explorer reaches WSL as the distro's default user
    # args: <disk> <partition> <uid> <repo>. stdin script: LF only, and a trailing newline so the
    # CRLF PowerShell appends lands on a line bash never reads (exit comes first)
    $sh = @'
set -eu
dev=$1 name=$2 uid=$3 repo=$4 mp=/mnt/churro/$2
part() { lsblk -lnpo PATH,PARTLABEL "$dev" | awk -v n="$1" '$2 == n {print $1; exit}'; }
mkdir -p "$mp"
if mountpoint -q "$mp"; then umount "$mp"; fi
case $name in
  EFI-SYSTEM|CHURRO-LOG)
    d=$(part "$name"); [ -n "$d" ] || { echo "no $name partition on $dev" >&2; exit 1; }
    mount -t vfat -o "uid=$uid,gid=$uid,umask=022" "$d" "$mp" ;;
  userdata)
    d=$(part userdata); [ -n "$d" ] || { echo "no userdata partition on $dev" >&2; exit 1; }
    # noload: no journal replay, nothing written (Android formats it on first start)
    mount -t ext4 -o ro,noload "$d" "$mp" || { echo "userdata didn't mount (never started: not formatted yet?)" >&2; exit 1; } ;;
  *)
    s=$(part super); [ -n "$s" ] || { echo "no super partition on $dev" >&2; exit 1; }
    read -r off size < <(python3 "$repo/lib/lpinfo.py" "$s" "$name") || { echo "no $name in super" >&2; exit 1; }
    modprobe erofs
    mount -t erofs -o "ro,loop,offset=$off,sizelimit=$size" "$s" "$mp" ;;
esac
echo "$mp"
exit 0
'@
    $mp = (($sh -replace "`r", '') + "`n") | wsl.exe -d $distro -u root -- bash -s -- $sdev $name $uid $wrepo
    if ($LASTEXITCODE -ne 0) { $mp = $null; Fail "mounting $name failed (see above)" }
    $mp = "$($mp | Select-Object -Last 1)".Trim()
    # keeps the distro running while Explorer browses (an idle distro stops and loses the mount)
    $keep = Start-Process wsl.exe -ArgumentList "-d $distro -- sleep infinity" -WindowStyle Hidden -PassThru
    $win = "\\wsl$\$distro" + ($mp -replace '/', '\')
    Write-Host "`n$name is mounted at $mp in WSL: $win"
    Start-Process explorer.exe $win
    Read-Host "`nPress Enter when done: it is unmounted and the stick goes back to Windows" | Out-Null
  } elseif ($grow) {
    # 5. grow userdata: grow-data.sh's plan first (DRY=1), then the real run
    $plan = wsl.exe -d $distro -u root -- env DRY=1 bash "$wrepo/tools/grow-data.sh" $sdev
    if ($LASTEXITCODE -ne 0) { Fail 'grow-data.sh failed (see above)' }
    Write-Host ''; $plan | Out-Host
    $gargs = @('--yes')
    if ($plan -match 'already started') {
      $ok = Read-Host "`nType ERASE to grow the partition and ERASE Android's data (it then sets itself up again with all the space)"
      if ($ok -cne 'ERASE') { Fail 'cancelled' }
      $gargs += '--erase'
    } elseif (-not ($plan -match 'nothing to do')) {
      $ok = Read-Host "`nGrow Android's data partition on this stick? Type YES"
      if ($ok -cne 'YES') { Fail 'cancelled' }
    }
    wsl.exe -d $distro -u root -- bash "$wrepo/tools/grow-data.sh" $sdev @gargs
    if ($LASTEXITCODE -ne 0) { Fail 'grow-data.sh failed (see above)' }
  } else {
  Write-Host "Image: $img"
  $ok = Read-Host "`nUpdate the stick from this image, keeping userdata? Type YES"
  if ($ok -cne 'YES') { Fail 'cancelled' }

  # 5. write (flash-keep-data.sh re-checks the partition layout and refuses on any mismatch)
  wsl.exe -d $distro -u root -- bash "$wrepo/tools/flash-keep-data.sh" (ToWsl $img) $sdev --yes
  if ($LASTEXITCODE -ne 0) { Fail 'flash-keep-data.sh failed (see above)' }
  }
  Write-Host 'Done.' -ForegroundColor Green; $rc = 0
} catch {
  Write-Host "ERROR: $_" -ForegroundColor Red
} finally {
  if ($mp) {   # lazy if Explorer still has it open; the stick goes away right after anyway
    wsl.exe -d $distro -u root -- sh -c "umount '$mp' 2>/dev/null || umount -l '$mp'; rmdir '$mp'"
    Write-Host "$mp unmounted."
  }
  if ($keep) { Stop-Process -Id $keep.Id -ErrorAction SilentlyContinue }
  if ($attached) { usbipd detach --busid $busid | Out-Null; Write-Host "USB device $busid given back to Windows." }
}
Read-Host 'Press Enter to exit' | Out-Null
exit $rc
