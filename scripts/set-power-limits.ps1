# GPU power limits for this rig. Run as Administrator; `nvidia-smi -pl` needs it.
#
#     powershell -ExecutionPolicy Bypass -File scripts\set-power-limits.ps1
#
# These do NOT persist across a reboot — nvidia-smi power limits are runtime only.
# Re-run after every boot, or register it as a scheduled task at startup:
#
#     schtasks /create /tn "sc-gpu-power" /tr "powershell -ExecutionPolicy Bypass -File
#       C:\Users\mail\working\Personal\SmartCoder\smart-coder-ops\scripts\set-power-limits.ps1"
#       /sc onstart /ru SYSTEM
#
# WHY these numbers, on 2026-08-29:
#
# GPU0, RTX 3080 Ti — 350W, its stock limit. It is the DESKTOP card as well as half
# the inference rig, so it is left alone: capping it costs frames in games for no
# stability benefit once the PSU was fixed.
#
# GPU1, RTX 3080 — 200W, well under its 380W stock. This card died mid-run: NVML
# reported "GPU is lost" while Windows still saw it enumerated and healthy (PnP
# Status OK, problem code 0), the llama.cpp process exited 128, and there was no Xid,
# no CUDA error and no nvlddmkm event anywhere. Core temperature was 75C, which is
# unremarkable for a 3080 — but GDDR6X runs 20-30C above the die, so the memory
# junction was plausibly near 100C, and a memory fault looks exactly like this: the
# card stops responding without dropping off the bus.
#
# It was also carrying more than usual. The tensor split had moved from 12,8 to 10,10
# to buy VRAM headroom on the Ti, taking this card from 7.3GB to 8.9GB — a 22% rise
# in active VRAM, which raises MEMORY temperature specifically.
#
# 200W is a deliberate over-correction while we find out whether that was the cause.
# Check with:
#
#     nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory --format=csv
#
# If memory junction sits near 100C under load, it is thermal (pads/airflow on that
# card) rather than anything the harness does. Raise this back toward 300W once a few
# full eval runs have completed without a loss.

$ErrorActionPreference = 'Stop'

$limits = @(
    @{ Index = 0; Watts = 350; Note = 'RTX 3080 Ti — stock; also the desktop card' },
    @{ Index = 1; Watts = 200; Note = 'RTX 3080 — capped after a mid-run GPU loss' }
)

foreach ($l in $limits) {
    Write-Host "GPU$($l.Index) -> $($l.Watts)W  ($($l.Note))"
    & nvidia-smi -i $l.Index -pl $l.Watts
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "GPU$($l.Index): nvidia-smi exited $LASTEXITCODE (lost card? not elevated?)"
    }
}

Write-Host ''
& nvidia-smi --query-gpu=index,name,power.limit,temperature.gpu --format=csv
