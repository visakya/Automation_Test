# Usage: .\run-trip-flow.ps1                  full run: book, accept, drive, finish
#        .\run-trip-flow.ps1 -ResumeAtPickup  continue a trip waiting at the pickup
param([switch]$ResumeAtPickup)

$ErrorActionPreference = "Stop"

$driverDevice = "9b01005930533036340013b959553c"
$passengerDevice = "R9RYA03Y3WP"
$driverPackage = "com.miwayz.driversapp.qa"
$passengerPackage = "com.miwayz.customer_app.qa"
$projectPath = "C:\Users\KasuniPiyumanthi\Desktop\Automation_Test"

# The passenger's pickup and drop-off are set in passenger_book_trip.yaml;
# only the driver phone's location is simulated.
$driveSpeedKmh = 120
# Where the driver waits for the ride request (Majestic City, Bambalapitiya).
# Set $driverStartName to "" to use the driver phone's real position instead.
$driverStartName = "Majestic City, Bambalapitiya"
$driverStartLat = 6.8939786
$driverStartLng = 79.8546803
# Real position of the driver phone, used to reset it after the run.
# Read from the driver app at start-up; these values are only a fallback.
$homeLat = 6.8814
$homeLng = 79.8572

$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
    [Environment]::GetEnvironmentVariable("Path", "User")
$javaHome = (Get-ChildItem "$env:LOCALAPPDATA\Temurin17" -Directory |
    Select-Object -First 1).FullName
$env:JAVA_HOME = $javaHome
$env:Path = "$javaHome\bin;$env:LOCALAPPDATA\Maestro\maestro\bin;$env:Path"

Set-Location $projectPath
. "$projectPath\mock-location.ps1"

# Every run gets its own log folder: run.log (these step lines) plus one log
# per Maestro flow.
$logDir = Join-Path $projectPath ("logs\" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
New-Item -ItemType Directory -Force $logDir | Out-Null
Start-Transcript -Path "$logDir\run.log" | Out-Null

$script:steps = New-Object System.Collections.ArrayList

# Runs one named step, printing START and PASS/FAIL with its duration, and
# records the result for the summary. Steps set shared values with $script:.
function Invoke-Step([string]$name, [scriptblock]$action) {
    Write-Host ""
    Write-Host ("[{0:HH:mm:ss}] START  {1}" -f (Get-Date), $name) -ForegroundColor Cyan
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = & $action
        $seconds = [int]$clock.Elapsed.TotalSeconds
        [void]$script:steps.Add([pscustomobject]@{ Step = $name; Result = "PASS"; Seconds = $seconds })
        Write-Host ("[{0:HH:mm:ss}] PASS   {1} ({2}s)" -f (Get-Date), $name, $seconds) -ForegroundColor Green
    }
    catch {
        $seconds = [int]$clock.Elapsed.TotalSeconds
        [void]$script:steps.Add([pscustomobject]@{ Step = $name; Result = "FAIL"; Seconds = $seconds })
        Write-Host ("[{0:HH:mm:ss}] FAIL   {1} ({2}s): {3}" -f (Get-Date), $name, $seconds, $_.Exception.Message) -ForegroundColor Red
        throw
    }
}

function Write-Info([string]$message) {
    Write-Host ("           {0}" -f $message)
}

# Runs a Maestro flow in a separate process and returns the process handle.
# Each Maestro step is printed live with a [driver]/[passenger] tag and saved
# to the run's log folder. Extra arguments (e.g. "-e NAME=value") go before
# the flow file, because Maestro only sees variables passed with -e.
function Start-MaestroFlow([string]$device, [string]$flow, [string]$tag, [string]$extraArgs = "") {
    $logFile = Join-Path $logDir ("{0}-{1}.log" -f $tag, [IO.Path]::GetFileNameWithoutExtension($flow))
    $command = @"
Set-Location '$projectPath'
`$env:JAVA_HOME = '$javaHome'
`$env:Path = '$javaHome\bin;$env:LOCALAPPDATA\Maestro\maestro\bin;' + [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
maestro.bat --device $device test $extraArgs $flow 2>&1 |
    ForEach-Object { "`$_" } |
    Where-Object { `$_ -notmatch 'Failed to record heartbeat|^\s+at |IOException: The process cannot access|^\s*`$' } |
    Tee-Object -FilePath '$logFile' |
    ForEach-Object { '  [$tag] ' + `$_ }
exit `$LASTEXITCODE
"@
    $process = Start-Process powershell.exe -ArgumentList "-NoProfile", "-Command", $command -NoNewWindow -PassThru
    # Reading the handle now keeps ExitCode available after the process exits
    # (otherwise Windows PowerShell 5.1 reports it as empty).
    $null = $process.Handle
    return $process
}

function Wait-MaestroFlow($process, [string]$description) {
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "$description failed (Maestro exit code $($process.ExitCode)); see $logDir"
    }
}

# Drives the driver phone along a road route in a separate process, printing
# [gps] progress lines live. The process keeps the phone parked at the end of
# the route until it is stopped.
function Start-DriveProcess([string]$name, [string]$routeJson) {
    $routeFile = Join-Path $logDir "$name.json"
    Set-Content -Path $routeFile -Value $routeJson -Encoding UTF8
    $command = ". '$projectPath\mock-location.ps1'; " +
        "Invoke-RouteDrive '$driverDevice' (Get-Content -Raw '$routeFile') $driveSpeedKmh -HoldAtEnd"
    return Start-Process powershell.exe -ArgumentList "-NoProfile", "-Command", $command -NoNewWindow -PassThru
}

# Keeps the driver phone parked at one position in a separate process until
# it is stopped.
function Start-HoldProcess([double]$lat, [double]$lng) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $command = ". '$projectPath\mock-location.ps1'; " +
        "Hold-MockLocation '$driverDevice' $($lat.ToString($inv)) $($lng.ToString($inv))"
    return Start-Process powershell.exe -ArgumentList "-NoProfile", "-Command", $command -NoNewWindow -PassThru
}

# Stops a Maestro run that is still going (e.g. after another step failed),
# including the Maestro/Java processes it started.
function Stop-MaestroFlow($process) {
    if ($process -and -not $process.HasExited) {
        taskkill /T /F /PID $process.Id 2>$null | Out-Null
    }
}

function Stop-DriveProcess($process) {
    if ($process -and -not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }
}

$script:driveProcess = $null
$failed = $false

try {
    Invoke-Step "Check both phones are connected" {
        $deviceLines = @(adb devices | Select-Object -Skip 1)
        foreach ($device in $driverDevice, $passengerDevice) {
            $ready = $deviceLines | Where-Object { $_ -match ("^{0}\s+device$" -f [regex]::Escape($device)) }
            if (-not $ready) { throw "Phone $device is not connected or not authorised." }
        }
        Write-Info "driver $driverDevice, passenger $passengerDevice"
    }

    if (-not $ResumeAtPickup) {
        Invoke-Step "Restart both apps" {
            adb -s $driverDevice shell am force-stop $driverPackage | Out-Null
            adb -s $passengerDevice shell am force-stop $passengerPackage | Out-Null
            adb -s $driverDevice logcat -c | Out-Null
            adb -s $driverDevice shell monkey -p $driverPackage 1 | Out-Null
            adb -s $passengerDevice shell monkey -p $passengerPackage 1 | Out-Null
        }
    }

    Invoke-Step "Record the driver's real position" {
        $realStart = $null
        $deadline = (Get-Date).AddSeconds(60)
        while (-not $realStart -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $realStart = Get-DriverAppLocation $driverDevice $driverPackage
        }
        if ($realStart) {
            $script:homeLat = $realStart[0]
            $script:homeLng = $realStart[1]
            Write-Info ("home position {0}" -f (Format-LatLng $script:homeLat $script:homeLng))
        }
        else {
            Write-Info ("driver app reported no position; using fallback {0}" -f (Format-LatLng $homeLat $homeLng))
        }
    }

    if ($driverStartName -and -not $ResumeAtPickup) {
        Invoke-Step "Place the driver at $driverStartName" {
            Enable-MockLocation $driverDevice
            $script:driveProcess = Start-HoldProcess $driverStartLat $driverStartLng
            # Wait until the driver app reports the new position, so the ride
            # is dispatched to the driver from there.
            adb -s $driverDevice logcat -c | Out-Null
            $seen = $null
            $deadline = (Get-Date).AddSeconds(60)
            do {
                Start-Sleep -Seconds 3
                $seen = Get-DriverAppLocation $driverDevice $driverPackage
            } until (((Get-Date) -gt $deadline) -or
                ($seen -and (Get-Distance $seen[0] $seen[1] $driverStartLat $driverStartLng) -lt 100))
            if (-not $seen -or (Get-Distance $seen[0] $seen[1] $driverStartLat $driverStartLng) -ge 100) {
                throw "The driver app did not report the $driverStartName position within 60 s."
            }
            Write-Info ("driver app reports {0}" -f (Format-LatLng $seen[0] $seen[1]))
        }
    }

    if ($ResumeAtPickup) {
        # Continue a trip that is already accepted and waiting at the pickup.
        $script:driverProcess = Start-MaestroFlow $driverDevice ".\driver_start_trip.yaml" "driver"
    }
    else {
        # The driver goes online and waits for the request while the passenger books.
        $script:driverProcess = Start-MaestroFlow $driverDevice ".\driver_until_pin.yaml" "driver"
        Start-Sleep -Seconds 10

        Invoke-Step "Passenger books the ride" {
            # Let the passenger flow finish before dumping its UI; running
            # uiautomator while Maestro holds the device can break the session.
            $passengerProcess = Start-MaestroFlow $passengerDevice ".\passenger_book_trip.yaml" "passenger"
            Wait-MaestroFlow $passengerProcess "Passenger booking flow"
        }
    }

    Invoke-Step "Driver accepts the ride" {
        # Once the ride is accepted, the driver app logs the pickup and drop-off.
        $stops = $null
        $deadline = (Get-Date).AddMinutes(5)
        while (-not $stops -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $stops = Get-TripStops $driverDevice $driverPackage
        }
        if (-not $stops) { throw "No pickup/drop-off appeared in the driver app log within 5 minutes." }
        $script:stops = $stops
        Write-Info ("pickup {0}, drop-off {1}" -f (Format-LatLng $stops.PickupLat $stops.PickupLng),
            (Format-LatLng $stops.DropLat $stops.DropLng))
    }

    Invoke-Step "Start driving to the pickup (on the road)" {
        if ($driverStartName -and -not $ResumeAtPickup) {
            # Start exactly where the driver has been parked
            $driverStart = @($driverStartLat, $driverStartLng)
        }
        else {
            $driverStart = Get-DriverAppLocation $driverDevice $driverPackage
            if (-not $driverStart) { throw "Could not read the driver's current location from the driver app log." }
        }
        $route = Get-RoadRoute $driverStart[0] $driverStart[1] $script:stops.PickupLat $script:stops.PickupLng
        Enable-MockLocation $driverDevice
        Stop-DriveProcess $script:driveProcess
        $script:driveProcess = Start-DriveProcess "route-to-pickup" $route
    }

    Invoke-Step "Read the ride PIN from the passenger phone" {
        $pin = $null
        $deadline = (Get-Date).AddMinutes(5)
        while (-not $pin -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $dump = adb -s $passengerDevice exec-out uiautomator dump /dev/tty
            $digits = [regex]::Matches($dump, 'resource-id="otp"[^>]*content-desc="([0-9])"')
            if ($digits.Count -eq 4) {
                $pin = ($digits | ForEach-Object { $_.Groups[1].Value }) -join ""
            }
        }
        if (-not $pin) { throw "Could not read the four-digit ride PIN from the passenger phone." }
        $script:pin = $pin
        Write-Info "PIN $pin"
    }

    Invoke-Step "Driver reaches the pickup and opens the PIN screen" {
        # Only one Maestro session may control the driver phone at a time.
        Wait-MaestroFlow $script:driverProcess "Driver flow up to the Ride Start PIN screen"
    }

    Invoke-Step "Start driving to the drop-off (on the road)" {
        # The driver is already at the pickup, so the new route starts there.
        $route = Get-RoadRoute $script:stops.PickupLat $script:stops.PickupLng $script:stops.DropLat $script:stops.DropLng
        Stop-DriveProcess $script:driveProcess
        $script:driveProcess = Start-DriveProcess "route-to-drop" $route
    }

    Invoke-Step "Enter PIN, drive to the drop-off and end the ride" {
        # Maestro ignores ordinary environment variables; the PIN must be
        # passed with -e so ${RIDE_START_PIN} resolves inside the flow.
        $process = Start-MaestroFlow $driverDevice ".\driver_after_pin.yaml" "driver" "-e RIDE_START_PIN=$($script:pin)"
        Wait-MaestroFlow $process "Driver trip flow"
    }

    Invoke-Step "Passenger rates the driver and returns home" {
        $process = Start-MaestroFlow $passengerDevice ".\passenger_finish_trip.yaml" "passenger"
        Wait-MaestroFlow $process "Passenger rating flow"
    }
}
catch {
    $failed = $true
}
finally {
    # Always give the driver phone its real location back, even after a failure.
    try {
        Invoke-Step "Reset the driver's location" {
            Stop-MaestroFlow $script:driverProcess
            Stop-DriveProcess $script:driveProcess
            Reset-MockLocation $driverDevice $script:homeLat $script:homeLng $driverPackage
        }
    }
    catch {
        $failed = $true
    }

    Write-Host ""
    Write-Host "================ Trip summary ================"
    $script:steps | Format-Table -AutoSize | Out-String | Write-Host
    if ($failed) {
        Write-Host "RESULT: FAILED" -ForegroundColor Red
    }
    else {
        Write-Host "RESULT: PASSED" -ForegroundColor Green
    }
    Write-Host "Logs: $logDir"
    Stop-Transcript | Out-Null
}

if ($failed) { exit 1 }
