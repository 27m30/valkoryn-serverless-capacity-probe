[CmdletBinding()]
param(
    [ValidateSet('Plan','Create')][string]$Mode='Plan',
    [Parameter(Mandatory)][string]$TemplateConfigurationPath,
    [string]$EndpointConfigurationPath=(Join-Path $PSScriptRoot 'endpoint-create.template.json'),
    [string]$StatePath=(Join-Path $PSScriptRoot 'live-resource-state.json'),
    [switch]$ApproveResourceCreation,
    [string]$ApprovalToken,
    [string]$ApiKeyEnvironment='RUNPOD_API_KEY'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$template=Get-Content -LiteralPath $TemplateConfigurationPath -Raw|ConvertFrom-Json
$endpoint=Get-Content -LiteralPath $EndpointConfigurationPath -Raw|ConvertFrom-Json

function Assert-ProbeResourcePlan {
    if([string]$template.imageName-notmatch'^ghcr\.io/[a-z0-9_.-]+/valkoryn-serverless-capacity-probe-v1@sha256:[a-f0-9]{64}$'){throw 'Template image must be the immutable GHCR probe digest reference.'}
    if([string]$template.name-ne'valkoryn-capacity-probe-v1'-or![bool]$template.isServerless-or[bool]$template.isPublic){throw 'Template identity or visibility is invalid.'}
    if([int]$template.volumeInGb-ne 0-or@($template.ports).Count-ne 0){throw 'Probe template must have no local volume and no exposed ports.'}
    if([string]$endpoint.name-ne'valkoryn-capacity-probe-v1'-or[int]$endpoint.workersMin-ne 0-or[int]$endpoint.workersMax-ne 1-or[int]$endpoint.gpuCount-ne 1){throw 'Endpoint scale/GPU policy is invalid.'}
    if(@($endpoint.networkVolumeIds).Count-ne 0-or@($endpoint.dataCenterIds).Count-ne 0){throw 'Endpoint must have no network volume and no region restriction.'}
    $expected=@('NVIDIA L40S','NVIDIA RTX 6000 Ada Generation','NVIDIA A40')
    if((@($endpoint.gpuTypeIds)-join'|')-ne($expected-join'|')){throw 'Endpoint GPU priority differs from the approved probe order.'}
    if([int]$endpoint.idleTimeout-ne 60-or[int]$endpoint.executionTimeoutMs-ne 60000){throw 'Endpoint timeouts differ from the approved probe values.'}
}

function Save-State([object]$Value){
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($StatePath));[IO.Directory]::CreateDirectory($directory)|Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($StatePath),($Value|ConvertTo-Json -Depth 30)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}

Assert-ProbeResourcePlan
$plan=[pscustomobject][ordered]@{
    mutation_performed=$false
    template_api='POST https://rest.runpod.io/v1/templates'
    endpoint_api='POST https://rest.runpod.io/v1/endpoints'
    template=$template
    endpoint=$endpoint
    creates_network_volume=$false
    modifies_existing_resource=$false
}
if($Mode-eq'Plan'){$plan;return}

if(!$ApproveResourceCreation-or$ApprovalToken-ne'APPROVE_CREATE_ONE_CAPACITY_PROBE_TEMPLATE_AND_ENDPOINT'){throw 'Exact resource-creation approval switch and token are required.'}
if(Test-Path -LiteralPath $StatePath){throw "Resource state already exists at '$StatePath'; refusing duplicate creation."}
$apiKey=[Environment]::GetEnvironmentVariable($ApiKeyEnvironment)
if([string]::IsNullOrWhiteSpace($apiKey)){throw "API key environment variable '$ApiKeyEnvironment' is empty."}
$headers=@{Authorization="Bearer $apiKey";Accept='application/json'}
$existingTemplates=@(Invoke-RestMethod -Method GET -Uri 'https://rest.runpod.io/v1/templates?includeEndpointBoundTemplates=true' -Headers $headers)
if(@($existingTemplates|Where-Object{$_.name-eq'valkoryn-capacity-probe-v1'}).Count){throw 'A RunPod template named valkoryn-capacity-probe-v1 already exists; refusing duplicate creation.'}
$existingEndpoints=@(Invoke-RestMethod -Method GET -Uri 'https://rest.runpod.io/v1/endpoints' -Headers $headers)
if(@($existingEndpoints|Where-Object{$_.name-eq'valkoryn-capacity-probe-v1'}).Count){throw 'A RunPod endpoint named valkoryn-capacity-probe-v1 already exists; refusing duplicate creation.'}
$state=[pscustomobject][ordered]@{schema_version=1;probe='SERVERLESS_CAPACITY_PROBE_V1';image_digest_reference=[string]$template.imageName;template_id=$null;endpoint_id=$null;template_created_at=$null;endpoint_created_at=$null;probe_submitted=$false}
$createdTemplate=Invoke-RestMethod -Method POST -Uri 'https://rest.runpod.io/v1/templates' -Headers $headers -ContentType 'application/json' -Body ($template|ConvertTo-Json -Depth 20 -Compress)
if([string]::IsNullOrWhiteSpace([string]$createdTemplate.id)-or[string]$createdTemplate.imageName-ne[string]$template.imageName-or![bool]$createdTemplate.isServerless){throw 'RunPod returned an invalid template proof.'}
$state.template_id=[string]$createdTemplate.id;$state.template_created_at=[DateTimeOffset]::UtcNow.ToString('o');Save-State $state
$endpoint.templateId=$state.template_id
$createdEndpoint=Invoke-RestMethod -Method POST -Uri 'https://rest.runpod.io/v1/endpoints' -Headers $headers -ContentType 'application/json' -Body ($endpoint|ConvertTo-Json -Depth 20 -Compress)
if([string]::IsNullOrWhiteSpace([string]$createdEndpoint.id)-or[string]$createdEndpoint.name-ne'valkoryn-capacity-probe-v1'-or[int]$createdEndpoint.workersMin-ne 0-or[int]$createdEndpoint.workersMax-ne 1){throw 'RunPod returned an invalid endpoint proof.'}
$state.endpoint_id=[string]$createdEndpoint.id;$state.endpoint_created_at=[DateTimeOffset]::UtcNow.ToString('o');Save-State $state
[pscustomobject][ordered]@{mutation_performed=$true;template_id=$state.template_id;endpoint_id=$state.endpoint_id;state_path=[IO.Path]::GetFullPath($StatePath);probe_submitted=$false}
