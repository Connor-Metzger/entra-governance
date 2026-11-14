# SOP: Onboard an application to identity governance

| Field | Value |
|---|---|
| SOP ID | IAM-SOP-002 |
| Version | 1.0 |
| Owner | IAM Governance |
| Last reviewed | 2026-11-13 |
| Related policy | IAM Access Control Policy §2 (owners), §3 (three layers), §5 (SoD), §6 (reviews) |
| Framework controls | PCI DSS 7.2.1–7.2.4, 12.5.2 (scope); NIST SP 800-53 AC-2, AC-5, AC-6; CIS Controls v8 6.1, 6.8 |

*Built in a lab environment (Microsoft Entra ID Governance). Worked example: StoreOps Portal, `docs/integration-analysis-storeops.md`, `evidence/M1.4/`, `evidence/M2.4/`, `evidence/M2.5/`.*

## Purpose
Bring a new application under Keystone's access rules before anyone uses it: every user gets access through a role, sensitive access is requested and expires, a named business owner decides, and reviews and leavers cover it from day one.

## Scope
Any application that signs in through Microsoft Entra ID (SAML, OpenID Connect or SCIM). Applications with their own logins are out of scope until they are connected; until then they are listed as an exception.

## Roles
| Role | Responsibility |
|---|---|
| Requester (project or app team) | Asks for onboarding; describes the app's roles and data |
| Business owner (e.g. Director of Store Operations) | Decides who should have each role; approves the role design; signs off reviews |
| PCI owner | Confirms whether the app is in PCI scope and approves PCI roles |
| IAM analyst | Builds and verifies the configuration; keeps the evidence |
| Escalation | IT Director (no business owner named, or the app can't enforce roles) |

## Prerequisites
- A named business owner (a person, not a team). **No owner, no onboarding.**
- The app's roles and what each one can do, and whether any role touches card data.
- IAM admin access; scripts in `scripts/`.

## Procedure
1. **Intake and data check.** Write a one-page analysis: what HR attribute decides each role, provisioning method, owner, PCI scope, review cadence, risks. *Expected: an approved memo. StoreOps: `docs/integration-analysis-storeops.md` found 16 Store Ops staff with no manager and 9 stores with no Store Manager before anything was built.*
2. **Register the app with roles and "assignment required".** Each role in the app becomes an app role; nobody gets in without an assignment. The business owner is recorded in the app's Notes field and is **not** made an Entra owner (Entra owners can change the configuration).
   ```powershell
   .\scripts\register_storeops_app.ps1 -Verify -EvidenceDir evidence/M1.4
   ```
   *Expected: 7/7 checks PASS: 5 roles, assignment required, owner in Notes.*
3. **Map each role to a layer** (policy §3):
   - **Everyone in a department** → assign the role to the birthright group. StoreOps: Associate → BR-02 Store Operations Baseline (156 people at the time).
   - **Everyone with a job title** → add the role to the title's access package. StoreOps: Store Manager → BUS-02, Shift Lead → ADD-01.
   - **Sensitive or admin** → a requested package with approval, justification and expiry. StoreOps: Cash Office → ADD-06 (manager + PCI owner, 90 days); Admin → ADD-07 (IT Director, 30 days).
   *Expected: no role is assigned to a person directly.*
4. **Add separation of duties.** List roles that must never be held together and mark the packages incompatible. StoreOps: Cash Office ADD-06 ↔ POS Refunds ADD-01. *Expected: a test request from someone holding the other package is blocked (Alex Larsen: `InvalidRequestSODCheck`, `evidence/M2.5/request_E00013_ADD-06_*.txt`).*
5. **Verify configuration as data, then verify people.**
   ```powershell
   .\scripts\create_access_packages.ps1 -HrFile <current HR file> -Verify -EvidenceDir evidence/M2.4
   .\scripts\create_requested_packages.ps1 -Verify -EvidenceDir evidence/M2.5
   ```
   *Expected: 33/33 and 12/12. Every check compares people by employee ID with HR, and a check that finds 0 people counts as a failure, not a pass.*
6. **Connect lifecycle and reviews.** Confirm the leaver workflow removes the app's packages (JML-L1), the mover workflow removes PCI and admin roles at once (JML-M2), and the app's sensitive roles are in the quarterly review (policy §6). *Expected: the app appears in the review scope list in `docs/certification-campaign-design.md`.*
7. **Test one person end to end** before go-live: grant, check, remove, check.
   ```powershell
   .\scripts\show_person_access.ps1 -EmployeeId <test person> -EvidenceDir evidence/<app> -Label before
   ```
   *Expected: the role appears after the grant and disappears after removal.*
8. **Hand over.** Send the business owner a one-page summary: roles, who gets each one, how to request, review dates, and their decisions. Record open risks in the gap register (policy §13).

## Exceptions and escalation
- **No named business owner** → stop and escalate to the IT Director. StoreOps went live with the Director of Store Operations as a role, not a named person: a documented open risk (integration analysis R3).
- **App can't enforce roles** (one role for everyone) → treat the whole app as its most sensitive role, or escalate for a compensating control.
- **App in PCI scope** → the PCI owner approves the role design before go-live; reviews at least every 6 months (quarterly at Keystone).

## Evidence and records
- Integration analysis memo and business owner approval.
- `-Verify` outputs (configuration and assignments) with date and time in the file name.
- SoD test result and end-to-end test (`show_person_access` before and after).
- All outputs sanitized: names and employee IDs only, no object or tenant IDs.

## Revision history
| Version | Date | Change | Author |
|---|---|---|---|
| 1.0 | 2026-11-13 | First version, from the StoreOps Portal onboarding (M1.4–M2.5) | IAM Governance |
