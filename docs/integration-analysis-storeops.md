# Integration analysis: StoreOps Portal

> **To:** Senior IAM Engineer · **From:** IAM Governance (lab) · **Date:** 2026-10-28 · **Status:** Draft for technical review
> **Decision needed:** approve the provisioning method (section 4) and the PCI scoping approach (section 7) before StoreOps Portal access packages are built in M2.4–M2.5.

## 1. Summary

StoreOps Portal is the store-level web app for schedules, timeclock, shift handover, inventory approval, safe counts and the cash-office settlement reports. It is registered in Entra ID as an enterprise app with five app roles. **Assignment required** is on, so no one can sign in without a role. Today one role is assigned: **Associate → BR-02 Store Operations Baseline**, which gives **156 people** access automatically from their HR department (158 after Avery and Riley start on 2026-10-31). The other four roles are defined but unassigned on purpose. Shift Lead and Store Manager will come from job-title access packages (M2.4). Cash Office (PCI) and Admin will only be granted through *requested* access packages with approval and quarterly review (M2.5).

Three things need a senior decision: (1) SSO-only vs. SSO + SCIM provisioning, (2) whether the whole app or only the Cash Office function is in PCI scope, which decides the review cadence, and (3) how the app limits each person to their own store.

## 2. App at a glance

| Item | Value |
|---|---|
| App | StoreOps Portal (fictional; registration only, no app behind it in the lab) |
| Users | Store Operations: 156 enabled today, across 40 stores (plus 1 at Corporate) |
| Business owner | Director of Store Operations (role in the role catalog; **no named person yet**, see R3) |
| Technical owner | IAM Team (Entra app owner = can change configuration) |
| Sign-in | Entra ID SSO (OIDC); app roles sent in the `roles` claim |
| Access gate | Assignment required = Yes |
| Data | Schedules, timeclock punches, inventory, safe counts, card settlement and deposit reconciliation (Cash Office) |
| Build script | `scripts/register_storeops_app.ps1` (idempotent; `-Verify` reads the config back) |

## 3. Authoritative source and attribute mapping

HR is the only source of truth. `load_users.ps1` writes HR into Entra; Entra passes it to the app. The app must never become a second place where store or title is maintained.

| HR feed | Entra attribute | App receives (claim / SCIM) | Used for |
|---|---|---|---|
| employee_id | employeeId | `externalId` | Immutable match key. UPNs change on name changes; employee IDs don't |
| upn | userPrincipalName | `preferred_username` / `userName` | Sign-in name |
| first_name, last_name | givenName, surname | `given_name`, `family_name` | Display |
| department | department | (drives group BR-02) | Who gets Associate |
| job_title | jobTitle | (drives M2.4 packages) | Who gets Shift Lead / Store Manager |
| location | officeLocation | custom claim `store` | **Store scoping**: which store's data a person sees |
| status, termination_date | accountEnabled, employeeLeaveDateTime | `active` (SCIM) | Leaver: L1 disables at 23:00 ET on the last day |

## 4. Provisioning method

| Option | How it works | Leaver handling | Verdict |
|---|---|---|---|
| A. SSO only | App trusts the token; creates its local profile on first sign-in | Disabled Entra account can't get a new token, but the app-side profile and any open session stay until the session times out | Acceptable for the Associate role only |
| B. SSO + SCIM | Entra provisioning creates, updates and deactivates app accounts from the same assignments | App account deactivated on the next provisioning cycle after L1 disables the user | **Recommended** |
| C. CSV / manual | Store admin adds people in the app | Depends on someone remembering | Rejected: this is the pattern that created 107 grants of mover drift (role catalog item 6.3) |

Option B needs the vendor to support SCIM 2.0. If they don't, Option A plus a short app session lifetime (≤ 8 h, so one shift) is the fallback, with the gap recorded as an exception.

## 5. Role design

App roles mirror the role catalog, so a role means the same thing in every system.

| App role | Value | Catalog source | Granted by | Expected users | Review |
|---|---|---|---|---|---|
| Associate | StoreOps.Associate | BR-02 | Group BR-02 (dynamic, department = Store Operations) | 156 (158 from 10-31) | Annual (BR-02), see R2 |
| Shift Lead | StoreOps.ShiftLead | BUS-01 + ADD-01 | Access package, automatic by title (M2.4) | 60 | Semiannual |
| Store Manager | StoreOps.StoreManager | BUS-02 (PCI-flagged) | Access package, automatic by title (M2.4) | 52 | Semiannual |
| Cash Office (PCI) | StoreOps.CashOffice | ADD-02 pattern | **Requested** package: manager + PCI owner (M2.5) | 0 until requested | Quarterly |
| Admin | StoreOps.Admin | Privileged | **Requested** package: IT Director (M2.5) | 0 until requested | Quarterly |

Design rules:
- **Groups only, no direct user assignments.** `-Verify` fails if anyone is assigned directly. Every grant must trace to HR data or an approved request.
- **No nested groups.** Entra app assignment doesn't pass through nested group membership, so BR-02 is assigned directly.
- **Layered, like the catalog.** A Store Manager holds Associate (from BR-02) plus Store Manager (from the package). The app must combine role claims, not expect exactly one.
- **Title rules must also check department.** Rowan Kowalski (E00004) moved to Fuel Operations, but HR still lists his title as *Store Associate*. A rule on title alone would keep store access for someone who left the stores. The M2.4 packages will use department + title.

## 6. Ownership

- **Business owner (Director of Store Operations):** decides who should have access, approves the role design, signs off reviews. Recorded in the enterprise app's Notes field.
- **Technical owner (IAM Team):** configuration, assignments, provisioning and evidence. Entra "Owners" can change the app's configuration, so business owners are **not** added as Entra owners.
- **PCI owner:** second approver for Cash Office; confirms the PCI scope in section 7.

## 7. PCI DSS scope

The Cash Office function shows card settlement and deposit reconciliation, so it is at least connected to the cardholder data environment. Which requirements apply depends on whether the PCI owner scopes **the whole app** or **only the Cash Office function**:

| Requirement (PCI DSS v4.0) | What it means for StoreOps |
|---|---|
| 7.2.1–7.2.2 | Access defined by job function with least privilege: covered by the role table in section 5 |
| 7.2.4 | All user accounts in scope reviewed **at least every six months** |
| 8.2.5 | Leavers' access revoked immediately: L1 at 23:00 ET on the last day; SCIM deactivates the app account |
| 8.4.2 | MFA for all access into the CDE: Conditional Access policy for the Cash Office role (M6 / production) |
| 10.2 | Audit logs for access to cardholder data: app-side requirement for the vendor |

If the whole app is in scope, the Associate role's annual review (inherited from BR-02) **does not meet 7.2.4**. See R2.

## 8. Risks and open questions

| # | Risk | Impact | Proposed handling | Owner |
|---|---|---|---|---|
| R1 | Store scoping depends on `officeLocation` from HR. HR data quality is weak: 16 enabled Store Operations staff have no manager, 9 of 40 stores have no Store Manager, and one store has four | Wrong store data shown, or Cash Office requests with no store manager to approve | App enforces the `store` claim; HR fixes the data at source (open item 7.1); requests with no manager route to the Director | HR, vendor |
| R2 | Annual BR-02 review vs. PCI 7.2.4 six-month review | Audit finding if the whole app is in PCI scope | Preferred: scope only Cash Office into PCI. Otherwise review all StoreOps roles semiannually | PCI owner |
| R3 | Business owner is a role title, not a named person | No one accountable to approve the design or sign reviews | Name the Director before M3 reviews start | Store Operations |
| R4 | SSO only leaves app-side accounts and sessions after a leaver is disabled | Former employee's session works until timeout | SCIM (Option B), or ≤ 8 h session lifetime | Vendor, IAM |
| R5 | Group-based assignment needs Entra ID P1 for every assigned user | Licensing cost for 156+ store users | Include in the licensing plan (lab has 1 P1 seat: lab deviation) | IT |
| R6 | Movers keep title-based roles until the package removes them | Store access after leaving stores | Department + title rules; PCI packages remove access on day 0 (open item 7.4) | IAM |

## 9. Recommendation

Approve SSO + SCIM provisioning (Option B) for StoreOps Portal, with the Associate role granted only through group BR-02 and every other role through access packages. Scope only the Cash Office function into PCI and give it quarterly reviews, two-person approval and MFA. That keeps the Associate role, held by 156 people, on its annual cycle, and puts the heaviest review effort on the few people approved to see card settlement data. Before the M3 access reviews, the Director of Store Operations must be named as the business owner, and HR must fix missing store managers at the source, not in Entra.

## 10. Lab deviations and evidence

- No real app sits behind the registration, so there are no sign-ins, tokens or SCIM runs. Evidence is the configuration read back from Graph.
- Group assignment uses the lab's single P1 seat; production would license every assigned user.

| Evidence | Shows |
|---|---|
| `evidence/M1.4/storeops_app_config.txt` | Graph read-back: 5 roles, assignment required, BR-02 → Associate (156 users), 7 of 7 checks passed |
| `01-storeops-app-roles.png` | App registration → App roles (5 roles) |
| `02-storeops-properties.png` | Enterprise app → Properties: Assignment required = Yes |
| `03-storeops-users-groups.png` | Enterprise app → Users and groups: BR-02 → Associate only |

Sources: Microsoft Learn, [Manage users and groups assignment to an application](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/assign-user-or-group-access-portal) (P1 for group assignment; nested groups not supported).
