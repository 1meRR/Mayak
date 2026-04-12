param(
  [string]$ProjectDir = "D:\VSCODE\Mayak-main\apps\client",
  [string]$DeviceId = "emulator-5554",
  [int]$RunTimeoutSec = 180
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outDir = Join-Path $ProjectDir ("diag_" + $timestamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Ensure adb in PATH for this session
$adbPath = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools"
if (Test-Path $adbPath) {
  $env:Path += ";$adbPath"
}

function Run-Cmd([string]$cmd, [string]$outfile) {
  Write-Host ">>> $cmd"
  cmd /c $cmd 2>&1 | Tee-Object -FilePath $outfile
}

Set-Location $ProjectDir

# Basic environment snapshots
Run-Cmd "flutter --version"                       (Join-Path $outDir "01_flutter_version.txt")
Run-Cmd "flutter doctor -v"                      (Join-Path $outDir "02_flutter_doctor.txt")
Run-Cmd "flutter devices"                        (Join-Path $outDir "03_flutter_devices.txt")
Run-Cmd "adb version"                            (Join-Path $outDir "04_adb_version.txt")
Run-Cmd "adb devices -l"                         (Join-Path $outDir "05_adb_devices.txt")
Run-Cmd "adb -s $DeviceId shell getprop"         (Join-Path $outDir "06_device_getprop.txt")

# Clean previous logs and app state
Run-Cmd "adb -s $DeviceId logcat -c"             (Join-Path $outDir "07_logcat_clear.txt")
Run-Cmd "adb -s $DeviceId shell am force-stop com.example.decentra_call_client" (Join-Path $outDir "08_force_stop.txt")

# Start logcat capture in background
$logcatFile = Join-Path $outDir "09_logcat_live.txt"
$logcatProc = Start-Process -FilePath "adb" `
  -ArgumentList "-s $DeviceId logcat -v threadtime *:V" `
  -RedirectStandardOutput $logcatFile `
  -RedirectStandardError (Join-Path $outDir "09_logcat_live_err.txt") `
  -NoNewWindow -PassThru

Start-Sleep -Seconds 2

# Run flutter with verbose logs in background
$flutterOut = Join-Path $outDir "10_flutter_run_verbose.txt"
$flutterProc = Start-Process -FilePath "flutter" `
  -ArgumentList "run -d $DeviceId --no-dds -v" `
  -RedirectStandardOutput $flutterOut `
  -RedirectStandardError (Join-Path $outDir "10_flutter_run_verbose_err.txt") `
  -NoNewWindow -PassThru

# Wait timeout
$elapsed = 0
while (-not $flutterProc.HasExited -and $elapsed -lt $RunTimeoutSec) {
  Start-Sleep -Seconds 2
  $elapsed += 2
}

if (-not $flutterProc.HasExited) {
  Write-Host ">>> Timeout reached, stopping flutter run..."
  try { $flutterProc.Kill() } catch {}
}

# Additional diagnostics after run
Run-Cmd "adb -s $DeviceId shell pidof com.example.decentra_call_client" (Join-Path $outDir "11_pidof.txt")
Run-Cmd "adb -s $DeviceId shell dumpsys activity top"                    (Join-Path $outDir "12_dumpsys_activity_top.txt")
Run-Cmd "adb -s $DeviceId shell dumpsys meminfo com.example.decentra_call_client" (Join-Path $outDir "13_meminfo.txt")
Run-Cmd "adb -s $DeviceId shell ls -la /data/tombstones"                (Join-Path $outDir "14_tombstones_list.txt")

# Try pull tombstones (may fail on non-root emulator/permissions)
Run-Cmd "adb -s $DeviceId pull /data/tombstones `"$outDir\tombstones`"" (Join-Path $outDir "15_tombstones_pull.txt")

# Stop logcat
try { if (-not $logcatProc.HasExited) { $logcatProc.Kill() } } catch {}

Write-Host ""
Write-Host "DONE. Diagnostics saved to:"
Write-Host $outDir