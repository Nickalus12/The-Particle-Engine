param(
  [ValidateSet("pr", "nightly", "investigative")]
  [string]$Profile = "pr",
  [ValidateSet("quick", "nightly")]
  [string]$SoakLevel = "",
  [switch]$IncludeSoak,
  [int]$TargetTimeoutSeconds = 0,
  [string]$OtlpEndpoint = "http://localhost:4318",
  [switch]$EmitVisualArtifacts,
  [string]$ArtifactRoot = "",
  [int]$MaxFailedVisualCases = 0
)

$ErrorActionPreference = "Stop"

$script = Join-Path $PSScriptRoot "run_performance_pipeline.py"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = $OtlpEndpoint

$args = @(
  "--profile", $Profile,
  "--export-otlp"
)
if ($SoakLevel -ne "") {
  $args += @("--soak-level", $SoakLevel)
}
if ($TargetTimeoutSeconds -gt 0) {
  $args += @("--target-timeout-seconds", $TargetTimeoutSeconds)
}
if ($IncludeSoak) {
  $args += "--include-soak"
}
if ($EmitVisualArtifacts) {
  $args += "--emit-visual-artifacts"
}
if ($ArtifactRoot -ne "") {
  $args += @("--artifact-root", $ArtifactRoot)
}
$args += @("--max-failed-visual-cases", $MaxFailedVisualCases)

python $script @args
