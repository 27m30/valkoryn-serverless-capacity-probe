[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceStatePath,
    [string]$RequestPath=(Join-Path $PSScriptRoot 'one-probe-request.json'),
    [string]$SubmissionRecordPath=(Join-Path $PSScriptRoot 'one-probe-submission.json'),
    [switch]$ApproveOneProbe,
    [string]$ApprovalToken,
    [string]$ApiKeyEnvironment='RUNPOD_API_KEY',
    [int]$PollIntervalSeconds=2,
    [int]$JobTimeoutSeconds=300,
    [int]$ScaleToZeroTimeoutSeconds=180
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(!$ApproveOneProbe-or$ApprovalToken-ne'APPROVE_EXACTLY_ONE_SERVERLESS_CAPACITY_PROBE'){throw 'Exact one-probe approval switch and token are required.'}
if(Test-Path -LiteralPath $SubmissionRecordPath){throw "Submission record already exists at '$SubmissionRecordPath'; a second probe requires separate approval and a new reviewed record path."}
$state=Get-Content -LiteralPath $ResourceStatePath -Raw|ConvertFrom-Json
if([string]$state.probe-ne'SERVERLESS_CAPACITY_PROBE_V1'-or[string]::IsNullOrWhiteSpace([string]$state.endpoint_id)){throw 'Approved probe endpoint state is missing.'}
if([bool]$state.probe_submitted){throw 'Resource state says a probe was already submitted.'}
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$request.input.nonce=[guid]::NewGuid().ToString('N')
$apiKey=[Environment]::GetEnvironmentVariable($ApiKeyEnvironment)
if([string]::IsNullOrWhiteSpace($apiKey)){throw "API key environment variable '$ApiKeyEnvironment' is empty."}
$headers=@{Authorization="Bearer $apiKey";Accept='application/json'}
$endpoint=[uri]::EscapeDataString([string]$state.endpoint_id)
$base='https://api.runpod.ai/v2'
$endpointProof=Invoke-RestMethod -Method GET -Uri "https://rest.runpod.io/v1/endpoints/$endpoint" -Headers $headers
$expectedGpuTypes=@('NVIDIA L40S','NVIDIA RTX 6000 Ada Generation','NVIDIA A40')
if([string]$endpointProof.name-ne'valkoryn-capacity-probe-v1'-or[int]$endpointProof.workersMin-ne 0-or[int]$endpointProof.workersMax-ne 1-or[int]$endpointProof.gpuCount-ne 1){throw 'Live endpoint proof differs from the approved scale/GPU configuration.'}
if(@($endpointProof.networkVolumeIds).Count-ne 0-or(@($endpointProof.gpuTypeIds)-join'|')-ne($expectedGpuTypes-join'|')){throw 'Live endpoint proof has a volume or different GPU priority.'}
$record=[pscustomobject][ordered]@{schema_version=1;probe='SERVERLESS_CAPACITY_PROBE_V1';endpoint_id=[string]$state.endpoint_id;nonce=[string]$request.input.nonce;intent_created_at=[DateTimeOffset]::UtcNow.ToString('o');remote_job_id=$null;submitted_at=$null;completed_at=$null;terminal_status=$null;result=$null}
function Save-Record {
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($SubmissionRecordPath));[IO.Directory]::CreateDirectory($directory)|Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($SubmissionRecordPath),($record|ConvertTo-Json -Depth 30)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}
Save-Record
$wallStart=[DateTimeOffset]::UtcNow
$submission=Invoke-RestMethod -Method POST -Uri "$base/$endpoint/run" -Headers $headers -ContentType 'application/json' -Body ($request|ConvertTo-Json -Depth 20 -Compress)
if([string]::IsNullOrWhiteSpace([string]$submission.id)){throw 'RunPod did not return a job ID.'}
$record.remote_job_id=[string]$submission.id;$record.submitted_at=[DateTimeOffset]::UtcNow.ToString('o');Save-Record
do{
    Start-Sleep -Seconds $PollIntervalSeconds
    $status=Invoke-RestMethod -Method GET -Uri "$base/$endpoint/status/$([uri]::EscapeDataString([string]$record.remote_job_id))" -Headers $headers
    if([string]$status.status-in@('COMPLETED','FAILED','TIMED_OUT','CANCELLED')){break}
}while(([DateTimeOffset]::UtcNow-$wallStart).TotalSeconds-lt$JobTimeoutSeconds)
if([string]$status.status-notin@('COMPLETED','FAILED','TIMED_OUT','CANCELLED')){throw "Probe polling timed out; the durable remote job ID is $($record.remote_job_id)."}
$record.completed_at=[DateTimeOffset]::UtcNow.ToString('o');$record.terminal_status=[string]$status.status
if([string]$status.status-ne'COMPLETED'){$record.result=$status;Save-Record;throw "Capacity probe ended with status $($status.status)."}
$output=$status.output
$required=@('worker_id','actual_gpu_model','cuda','vram','cpu','ram','hostname','worker_startup_timestamp','handler_execution_timestamp','cold_start_duration_ms')
$actual=@($output.PSObject.Properties.Name)
if(@($required|Where-Object{$_-notin$actual}).Count-or@($actual|Where-Object{$_-notin$required}).Count){throw 'Capacity probe returned an invalid output contract.'}
$approved=@('NVIDIA L40S','NVIDIA RTX 6000 Ada Generation','NVIDIA L40','NVIDIA RTX A6000','NVIDIA A40')
if([string]$output.actual_gpu_model-notin$approved-or![bool]$output.cuda.available-or[long]$output.vram.total_bytes-lt 47000000000){throw 'Capacity probe returned an unapproved or insufficient GPU proof.'}
$rate=if([string]$output.actual_gpu_model-in@('NVIDIA RTX A6000','NVIDIA A40')){0.00034}else{0.00053}
$executionMs=[double]$(if($null-ne$status.PSObject.Properties['executionTime']){$status.executionTime}else{0})
$delayMs=[double]$(if($null-ne$status.PSObject.Properties['delayTime']){$status.delayTime}else{0})
$coldMs=[double]$output.cold_start_duration_ms
$lowerCost=[math]::Round((($executionMs+$coldMs)/1000.0)*$rate,6)
$withIdleCost=[math]::Round(((($executionMs+$coldMs)/1000.0)+60)*$rate,6)
$scaleStart=[DateTimeOffset]::UtcNow;$scaledToZero=$false
do{
    Start-Sleep -Seconds $PollIntervalSeconds
    $health=Invoke-RestMethod -Method GET -Uri "$base/$endpoint/health" -Headers $headers
    if([int]$health.workers.running-eq 0-and[int]$health.workers.idle-eq 0){$scaledToZero=$true;break}
}while(([DateTimeOffset]::UtcNow-$scaleStart).TotalSeconds-lt$ScaleToZeroTimeoutSeconds)
$region=$null
foreach($name in @('dataCenterId','datacenter','region')){if($null-ne$status.PSObject.Properties[$name]){$region=[string]$status.$name;break}}
$report=[pscustomobject][ordered]@{worker_assigned=$true;remote_job_id=[string]$record.remote_job_id;worker_id=[string]$output.worker_id;actual_gpu_model=[string]$output.actual_gpu_model;queue_delay_ms=$delayMs;worker_startup_timestamp=[string]$output.worker_startup_timestamp;handler_execution_timestamp=[string]$output.handler_execution_timestamp;cold_start_duration_ms=$coldMs;handler_execution_time_ms=$executionMs;total_observed_job_latency_ms=[math]::Round(([DateTimeOffset]::UtcNow-$wallStart).TotalMilliseconds,3);cuda=$output.cuda;vram=$output.vram;cpu=$output.cpu;ram=$output.ram;hostname=[string]$output.hostname;region_or_datacenter=$region;estimated_compute_cost_before_idle_usd=$lowerCost;estimated_compute_cost_including_60s_idle_usd=$withIdleCost;scaled_to_zero_observed=$scaledToZero}
$record.result=$report;Save-Record
$report
