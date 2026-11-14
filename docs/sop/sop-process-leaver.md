# SOP: Process a leaver

| Field | Value |
|---|---|
| SOP ID | IAM-SOP-001 |
| Version | 1.0 |
| Owner | IAM Governance |
| Last reviewed | 2026-11-13 |
| Related policy | IAM Access Control Policy §4 (joiners, movers, leavers), §9 (individual accounts) |
| Framework controls | PCI DSS 8.2.5; NIST SP 800-53 AC-2, AC-2(3), PS-4; CIS Controls v8 6.2 |

*Built in a lab environment (Microsoft Entra ID Governance). Worked example: E00010 Logan Nguyen, `evidence/M1.3/`.*

## Purpose
Make sure a person who leaves Keystone loses all access by the end of their last day, and that we can prove it. A leaver who keeps access to the POS, the cash office or StoreOps Portal is a PCI DSS 8.2.5 failure and a theft risk.

## Scope
- **Path A, planned leaver** (resignation, end of contract): the automatic workflow does the work and IAM checks it.
- **Path B, involuntary termination** (dismissal, walked off site): IAM disables the account **immediately** on request, without waiting for the workflow.
- Every account sourced from HR (employee ID present). Admin and break-glass accounts are out of scope; they have their own procedure.

## Roles
| Role | Responsibility |
|---|---|
| HR | Enters the termination with the last day **by the end of the employee's last shift** (policy §4). For Path B, calls the IAM desk |
| Manager | Tells HR the same day; collects badges and devices; never asks IAM to keep the account open "for a few days" |
| IAM analyst | Path A: checks the result the next morning. Path B: disables now, then checks |
| Escalation | IAM engineering (workflow failed, account can't be disabled); Security Operations (suspected theft or misuse, activity after the leave time) |

## Prerequisites
- Ticket from HR (Path A: the nightly HR load report; Path B: a phone call confirmed by calling HR back on the number in the HR directory, never the number the caller gives).
- IAM admin access to Microsoft Entra admin center and PowerShell 7 with Microsoft Graph (`scripts/show_person_access.ps1`).

## Procedure

### Path A: planned leaver
1. **HR enters the termination.** The nightly load (`scripts/load_users.ps1`) sets the leave date and time: last day, 23:00 ET, stored in UTC. *Expected: the load report lists the person under `LeaverScheduled`.*
2. **JML-L1 "Last day offboard" runs** at the first hourly run after 23:00 ET on the last day: disables the account, revokes sign-in sessions, removes all access packages, groups and Teams. *Expected: Workflow history shows the person with 5 of 5 tasks completed.*
3. **Next business morning, IAM checks the run.** Entra admin center → ID Governance → Lifecycle workflows → JML-L1 → Workflow history → Users. *Expected: status Completed and **0 failed tasks**. A status of "Completed with errors" is a failure: go to step 6.*
4. **IAM checks the person, not just the run.**
   ```powershell
   .\scripts\show_person_access.ps1 -EmployeeId E00010 -EvidenceDir evidence/<ticket> -Label after-l1
   ```
   *Expected: enabled False; no birthright groups, no access packages, no ENT groups, no StoreOps roles.*
5. **Seven days later, JML-L2** removes licenses and deletes the account. It can be restored for 30 days if HR made a mistake. *Expected: the person appears under Deleted users (Logan: deleted 2026-11-02 22:37 ET, `evidence/M1.3/10-logan-deleted-users.png`).*
6. **If any task failed:** do that task by hand now (disable, revoke sessions, remove the package or group), record it in the ticket, and raise an incident for IAM engineering. Workflow failures are not alerted today (trend report G3), so this morning check is the control.

### Path B: involuntary termination ("disable now")
1. **Confirm the request.** Call HR back on the HR directory number. Record who asked and when. *Expected: HR confirms the employee ID and that the termination is effective now.*
2. **Disable the account.** Entra admin center → Users → the person → **Edit properties** → Settings → clear **Account enabled** → Save. *Expected: the user shows "Account enabled: No".*
3. **Revoke sessions.** Same user → **Revoke sessions** → Yes. *Expected: confirmation banner. Existing sign-ins to Microsoft 365 and connected apps must sign in again, and can't.*
4. **Remove payment card and admin access now.** ID Governance → Entitlement management → Access packages → ADD-06 StoreOps Cash Office (and ADD-07 if held) → Assignments → select the person → **Remove access**. *Expected: assignment state Expired within a few minutes.*
5. **Check the person.** Run `show_person_access.ps1` as in Path A step 4. Birthright groups drop on their own once the account is disabled (the rules require an enabled account). *Expected: enabled False, no Cash Office or Admin.*
6. **HR enters the termination the same day.** The nightly load will not re-enable the account (it sets "enabled" only when it creates a new account). JML-L1 then does the rest on the leave date.
7. **Store manager follow-up:** collect the badge and keys, and have the cash office count done by another authorised person. If the person may have misused access, **escalate to Security Operations** before anything else is changed, so evidence isn't lost.

## Exceptions and escalation
- **Never re-enable a leaver's account**, including for a pay stub, a tax form or "to forward their email". HR provides documents; the manager asks IAM for a mailbox delegation if needed. A rehire goes through the joiner process.
- **Workflow failed or the account can't be disabled** → IAM engineering, within 1 hour (24/7: on-call).
- **Sign-in activity after the leave time** or suspected theft → Security Operations immediately, then the IT Director.
- **HR entered the termination late** (after the last shift) → record the exposure (hours between leave time and HR entry) in the ticket and report it monthly (trend report G2).

## Evidence and records
Kept with the ticket for at least 12 months (PCI DSS audit trail):
- HR termination record or confirmed call (Path B: who, when, call-back number).
- Workflow history screenshot or run export showing tasks completed and failed.
- `show_person_access` output after the change (names only, no object IDs).
- Exposure: leave time vs time disabled. Logan: leave 2026-10-26 23:00 ET, disabled 2026-10-27 10:38 ET = 11.6 h, because HR entered the termination the next morning.

## Revision history
| Version | Date | Change | Author |
|---|---|---|---|
| 1.0 | 2026-11-13 | First version; Path B added for policy §4 and trend report G2 | IAM Governance |
