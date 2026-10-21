<#
.SYNOPSIS
    Exports a point-in-time snapshot of HR-sourced users (with manager) from Entra ID.

.DESCRIPTION
    Raw export goes to exports/ (gitignored: contains object IDs).
    A sanitized copy (no object IDs) goes to evidence/<module>/ for the repo.

.EXAMPLE
    .\scripts\export_snapshot.ps1 -Label T0 -EvidenceDir evidence/M1.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Label,
    [string]$ExportDir   = "exports",
    [string]$EvidenceDir = ""
)
$ErrorActionPreference = "Stop"
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

$props = "id,displayName,userPrincipalName,employeeId,department,jobTitle,officeLocation," +
         "employeeType,employeeHireDate,accountEnabled,createdDateTime"
$users = @(Get-MgUser -All -Property $props -ExpandProperty manager)

$idToEmp = @{}
foreach ($u in $users) { $idToEmp[$u.Id] = $u.EmployeeId }

$rows = foreach ($u in $users | Where-Object { $_.EmployeeId } | Sort-Object EmployeeId) {
    $mgrEmp = $null
    if ($u.Manager -and $u.Manager.Id) { $mgrEmp = $idToEmp[$u.Manager.Id] }
    [pscustomobject]@{
        object_id           = $u.Id
        employee_id         = $u.EmployeeId
        upn                 = $u.UserPrincipalName
        display_name        = $u.DisplayName
        department          = $u.Department
        job_title           = $u.JobTitle
        office_location     = $u.OfficeLocation
        employee_type       = $u.EmployeeType
        hire_date           = if ($u.EmployeeHireDate) { ([datetime]$u.EmployeeHireDate).ToUniversalTime().ToString("yyyy-MM-dd") } else { "" }
        account_enabled     = $u.AccountEnabled
        manager_employee_id = $mgrEmp
    }
}

$date = Get-Date -Format "yyyy-MM-dd"
New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
$raw = Join-Path $ExportDir "snapshot_${Label}_$date.csv"
$rows | Export-Csv -Path $raw -NoTypeInformation -Encoding UTF8
Write-Host ("Users in tenant: {0} | HR-sourced (have employeeId): {1}" -f $users.Count, @($rows).Count)
Write-Host "Raw snapshot:       $raw"

if ($EvidenceDir) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $clean = Join-Path $EvidenceDir "snapshot_${Label}_${date}_sanitized.csv"
    $rows | Select-Object * -ExcludeProperty object_id | Export-Csv -Path $clean -NoTypeInformation -Encoding UTF8
    Write-Host "Sanitized evidence: $clean"
}
