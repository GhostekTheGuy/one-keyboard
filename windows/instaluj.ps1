# Jedna Klawiatura - instalator agenta na Windowsie.
# Uruchomienie (najlepiej w PowerShellu jako administrator):
#   irm http://ADRES_MACA:24851/instaluj.ps1 | iex
$ErrorActionPreference = 'Stop'
$base = '__BASE__'
$dir = Join-Path $env:LOCALAPPDATA 'JednaKlawiatura'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$agent = Join-Path $dir 'agent.ps1'
Invoke-WebRequest -UseBasicParsing "$base/agent.ps1" -OutFile $agent

# zatrzymaj poprzednia wersje
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*JednaKlawiatura*agent.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'JednaKlawiatura' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    $old = Join-Path ([Environment]::GetFolderPath('Startup')) 'JednaKlawiatura.lnk'
    if (Test-Path $old) { Remove-Item $old -Force }
    Start-ScheduledTask -TaskName 'JednaKlawiatura'
    Write-Host 'OK: agent dziala (jako administrator) i bedzie startowal sam po zalogowaniu.' -ForegroundColor Green
} else {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'JednaKlawiatura.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = 'powershell.exe'
    $s.Arguments = $arg
    $s.WindowStyle = 7
    $s.Save()
    Start-Process powershell.exe -ArgumentList $arg -WindowStyle Hidden
    Write-Host 'OK: agent dziala i startuje sam po zalogowaniu.' -ForegroundColor Green
    Write-Host 'Bez administratora nie wpisze nic do okien uruchomionych jako administrator.' -ForegroundColor Yellow
    Write-Host 'Pelna wersja: uruchom to samo polecenie w PowerShellu jako administrator.' -ForegroundColor Yellow
}
Start-Sleep -Seconds 3
Write-Host '--- log agenta ---'
Get-Content (Join-Path $dir 'agent.log') -Tail 5 -ErrorAction SilentlyContinue
