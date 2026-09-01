# SERVERLESS_CAPACITY_PROBE_V1

This isolated RunPod Serverless queue worker measures only compute placement.
It does not import or mount any Valkoryn production worker, workflow, model,
character, media, or release artifact.

The worker uses a CUDA base image plus Python and the RunPod handler SDK. It
does not install PyTorch because `nvidia-smi` and Linux procfs provide every
measurement required by the probe. The CUDA 12.8 base remains compatible with
the intended PyTorch cu128 production runtime while keeping the image small.

The first handler call measures cold-start duration from Python module import
to handler entry. This excludes container scheduling and image-pull time, so
RunPod's queue delay and execution-time fields must be retained alongside the
handler response for the complete cold-start measurement.

Safety gates in `endpoint-proposal.json` default to false. `Invoke-Probe.ps1`
prints a plan by default and refuses a live `/run` unless both the checked-in
gate and an exact approval token are supplied.

Offline tests:

```powershell
py -m unittest discover -s .\tests -v
powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\..\tests\Test-ServerlessCapacityProbeV1.ps1
```
