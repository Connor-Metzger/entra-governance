<#
.SYNOPSIS
    Loads active employees from the HR feed into Entra ID (Keystone Fuel & Market lab).

.DESCRIPTION
    HR is the authoritative source: only rows with status = Active become accounts.
    Matching key is employeeId (never changes), not UPN (changes when a name changes).
    Safe to rerun: existing users are updated, not duplicated.

    Pass 1 creates/updates users and sets HR attributes.
    Pass 2 links each user to their manager, and logs data-quality problems
    (manager terminated in HR, or no manager) instead of failing silently.

.EXAMPLE
    .\scripts\load_users.ps1 -DryRun     # read the HR file and report; changes nothing
    .\scripts\load_users.ps1             # load into the connected tenant
#>
[CmdletBinding()]
param(
    [string]$HrFile       = "data/t0/hr_feed.csv",
    [string]$SourceDomain = "kqm-lab.example",
    [string]$TenantDomain = "keystonefuellab.onmicrosoft.com",
    [string]$ReportDir    = "exports",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function New-RandomPassword {
    # Random 24+ char password. Synthetic users never sign in; real joiners get a
    # Temporary Access Pass from the joiner workflow (M1.3) instead.
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) + "Kf9!"
}

# ---------- 1. Read HR and keep active employees only ----------
$hr     = Import-Csv -Path $HrFile -Encoding UTF8
$active = @($hr | Where-Object { $_.status -eq "Active" })
$activeIds = @{}
foreach ($row in $active) { $activeIds[$row.employee_id] = $true }

Write-Host ("HR rows: {0} | Active: {1} | Terminated (not loaded): {2}" -f `
    $hr.Count, $active.Count, ($hr.Count - $active.Count))

# ---------- 2. Build the target attributes for each employee ----------
$plan = foreach ($row in $active) {
    $local = ($row.upn -split "@")[0]
    if (-not $row.upn.EndsWith("@$SourceDomain")) { throw "Unexpected UPN domain: $($row.upn)" }
    [pscustomobject]@{
        EmployeeId = $row.employee_id
        ManagerId  = $row.manager_id
        Body       = [ordered]@{
            accountEnabled   = $true
            displayName      = "$($row.first_name) $($row.last_name)"
            givenName        = $row.first_name
            surname          = $row.last_name
            userPrincipalName = "$local@$TenantDomain"
            mailNickname     = $local
            employeeId       = $row.employee_id
            department       = $row.department
            jobTitle         = $row.job_title
            officeLocation   = $row.location
            employeeType     = $row.employment_type
            employeeHireDate = "$($row.hire_date)T00:00:00Z"
            companyName      = "Keystone Fuel & Market"
            usageLocation    = "US"
        }
    }
}

# Manager data quality (works offline, so -DryRun shows it too)
$mgrStatus = @{}
foreach ($p in $plan) {
    if ([string]::IsNullOrWhiteSpace($p.ManagerId))  { $mgrStatus[$p.EmployeeId] = "NoManager" }
    elseif (-not $activeIds.ContainsKey($p.ManagerId)) { $mgrStatus[$p.EmployeeId] = "ManagerTerminated" }
    else { $mgrStatus[$p.EmployeeId] = "ToLink" }
}
$toLink     = @($mgrStatus.Values | Where-Object { $_ -eq "ToLink" }).Count
$noMgr      = @($mgrStatus.Values | Where-Object { $_ -eq "NoManager" }).Count
$termMgr    = @($mgrStatus.Values | Where-Object { $_ -eq "ManagerTerminated" }).Count
Write-Host ("Manager links to set: {0} | No manager in HR: {1} | Manager terminated in HR: {2}" -f $toLink, $noMgr, $termMgr)

if ($DryRun) {
    Write-Host "DRY RUN - nothing changed. Sample of first user:"
    $plan[0].Body.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-18} {1}" -f $_.Key, $_.Value) }
    return
}

# ---------- 3. Pass 1: create or update users ----------
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

Write-Host "Reading existing users from the tenant..."
$existing = @{}
Get-MgUser -All -Property "id,userPrincipalName,employeeId" | ForEach-Object {
    if ($_.EmployeeId) { $existing[$_.EmployeeId] = $_.Id }
}
Write-Host ("Existing users with an employeeId: {0}" -f $existing.Count)

$report = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($p in $plan) {
    $i++
    Write-Progress -Activity "Pass 1: users" -Status $p.Body.userPrincipalName -PercentComplete ($i / $plan.Count * 100)
    $action = ""; $detail = ""
    try {
        if ($existing.ContainsKey($p.EmployeeId)) {
            Update-MgUser -UserId $existing[$p.EmployeeId] -BodyParameter $p.Body
            $action = "Updated"
        } else {
            $body = [ordered]@{}
            foreach ($k in $p.Body.Keys) { $body[$k] = $p.Body[$k] }
            $body.passwordProfile = @{ password = (New-RandomPassword); forceChangePasswordNextSignIn = $true }
            $new = New-MgUser -BodyParameter $body
            $existing[$p.EmployeeId] = $new.Id
            $action = "Created"
        }
    } catch {
        $action = "Failed"; $detail = $_.Exception.Message
    }
    $report.Add([pscustomobject]@{
        employee_id = $p.EmployeeId; upn = $p.Body.userPrincipalName
        user_action = $action; manager_id = $p.ManagerId
        manager_status = $mgrStatus[$p.EmployeeId]; detail = $detail
    })
}
Write-Progress -Activity "Pass 1: users" -Completed

# ---------- 4. Pass 2: link managers ----------
$i = 0
foreach ($r in $report) {
    $i++
    Write-Progress -Activity "Pass 2: managers" -Status $r.upn -PercentComplete ($i / $report.Count * 100)
    if ($r.manager_status -ne "ToLink" -or $r.user_action -eq "Failed") { continue }
    try {
        $ref = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($existing[$r.manager_id])" }
        Set-MgUserManagerByRef -UserId $existing[$r.employee_id] -BodyParameter $ref
        $r.manager_status = "Linked"
    } catch {
        $r.manager_status = "LinkFailed"; $r.detail = $_.Exception.Message
    }
}
Write-Progress -Activity "Pass 2: managers" -Completed

# ---------- 5. Report ----------
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $ReportDir "load_report_$stamp.csv"
$report | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "===== Load summary ====="
$report | Group-Object user_action    | Sort-Object Name | ForEach-Object { Write-Host ("Users   {0,-18} {1}" -f $_.Name, $_.Count) }
$report | Group-Object manager_status | Sort-Object Name | ForEach-Object { Write-Host ("Manager {0,-18} {1}" -f $_.Name, $_.Count) }
Write-Host "Report: $outFile"
