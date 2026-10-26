# PowerShell: mock GPS helpers for run-trip-flow.ps1.
# Uses Android's built-in test location providers through adb, so no helper
# app is installed and nothing posts notifications on the phones.

function adb {
    # Wraps adb.exe so its stderr chatter (e.g. monkey printing its arguments)
    # is dropped instead of becoming a terminating error when the caller uses
    # $ErrorActionPreference = "Stop" in Windows PowerShell 5.1.
    $ErrorActionPreference = "Continue"
    & adb.exe @args 2>$null
}

$script:MockProviders = "gps", "network", "fused"
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Format-LatLng([double]$Lat, [double]$Lng) {
    return "{0},{1}" -f $Lat.ToString("0.0000000", $script:Inv), $Lng.ToString("0.0000000", $script:Inv)
}

function Get-Distance([double]$Lat1, [double]$Lng1, [double]$Lat2, [double]$Lng2) {
    # Haversine distance in metres
    $toRad = [Math]::PI / 180
    $dLat = ($Lat2 - $Lat1) * $toRad
    $dLng = ($Lng2 - $Lng1) * $toRad
    $a = [Math]::Sin($dLat / 2) * [Math]::Sin($dLat / 2) +
        [Math]::Cos($Lat1 * $toRad) * [Math]::Cos($Lat2 * $toRad) * [Math]::Sin($dLng / 2) * [Math]::Sin($dLng / 2)
    return 2 * 6371000 * [Math]::Asin([Math]::Sqrt($a))
}

function Enable-MockLocation([string]$Device) {
    # The adb shell user needs the mock-location app-op to register test providers
    adb -s $Device shell appops set com.android.shell android:mock_location allow | Out-Null
    $commands = foreach ($provider in $script:MockProviders) {
        "cmd location providers add-test-provider $provider; cmd location providers set-test-provider-enabled $provider true"
    }
    adb -s $Device shell ($commands -join "; ") 2>&1 | Out-Null
}

function Set-MockLocation([string]$Device, [double]$Lat, [double]$Lng) {
    # One adb call per update, covering every provider the apps may listen to
    $location = Format-LatLng $Lat $Lng
    $commands = foreach ($provider in $script:MockProviders) {
        "cmd location providers set-test-provider-location $provider --location $location --accuracy 5"
    }
    adb -s $Device shell ($commands -join "; ") 2>&1 | Out-Null
}

function Hold-MockLocation([string]$Device, [double]$Lat, [double]$Lng) {
    # Keeps re-sending a fixed position until the job running it is stopped
    while ($true) {
        Set-MockLocation $Device $Lat $Lng
        Start-Sleep -Seconds 2
    }
}

function Get-RoadRoute([double]$FromLat, [double]$FromLng, [double]$ToLat, [double]$ToLng) {
    # Driving route on real roads from the public OSRM (OpenStreetMap) server.
    # Returns JSON of [[lat, lng], ...] so it can be passed to background jobs.
    $from = "{0},{1}" -f $FromLng.ToString($script:Inv), $FromLat.ToString($script:Inv)
    $to = "{0},{1}" -f $ToLng.ToString($script:Inv), $ToLat.ToString($script:Inv)
    $url = "https://router.project-osrm.org/route/v1/driving/${from};${to}?overview=full&geometries=geojson"
    $response = Invoke-RestMethod -Uri $url -TimeoutSec 30
    if ($response.code -ne "Ok" -or -not $response.routes) {
        throw "No road route found from $from to $to."
    }
    # GeoJSON coordinates are [lng, lat]
    $points = foreach ($c in $response.routes[0].geometry.coordinates) { , @([double]$c[1], [double]$c[0]) }
    Write-Host ("Road route: {0:0} m, {1} points" -f $response.routes[0].distance, $points.Count)
    return ConvertTo-Json -InputObject @($points) -Compress
}

function Invoke-RouteDrive([string]$Device, [string]$RouteJson, [double]$SpeedKmh = 35, [switch]$HoldAtEnd) {
    # Moves the mock position along the route at a steady speed, one update
    # per second. Position comes from elapsed time, so slow adb calls never
    # make the vehicle skip ahead or slow down.
    # PowerShell 5.1 returns the JSON array as one object; don't wrap it in @()
    $points = ConvertFrom-Json $RouteJson
    $cumulative = New-Object double[] $points.Count
    for ($i = 1; $i -lt $points.Count; $i++) {
        $cumulative[$i] = $cumulative[$i - 1] +
            (Get-Distance $points[$i - 1][0] $points[$i - 1][1] $points[$i][0] $points[$i][1])
    }
    $total = $cumulative[$points.Count - 1]
    $speed = $SpeedKmh / 3.6
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $segment = 0
    $lastReport = -1
    Write-Host ("  [gps] driving {0:0.0} km at {1} km/h (about {2:0.0} min)" -f ($total / 1000), $SpeedKmh, ($total / $speed / 60))

    while ($true) {
        $travelled = [Math]::Min($clock.Elapsed.TotalSeconds * $speed, $total)
        while ($segment -lt $points.Count - 2 -and $cumulative[$segment + 1] -lt $travelled) { $segment++ }
        $length = $cumulative[$segment + 1] - $cumulative[$segment]
        $f = if ($length -gt 0) { ($travelled - $cumulative[$segment]) / $length } else { 0 }
        $lat = $points[$segment][0] + ($points[$segment + 1][0] - $points[$segment][0]) * $f
        $lng = $points[$segment][1] + ($points[$segment + 1][1] - $points[$segment][1]) * $f
        Set-MockLocation $Device $lat $lng

        # Progress line every 15 seconds
        $report = [int][Math]::Floor($clock.Elapsed.TotalSeconds / 15)
        if ($report -ne $lastReport) {
            Write-Host ("  [gps] {0:0.0} / {1:0.0} km" -f ($travelled / 1000), ($total / 1000))
            $lastReport = $report
        }
        if ($travelled -ge $total) { break }
        Start-Sleep -Seconds 1
    }
    Write-Host ("  [gps] arrived ({0:0.0} km)" -f ($total / 1000))

    if ($HoldAtEnd) {
        $last = $points[$points.Count - 1]
        Hold-MockLocation $Device $last[0] $last[1]
    }
}

function Reset-MockLocation([string]$Device, [double]$HomeLat, [double]$HomeLng, [string]$Package = "com.miwayz.driversapp.qa") {
    # Gives the phone back its real GPS without a reboot. Google Play Services
    # and the app keep the last position they received, so the phone is first
    # parked at its real (home) position until the app reports it; that is what
    # stays shown once the test providers are removed, instead of the trip's
    # last point.
    Enable-MockLocation $Device
    adb -s $Device logcat -c | Out-Null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $confirmed = $false
    while (-not $confirmed -and $clock.Elapsed.TotalSeconds -lt 90) {
        Set-MockLocation $Device $HomeLat $HomeLng
        Start-Sleep -Seconds 2
        $seen = Get-DriverAppLocation $Device $Package
        # Park at least 10 s, then wait until the app reports the home position
        $confirmed = $clock.Elapsed.TotalSeconds -ge 10 -and $seen -and
            (Get-Distance $seen[0] $seen[1] $HomeLat $HomeLng) -lt 30
    }
    if (-not $confirmed) {
        Write-Host "  [gps] the app did not report the home position within 90 s; resetting anyway" -ForegroundColor Yellow
    }

    $commands = foreach ($provider in $script:MockProviders) {
        "cmd location providers remove-test-provider $provider"
    }
    adb -s $Device shell ($commands -join "; ") | Out-Null
    adb -s $Device shell appops set com.android.shell android:mock_location default | Out-Null
    # Apps are left running: closing them mid-trip would interrupt the trip.
    Write-Host ("Location reset on {0} (home {1})." -f $Device, (Format-LatLng $HomeLat $HomeLng))
}

function Get-AppLogText([string]$Device, [string]$Package) {
    $appPid = adb -s $Device shell pidof $Package
    if (-not $appPid) { return "" }
    return (adb -s $Device logcat -d --pid=$appPid) -join "`n"
}

function Get-DriverAppLocation([string]$Device, [string]$Package) {
    # Latest position the driver app reported (location update or heat-map request)
    $log = Get-AppLogText $Device $Package
    $found = [regex]::Matches($log,
        '"latitude":([0-9.]+),"longitude":([0-9.]+)|locationData: \{latitude: ([0-9.]+), longitude: ([0-9.]+)')
    if ($found.Count -eq 0) { return $null }
    $m = $found[$found.Count - 1]
    if ($m.Groups[1].Success) { return @([double]$m.Groups[1].Value, [double]$m.Groups[2].Value) }
    return @([double]$m.Groups[3].Value, [double]$m.Groups[4].Value)
}

function Get-TripStops([string]$Device, [string]$Package) {
    # Pickup and drop-off coordinates from the trip message the driver app logs
    # once a ride has been accepted
    $log = Get-AppLogText $Device $Package
    $pickup = [regex]::Matches($log, '\{type: PICKUP[^}]*?latitude: ([0-9.]+), longitude: ([0-9.]+)')
    $drop = [regex]::Matches($log, '\{type: DROP[^}]*?latitude: ([0-9.]+), longitude: ([0-9.]+)')
    if ($pickup.Count -eq 0 -or $drop.Count -eq 0) { return $null }
    $p = $pickup[$pickup.Count - 1]; $d = $drop[$drop.Count - 1]
    return @{
        PickupLat = [double]$p.Groups[1].Value; PickupLng = [double]$p.Groups[2].Value
        DropLat = [double]$d.Groups[1].Value; DropLng = [double]$d.Groups[2].Value
    }
}
