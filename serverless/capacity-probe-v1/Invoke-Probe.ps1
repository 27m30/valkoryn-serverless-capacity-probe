[CmdletBinding()]
param(
    [ValidateSet('Plan')][string]$Mode='Plan',
    [string]$ConfigurationPath=(Join-Path $PSScriptRoot 'endpoint-proposal.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$configuration=Get-Content -LiteralPath $ConfigurationPath -Raw|ConvertFrom-Json
$nonce=[guid]::NewGuid().ToString('N')
$body=$configuration.request_body|ConvertTo-Json -Depth 20|ConvertFrom-Json
$body.input.nonce=$nonce

[pscustomobject][ordered]@{
    probe=$configuration.probe
    mutation_performed=$false
    live_submission_enabled=[bool]$configuration.live_submission_enabled
    endpoint_id=$configuration.endpoint_id
    gpu_priority=@($configuration.gpu_policy.rest_priority_types)
    network_volume_ids=@($configuration.network_volume_ids)
    request=$body
    maximum_expected_probe_cost_usd=[double]$configuration.pricing_guard.maximum_expected_probe_cost_usd
}
