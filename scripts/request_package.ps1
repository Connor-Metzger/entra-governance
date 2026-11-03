<#
.SYNOPSIS
    Admin direct assignment of a requested access package to one person, with a justification (M2.5).

.DESCRIPTION
    Sends an "adminAdd" assignment request, then follows it until Entra delivers or rejects it.
    Use it to show two things in the lab:
      - a delivered assignment carries the policy's expiry date
      - an incompatible package (SoD) blocks the assignment, even when an admin makes it
    An admin direct assignment SKIPS the approval stages. In production only the access package
    assignment managers can do this, and every one is in the request history. End users request
    at myaccess.microsoft.com and go through the approval stages.
    Prints names and employee IDs only (no object IDs), so the output can go into evidence/.

.EXAMPLE
    .\scripts\request_package.ps1 -EmployeeId E00001 -Package "ADD-06 StoreOps Cash Office" -Justification "..."
    .\scripts\request_package.ps1 -EmployeeId E00013 -Package "ADD-06 StoreOps Cash Office" -Justification "..." -EvidenceDir evidence/M2.5
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$EmployeeId,
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Justification,
    [string]$CatalogName = "Keystone Store & Fuel Operations",
    [int]$WaitSeconds    = 120,
    [string]$EvidenceDir = ""
)
$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
$em    = "$graph/identityGovernance/entitlementManagement"
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }
if ($Justification.Trim().Length -lt 15) { throw "Give a real justification (who, what for, how long)." }
function F([string]$f) { return [uri]::EscapeDataString($f) }

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { $lines.Add($t); Write-Host $t }

$u = @((Invoke-MgGraphRequest GET "$graph/users?`$filter=$(F "employeeId eq '$EmployeeId'")&`$select=id,displayName,jobTitle,officeLocation,accountEnabled").value)
if ($u.Count -ne 1) { throw "$EmployeeId : $($u.Count) users found (expected 1)." }
$u = $u[0]
$pkgs = @((Invoke-MgGraphRequest GET "$em/accessPackages?`$filter=$(F "displayName eq '$Package'")&`$expand=catalog,assignmentPolicies").value |
    Where-Object { $_.catalog.displayName -eq $CatalogName })
if ($pkgs.Count -ne 1) { throw "Package '$Package' : $($pkgs.Count) found in '$CatalogName' (expected 1)." }
$pkg = $pkgs[0]
$pol = @($pkg.assignmentPolicies)
if ($pol.Count -ne 1) { throw "Package '$Package' has $($pol.Count) policies (expected 1)." }

Say ("Admin direct assignment, {0} UTC" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm"))
Say ("Person:        {0} {1} | {2} | {3} | enabled {4}" -f $EmployeeId, $u.displayName, $u.jobTitle, $u.officeLocation, $u.accountEnabled)
Say ("Package:       {0}" -f $Package)
Say ("Justification: {0}" -f $Justification)

$body = [ordered]@{
    requestType   = "adminAdd"
    justification = $Justification
    assignment    = [ordered]@{ targetId = $u.id; assignmentPolicyId = $pol[0].id; accessPackageId = $pkg.id }
}
try {
    $req = Invoke-MgGraphRequest -Method POST -Uri "$em/assignmentRequests" -Body ($body | ConvertTo-Json -Depth 5) -ContentType "application/json"
} catch {
    # Graph rejects some requests outright (for example SoD) instead of creating a request
    $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    $code = if ($msg -match '"code"\s*:\s*"([^"]+)"') { $Matches[1] } else { "" }
    $text = if ($msg -match '"message"\s*:\s*"([^"]+)"') { $Matches[1] } else { $msg }
    Say ("Result:        REJECTED by Entra when submitted. {0}{1}" -f $(if ($code) { "[$code] " } else { "" }), $text)
    $state = "rejected"
}
if ($req) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        Start-Sleep -Seconds 5
        $req = Invoke-MgGraphRequest GET "$em/assignmentRequests/$($req.id)?`$expand=assignment"
        $state = $req.state
    } while ($state -notin @("delivered", "denied", "deliveryFailed", "canceled", "pendingApproval") -and (Get-Date) -lt $deadline)
    Say ("Request:       state {0}, status {1}" -f $req.state, $req.status)
    if ($state -eq "delivered") {
        $a = Invoke-MgGraphRequest GET "$em/assignments/$($req.assignment.id)"
        $end = $a.schedule.expiration.endDateTime
        Say ("Assignment:    {0}, expires {1}" -f $a.state, $(if ($end) { ([datetime]$end).ToUniversalTime().ToString("yyyy-MM-dd HH:mm") + "Z" } else { "NEVER (check the policy)" }))
    } elseif ($state -notin @("denied", "deliveryFailed", "canceled", "pendingApproval")) {
        Say "Still processing after $WaitSeconds s. Check Requests on the package in the portal, or rerun -Verify in a few minutes."
    }
}
if ($EvidenceDir) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $out = Join-Path $EvidenceDir ("request_{0}_{1}_{2}.txt" -f $EmployeeId, ($Package -split ' ')[0], (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd_HHmm"))
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Host "Saved: $out"
}
