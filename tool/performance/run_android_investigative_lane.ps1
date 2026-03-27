param(
  [string]$DeviceId = "",
  [int]$TargetTimeoutSeconds = 180,
  [string]$ArtifactDir = "",
  [switch]$ExportOtlp,
  [switch]$NoRequireTelemetryComplete
)

$ErrorActionPreference = "Stop"

$script = Join-Path $PSScriptRoot "run_android_investigative_lane.py"
$args = @(
  "--target-timeout-seconds", $TargetTimeoutSeconds
)
if ($DeviceId -ne "") {
  $args += @("--device-id", $DeviceId)
}
if ($ArtifactDir -ne "") {
  $args += @("--artifact-dir", $ArtifactDir)
}
if ($ExportOtlp) {
  $args += "--export-otlp"
}
if ($NoRequireTelemetryComplete) {
  $args += "--no-require-telemetry-complete"
}

python $script @args
