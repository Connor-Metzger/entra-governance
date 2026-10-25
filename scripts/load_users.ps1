<#
.SYNOPSIS
    Loads the HR feed into Entra ID (Keystone Fuel & Market lab).

.DESCRIPTION
    HR is the authoritative source. Matching key is employeeId (never changes), not UPN.
    Safe to rerun: existing users are updated, not duplicated.

    Lifecycle rules (M1.3):
      - Active rows are created or updated.
      - Future hires (hire date/time still ahead) are CREATED DISABLED. The day-one
        Lifecycle Workflow enables them, so birthright groups (which require
        accountEnabled = true) don't grant access before the first shift.
      - accountEnabled is set ONLY when an account is created. Updates never touch it,
        so this sync can't re-enable a leaver that a workflow disabled.
      - termination_date in HR -> employeeLeaveDateTime in Entra (the leaver workflow
        trigger). Removed in HR (rescinded resignation) -> cleared in Entra.
      - Terminated rows update an EXISTING account (so the leave date reaches Entra) but
        never create one.
      - HR dates are local store dates. They're converted to UTC at a set local time:
        hire = early morning (workflows never run before the timestamp), leave = late
        evening (don't cut off a closing shift).

    Pass 1 creates/updates users. Pass 2 links managers and logs data-quality problems.

.EXAMPLE
    .\scripts\load_users.ps1 -DryRun                              # report only; changes nothing
    .\scripts\load_users.ps1                                      # load data/t0
    .\scripts\load_users.ps1 -HrFile exports\hr_m13_joiner.csv    # load a simulated HR change
#>
[CmdletBinding()]
param(
    [string]$HrFile        = "data/t0/hr_feed.csv",
    [string]$SourceDomain  = "kqm-lab.example",
    [string]$TenantDomain  = "keystonefuellab.onmicrosoft.com",
    [string]$ReportDir     = "exports",
    [string]$TimeZoneId    = "Eastern Standard Time",   # Windows ID; covers EST and EDT
    [string]$HireTimeLocal = "03:00",
    [string]$LeaveTimeLocal = "23:00",
    [int]$CatchUpDays      = 3,                          # Lifecycle Workflows catch-up window
    [switch]$SkipMail,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$tz     = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
$nowUtc = [DateTime]::UtcNow

function New-RandomPassword {
    # Random 24+ char password nobody knows. Joiners sign in with the Temporary Access
    # Pass from the pre-hire workflow instead.
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) + "Kf9!"
}

function ConvertTo-UtcFromLocal([string]$Date, [string]$Time) {
    # "2026-10-31" + "03:00" in Eastern time -> UTC DateTime (DST-aware)
    $local = [DateTime]::ParseExact("$Date $Time", "yyyy-MM-dd HH:mm",
        [Globalization.CultureInfo]::InvariantCulture)
    return [TimeZoneInfo]::ConvertTimeToUtc($local, $tz)
}

function Format-Utc([DateTime]$d) { $d.ToString("yyyy-MM-ddTHH:mm:ssZ") }

# ---------- 1. Read HR ----------
$hr = @(Import-Csv -Path $HrFile -Encoding UTF8)
$activeIds = @{}
foreach ($row in $hr) { if ($row.status -eq "Active") { $activeIds[$row.employee_id] = $true } }
$inScope = @($hr | Where-Object { $_.status -in @("Active", "Terminated") })

Write-Host ("HR rows: {0} | Active: {1} | Terminated: {2} (updated only if already in Entra)" -f `
    $hr.Count, $activeIds.Count, @($hr | Where-Object status -eq "Terminated").Count)

# ---------- 2. Build target attributes + lifecycle stage ----------
$plan = foreach ($row in $inScope) {
    $local = ($row.upn -split "@")[0]
    if (-not $row.upn.EndsWith("@$SourceDomain")) { throw "Unexpected UPN domain: $($row.upn)" }
    $upn     = "$local@$TenantDomain"
    $hireUtc = ConvertTo-UtcFromLocal $row.hire_date $HireTimeLocal
    $leaveUtc = $null
    if (-not [string]::IsNullOrWhiteSpace($row.termination_date)) {
        $leaveUtc = ConvertTo-UtcFromLocal $row.termination_date $LeaveTimeLocal
    }

    # Lifecycle stage, so the report says which workflow should pick this person up
    $stage = "Active"
    if ($row.status -eq "Terminated" -and -not $leaveUtc) { $stage = "TerminatedNoDate" }
    elseif ($leaveUtc -and $leaveUtc -ge $nowUtc)          { $stage = "LeaverScheduled" }
    elseif ($leaveUtc -and $leaveUtc -ge $nowUtc.AddDays(-$CatchUpDays)) { $stage = "LeaverInWindow" }
    elseif ($leaveUtc)                                     { $stage = "LeaverMissedWindow" }
    elseif ($hireUtc -gt $nowUtc)                          { $stage = "PreHire" }

    $body = [ordered]@{
        displayName       = "$($row.first_name) $($row.last_name)"
        givenName         = $row.first_name
        surname           = $row.last_name
        userPrincipalName = $upn
        mailNickname      = $local
        employeeId        = $row.employee_id
        department        = $row.department
        jobTitle          = $row.job_title
        officeLocation    = $row.location
        employeeType      = $row.employment_type
        employeeHireDate  = Format-Utc $hireUtc
        companyName       = "Keystone Fuel & Market"
        usageLocation     = "US"
    }
    # Workflow emails go to the manager's mail attribute, so every user needs one
    if (-not $SkipMail) { $body.mail = $upn }
    if ($leaveUtc) { $body.employeeLeaveDateTime = Format-Utc $leaveUtc }

    [pscustomobject]@{
        EmployeeId = $row.employee_id
        ManagerId  = $row.manager_id
        HrStatus   = $row.status
        Stage      = $stage
        HireUtc    = $hireUtc
        LeaveUtc   = $leaveUtc
        Body       = $body
    }
}

# Manager data quality (works offline, so -DryRun shows it too)
$mgrStatus = @{}
foreach ($p in $plan) {
    if ([string]::IsNullOrWhiteSpace($p.ManagerId))    { $mgrStatus[$p.EmployeeId] = "NoManager" }
    elseif (-not $activeIds.ContainsKey($p.ManagerId)) { $mgrStatus[$p.EmployeeId] = "ManagerTerminated" }
    else { $mgrStatus[$p.EmployeeId] = "ToLink" }
}
$activePlan = @($plan | Where-Object HrStatus -eq "Active")
Write-Host ("Manager links to set: {0} | No manager in HR: {1} | Manager terminated in HR: {2}  (active rows)" -f `
    @($activePlan | Where-Object { $mgrStatus[$_.EmployeeId] -eq "ToLink" }).Count,
    @($activePlan | Where-Object { $mgrStatus[$_.EmployeeId] -eq "NoManager" }).Count,
    @($activePlan | Where-Object { $mgrStatus[$_.EmployeeId] -eq "ManagerTerminated" }).Count)

Write-Host "Lifecycle stage (from HR dates, now = $(Format-Utc $nowUtc)):"
$plan | Group-Object Stage | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-20} {1}" -f $_.Name, $_.Count)
}
$plan | Where-Object Stage -ne "Active" | Where-Object { $_.HrStatus -eq "Active" -or $_.LeaveUtc -ge $nowUtc.AddDays(-30) } |
    ForEach-Object {
        Write-Host ("  -> {0} {1,-20} {2,-18} hire {3}  leave {4}" -f $_.EmployeeId, $_.Body.displayName, $_.Stage,
            (Format-Utc $_.HireUtc), $(if ($_.LeaveUtc) { Format-Utc $_.LeaveUtc } else { "-" }))
    }

if ($DryRun) {
    Write-Host "DRY RUN - nothing changed. Sample of first user:"
    $plan[0].Body.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Key, $_.Value) }
    return
}

# ---------- 3. Pass 1: create or update users ----------
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

Write-Host "Reading existing users from the tenant..."
$existing = @{}; $existingLeave = @{}
Get-MgUser -All -Property "id,userPrincipalName,employeeId,employeeLeaveDateTime" | ForEach-Object {
    if ($_.EmployeeId) {
        $existing[$_.EmployeeId] = $_.Id
        $existingLeave[$_.EmployeeId] = $_.EmployeeLeaveDateTime
    }
}
Write-Host ("Existing users with an employeeId: {0}" -f $existing.Count)

$report = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($p in $plan) {
    $i++
    Write-Progress -Activity "Pass 1: users" -Status $p.Body.userPrincipalName -PercentComplete ($i / $plan.Count * 100)
    $action = ""; $detail = ""; $enabledOnCreate = ""
    try {
        if ($existing.ContainsKey($p.EmployeeId)) {
            $body = [ordered]@{}
            foreach ($k in $p.Body.Keys) { $body[$k] = $p.Body[$k] }
            # Leave date removed in HR (rescinded resignation) -> clear it so no leaver workflow fires
            if (-not $p.LeaveUtc -and $existingLeave[$p.EmployeeId]) {
                $body.employeeLeaveDateTime = $null
                $detail = "Leave date cleared (removed in HR)"
            }
            Update-MgUser -UserId $existing[$p.EmployeeId] -BodyParameter $body
            $action = "Updated"
        } elseif ($p.HrStatus -eq "Terminated") {
            $action = "NotLoaded"   # never create an account for someone who already left
        } else {
            $body = [ordered]@{}
            foreach ($k in $p.Body.Keys) { $body[$k] = $p.Body[$k] }
            $body.accountEnabled  = ($p.HireUtc -le $nowUtc)   # future hire -> disabled until day one
            $enabledOnCreate = $body.accountEnabled
            $body.passwordProfile = @{ password = (New-RandomPassword); forceChangePasswordNextSignIn = $true }
            $new = New-MgUser -BodyParameter $body
            $existing[$p.EmployeeId] = $new.Id
            $action = "Created"
        }
    } catch {
        $action = "Failed"; $detail = $_.Exception.Message
    }
    if ($p.Stage -eq "LeaverMissedWindow" -and $action -eq "Updated") {
        $detail = "Leave date is more than $CatchUpDays days ago: scheduled leaver workflow will NOT pick this up. Run real-time termination on demand."
    }
    $report.Add([pscustomobject]@{
        employee_id = $p.EmployeeId; upn = $p.Body.userPrincipalName
        hr_status = $p.HrStatus; stage = $p.Stage
        hire_utc = Format-Utc $p.HireUtc
        leave_utc = $(if ($p.LeaveUtc) { Format-Utc $p.LeaveUtc } else { "" })
        user_action = $action; enabled_on_create = $enabledOnCreate
        manager_id = $p.ManagerId; manager_status = $mgrStatus[$p.EmployeeId]; detail = $detail
    })
}
Write-Progress -Activity "Pass 1: users" -Completed

# ---------- 4. Pass 2: link managers ----------
$i = 0
foreach ($r in $report) {
    $i++
    Write-Progress -Activity "Pass 2: managers" -Status $r.upn -PercentComplete ($i / $report.Count * 100)
    if ($r.manager_status -ne "ToLink" -or $r.user_action -notin @("Created", "Updated")) { continue }
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
$report | Where-Object user_action -in @("Created", "Updated") | Group-Object manager_status | Sort-Object Name |
    ForEach-Object { Write-Host ("Manager {0,-18} {1}" -f $_.Name, $_.Count) }
$report | Where-Object user_action -eq "Created" | ForEach-Object {
    Write-Host ("Created {0} {1} enabled={2} stage={3}" -f $_.employee_id, $_.upn, $_.enabled_on_create, $_.stage)
}
$report | Where-Object { $_.detail } | ForEach-Object { Write-Host ("Note    {0}: {1}" -f $_.employee_id, $_.detail) }
Write-Host "Report: $outFile"
