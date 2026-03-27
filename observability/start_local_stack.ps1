param(
  [switch]$Recreate
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$composeFile = Join-Path $PSScriptRoot "docker-compose.yml"

if ($Recreate) {
  docker compose -f $composeFile down --remove-orphans
}

docker compose -f $composeFile up -d

Write-Host "Waiting for Grafana health endpoint..."
$maxAttempts = 30
$healthy = $false
for ($i = 0; $i -lt $maxAttempts; $i++) {
  try {
    $resp = Invoke-WebRequest -Uri "http://localhost:3000/api/health" -UseBasicParsing -TimeoutSec 2
    if ($resp.StatusCode -eq 200) {
      Write-Host "Grafana is healthy at http://localhost:3000"
      $healthy = $true
      break
    }
  } catch {
    Start-Sleep -Seconds 1
  }
}

if (-not $healthy) {
  Write-Error "Grafana did not become healthy in time."
}

try {
  $pair = "admin:admin"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
  $token = [Convert]::ToBase64String($bytes)
  $headers = @{ Authorization = "Basic $token" }
  $dash = Invoke-WebRequest `
    -Uri "http://localhost:3000/api/dashboards/uid/particle-perf-overview" `
    -Headers $headers -UseBasicParsing -TimeoutSec 4
  if ($dash.StatusCode -eq 200) {
    Write-Host "Provisioned dashboard detected: particle-perf-overview"
    exit 0
  }
} catch {
  Write-Warning "Grafana is healthy but dashboard provisioning not yet ready."
  exit 0
}
