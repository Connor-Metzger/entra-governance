# Title-Based Access Packages — Keystone Fuel & Market

*Modules M2.4–M2.5 · Built in a lab tenant (Microsoft Entra ID Governance trial) · Last updated 2026-11-03*

## 1. Summary

The role catalog (`docs/role-catalog.md`) has three layers. Each layer is granted by a different mechanism, and each has one owner:

| Layer | Example | Granted by | Changes when |
|---|---|---|---|
| Birthright | BR-02 Store Operations Baseline | Dynamic group, rule on **department** (M1.2) | Department changes (mover) |
| Business (title) | BUS-02 Store Manager | **Access package, automatic policy**, rule on department + **job title** (this module) | Job title changes (promotion, demotion) |
| Add-on | ADD-01 POS Refunds | Same as business | Job title changes |
| Requested | Cash Office (PCI), Admin | Access package with approval and expiry (M2.5) | Request, expiry, review |

No title-based access is granted by hand. When HR changes someone's job title, Entra adds or removes the package with no ticket. It removes it with **no grace period**.

| Question | Before (project 1: detect after the fact) | After (this module) |
|---|---|---|
| Who grants a Shift Lead POS refunds? | Ticket to IT, by hand | ADD-01 policy, from the HR title |
| What happens when a Shift Lead is demoted? | Nothing until the next review | Refunds and the StoreOps Shift Lead role are removed automatically (tested: within 32 minutes) |
| How do we prove who has what? | Export and compare by hand | `-Verify`: 33 checks, person by person against HR |

## 2. Design rules

1. **Department AND title, never title alone.** Rowan Kowalski (E00004) moved to Fuel Operations but HR still has him as "Store Associate". A title-only rule would keep giving him POS access. Every rule includes the department, and `-Verify` checks that wrong-department title matches hold nothing (1 checked: Rowan holds none).
2. **The same in-force guard as birthright:** `employeeId -ne null` and `accountEnabled -eq true`. Admin and break-glass accounts never match, and a disabled leaver drops out of every package.
3. **Attributes only, never `memberOf`.** Rules don't depend on other groups (memberOf rules are quarantined from 2026-11-03).
4. **One automatic policy per package.** Auto-remove is on with no grace period. The package is the only source of members for its `ENT-` groups and StoreOps roles. StoreOps Shift Lead and Store Manager are assigned to users by the package, not to groups.
5. **Birthright stays as groups.** A package per department would duplicate BR-01..06 and add a second owner for the same access.

## 3. Packages

Catalog: **Keystone Store & Fuel Operations** · Script: `scripts/create_access_packages.ps1` · Counts as of 2026-10-30 (HR file `hr_m24.csv`, 275 in force)

| Package | Department + title(s) | Grants | Owner | Review | Flags | People |
|---|---|---|---|---|---|---|
| BUS-01 Store Frontline | Store Operations + Store Associate or Shift Lead | ENT-POS-Cashier | Director of Store Operations | Semiannual | | 104 |
| BUS-02 Store Manager | Store Operations + Store Manager | ENT-POS-Manager, ENT-Inventory-Approver, ENT-Scheduling-Admin, ENT-SafeCount-Operator, StoreOps.StoreManager | Director of Store Operations | Semiannual | PCI | 52 |
| ADD-01 POS Refunds | Store Operations + Shift Lead | ENT-POS-Refunds, StoreOps.ShiftLead | Director of Store Operations | Quarterly | | 60 |
| BUS-03 Fuel Technician | Fuel Operations + Fuel Technician | ENT-FuelPricing-View, ENT-TankMonitor-Operator | Fuel Operations Director | Semiannual | | 6 |
| BUS-04 Fuel Operations Manager | Fuel Operations + Fuel Operations Manager | ENT-FuelPricing-Edit, ENT-TankMonitor-Admin | Fuel Operations Director | Quarterly | Privileged | 11 |

233 assignments for 173 people (the 60 Shift Leads hold BUS-01 and ADD-01). Because BUS-01 covers both store titles, a promotion or demotion between Associate and Shift Lead moves **only** the add-on.

## 4. Why no grace period

Access is based on the job someone currently has. If a Shift Lead is demoted, they should lose access to refunds immediately, even if they are still working on the sales floor and using a register. This is important because employees could misuse refund access by sending money back to their own cards or making refunds they shouldn't be making. There is no reason to allow extra time for this access because the person taking over as Shift Lead will have the same refund permissions.

Requested packages were designed differently: movers would keep them for 15 days to hand over their work (JML-M1), except PCI and admin packages, which JML-M2 removes at the next hourly run (M2.5). In testing, M1's 15-day removal failed (trend report G4), so in practice automatic packages leave with the HR change and Cash Office and Admin leave through JML-M2.

## 5. Test: promotion and demotion (2026-10-29)

HR change file `exports/hr_m24.csv` = `hr_m13_s2.csv` with two title changes (`Compare-Object` showed exactly 2 rows changed):
- **E00013 Alex Larsen**, Store-004: Store Associate → **Shift Lead** (promotion)
- **E00006 Cameron Tanaka**, Store-025: Shift Lead → **Store Associate** (demotion)

| Time (ET) | Event | Evidence |
|---|---|---|
| 17:40 | Before: Cameron holds ADD-01 + StoreOps.ShiftLead; Alex holds BUS-01 only | `person_access_before_2026-10-29_2140.txt` |
| 17:44 | HR load of `hr_m24.csv` (updates only; `accountEnabled` is never sent on update) | `exports/load_report_2026-10-29_1744.csv` (not committed) |
| 18:03 | Verify: ADD-01 **HR says 60, delivered 60**, but `missing: E00013; unexpected: E00006`. 3 of 33 FAIL | `access_packages_config_2026-10-29_2203.txt` |
| 18:16 | After: Alex delivered ADD-01 + StoreOps.ShiftLead; Cameron's ADD-01 **expired**, refunds group and role gone. StoreOps 7/7 | `person_access_after_2026-10-29_2216.txt`, `storeops_app_config.txt`, `05`, `06` |
| 10-30 18:50 | Final verify: **33/33** | `access_packages_config_2026-10-30_2250.txt` |

What it shows:
- **No ticket and no admin click.** The HR title change alone moved the access in both directions.
- **Removal took up to 32 minutes.** At 19 minutes Cameron still held refunds. Microsoft documents re-evaluation as "several minutes". Where 30 minutes of exposure is too long (PCI packages), IAM can remove the assignment directly at the time of the change, and the policy keeps it removed.
- **Counts alone would have passed.** At 18:03 the totals matched (60 = 60) while the wrong person held refunds. `-Verify` compares employee IDs, not totals.
- **Birthright didn't move.** Both stayed in Store Operations, so BR-01/BR-02 stayed the same, and the M1 mover workflow (department trigger) didn't fire. The package policy is the only control that sees a title change.

## 6. Things that broke

| Date | What happened | Fix | Lesson |
|---|---|---|---|
| 10-28 | Mock test: StoreOps -Verify counted 47 of 60 Shift Leads | Graph returns 100 assignments per page; added paging | A check that worked on 1 item can silently truncate at 100 |
| 10-28 | First live verify crashed: "Index operation failed" | A new package with 0 assignments piped `$null` into ForEach-Object; nulls dropped | Test the empty case: new packages start at zero |
| 10-28 | BUS-03 showed 0 of 6 delivered for several minutes after creation | None: delivered on its own | Check again before investigating (the script says so on FAIL) |

## 7. Control mapping

| Framework | Control | How this module meets it |
|---|---|---|
| PCI DSS v4.0 | 7.2.1–7.2.2: access based on job classification and function, least privilege | Rules on department + title from HR; access removed when the title changes |
| PCI DSS v4.0 | 7.2.4: review user accounts and access at least every 6 months | Review cadence set per package (semiannual or quarterly); reviews in M3 |
| NIST SP 800-53 | AC-2 Account management; AC-6 Least privilege; PS-5 Personnel transfer | Automatic assignment and removal on reassignment |
| CIS Controls v8 | 6.8 Define and maintain role-based access control | Packages implement the approved role catalog |

## 8. Open items

| # | Item | Owner |
|---|---|---|
| 8.1 | E00278 Jamie Novak (Store Manager, Store-029) reports to Cameron Tanaka, now a Store Associate at Store-025. Manager links drive TAP delivery, mover notices and access review routing (M1.1 found 29 Store Managers reporting to Shift Leads; JML open item 7.1 covers missing managers) | HR |
| 8.2 | A title-only change notifies nobody: the M1 mover workflow triggers on department. Decide whether to add a jobTitle-change trigger that notifies the manager | IAM + Director of Store Operations |
| 8.3 | ~~Re-evaluation latency (up to 32 min observed)~~ **Resolved M2.5 (2026-11-03):** accepted for ADD-01; PCI and admin requested packages are removed by JML-M2 at the next workflow run after a department change (§10.4) | IAM |
| 8.4 | Licensing: 173 people in scope vs 25 trial Governance licenses (lab deviation) | IT |
| 8.5 | ADD-06 lists ADD-01 as incompatible, but not the reverse. Not tested: what happens if a Cash Office holder is promoted to Shift Lead (is the ADD-01 automatic assignment blocked?). Decide whether to make it two-way and test it | IAM + Director of Store Operations |
| 8.6 | ~~JML-M1 15-day removal may also remove the mover's new packages~~ **Superseded (M4.3, 2026-11-12):** the M1 task failed for Finley ("Custom assignment schedule is prevented by policy"), so nothing was scheduled. See trend report G4 | IAM |

## 9. Evidence (`evidence/M2.4/`)

| File | Shows |
|---|---|
| 01-catalog-resources.png | Catalog with ENT- groups and StoreOps Portal |
| 02-bus02-resource-roles.png / 03-bus02-auto-policy.png / 04-bus02-assignments.png | BUS-02 resources, automatic policy rule, delivered assignments |
| 05-add01-alex-delivered.png / 06-add01-cameron-removed.png | Promotion delivered, demotion removed |
| access_packages_config_2026-10-29_0116.txt | First build: 33/33 |
| access_packages_config_2026-10-29_2203.txt | Mid-change: totals match, wrong people (3 FAIL) |
| access_packages_config_2026-10-30_2250.txt | After the change: 33/33 |
| person_access_before_* / person_access_after_* | Alex and Cameron, every layer, before and after |
| storeops_app_config.txt | StoreOps Portal: Shift Lead 60 users, 7/7 |

Lab deviations (ENT stand-in groups, licensing): `docs/lab-environment.md`.

## 10. Requested packages: Cash Office (PCI) and Admin (M2.5, 2026-11-02/03)

Nobody gets these two because of their HR data. A person asks, gives a reason, an approver says yes, and the access ends on its own. "Has the title" is not "needs card data".

Scripts: `scripts/create_requested_packages.ps1` (packages, -Verify 12 checks), `scripts/request_package.ps1` (admin direct assignment), `scripts/create_pci_mover_workflow.ps1` (JML-M2, -Verify 8 checks).

### 10.1 Design

| Package | Who may ask | Approval | Justification | Expires | Incompatible with | Grants | Owner |
|---|---|---|---|---|---|---|---|
| ADD-06 StoreOps Cash Office [PCI] | BR-02 Store Operations | 1. requestor's manager (no manager in HR → fallback approver) 2. PCI owner | Requestor and approvers | 90 days | ADD-01 POS Refunds | StoreOps.CashOffice | Director of Store Operations |
| ADD-07 StoreOps Admin [Privileged] | BR-06 IT | IT Director | Requestor and approver | 30 days | (none) | StoreOps.Admin | IT Director |

- **90 days for Cash Office** is shorter than the 6-month review in PCI DSS 7.2.4, so access can't outlive two reviews. Keeping it means asking again with a fresh reason.
- **SoD (separation of duties):** whoever issues refunds must not reconcile the cash. Cash Office is incompatible with ADD-01 POS Refunds, the same rule as POS-Refunds ↔ SafeCount-Operator in the role catalog.

### 10.2 SoD test (2026-11-03 01:05–01:20 UTC)

| Person | Request | Result |
|---|---|---|
| E00001 Morgan Haddad, Store Manager, Store-007 | ADD-06, admin direct assignment with justification | Delivered, expires 2027-02-01 01:05Z |
| E00013 Alex Larsen, Shift Lead (holds ADD-01 POS Refunds) | ADD-06, same | **Rejected:** `InvalidRequestSODCheck`, conflicting package ADD-01 POS Refunds. Blocked even for an admin |

### 10.3 Two clocks for movers

Both mover workflows trigger on a department change (`attributeChangeTrigger`, scope `companyName eq 'Keystone Fuel & Market'`).

| Workflow | Tasks | Clock | Why |
|---|---|---|---|
| JML-M1 Department change | Notify manager; remove all access package assignments | 15-day handover (**failed in test: trend report G4**) | Ordinary access: let the mover finish work in the old team |
| JML-M2 PCI access removal on move | Remove ADD-06 Cash Office; remove ADD-07 Admin (continue on error) | Next scheduled run (hourly in the lab) | No handover need for card data or admin. Only Store Ops may ask for Cash Office and only IT for Admin, so changing department means leaving the team that justified it |

### 10.4 Test: Finley Moreau (E00034), Store Operations → Fuel Operations (2026-11-03)

HR change file `exports/hr_m25.csv` = `hr_m24.csv` + E00034 department Store Operations → **Fuel Operations**, title Store Associate → **Fuel Technician** (`Compare-Object`: exactly 1 person changed).

| Time (ET) | Event | Evidence |
|---|---|---|
| 11:04 | JML-M2 created; verify **8/8**, Cash Office held by Morgan only | `pci_mover_workflow_2026-11-03_1104.txt` |
| 11:04 | Finley given ADD-06 with justification; delivered, expires 2027-02-01 | `request_E00034_ADD-06_2026-11-03_1605.txt` |
| 11:05 | Before: BR-02, BUS-01 (POS-Cashier), ADD-06, StoreOps.Associate + **StoreOps.CashOffice** | `person_access_before_move_2026-11-03_1605.txt` |
| ~11:06 | HR load of `hr_m25.csv` | (load report not committed) |
| 11:08 | Verify **7/8**: Finley holds Cash Office as a Fuel Technician (`<-- OUTSIDE`). This is the exposure window | `pci_mover_workflow_2026-11-03_1108.txt` |
| 11:37 | JML-M2 **scheduled** run for Finley: 2 of 2 tasks completed (11:37:52–11:38:04) | `05-m2-history.png` |
| 11:41 | Verify **8/8**: Cash Office held by Morgan only | `pci_mover_workflow_2026-11-03_1141.txt` |
| 11:42 | After: BR-03, no StoreOps roles, ADD-06 **expired**, BUS-01 **expired**; BUS-03 not yet delivered (30/33) | `person_access_after_move_2026-11-03_1642.txt`, `access_packages_config_2026-11-03_1643.txt` |
| 12:00 | BUS-03 Fuel Technician delivered; packages **33/33**; groups BR-02 157, BR-03 19, all match | `person_access_after_move_2026-11-03_1700.txt`, `access_packages_config_2026-11-03_1700.txt`, `group_counts_2026-11-03_1200.csv` |

What it shows:
- **Card-data access ended about 32 minutes after HR recorded the move**, at the next hourly run, not after 15 days. The workflow schedule is the limit: in the lab, runs land at :37 past the hour, so the worst case is about one hour.
- **One HR change, five controls, no ticket.** M2 removed Cash Office, M1 notified the manager, BUS-01 removed POS-Cashier, BR-02 → BR-03 moved birthright, and BUS-03 granted the new job's access.
- **Removal came before the grant** (BUS-01 off by 11:42, BUS-03 on between 11:43 and 12:00). Missing access for a few minutes is a productivity gap. Extra card access is a security gap.
- **"Remove access package" completes when the user doesn't hold the package.** The ADD-07 task completed for Finley, who never held Admin, and an extra on-demand run at 11:39 completed both tasks after Cash Office was already gone. One workflow can cover both packages without a false error on every mover.
- **The new workflow didn't pick up older moves.** Rowan (moved 10-27) has no M2 run; M2 acts on changes after it was created.
- **Verify checks the outcome, not just the config.** The config was 6/6 at 11:08, while a Fuel Technician still held Cash Office.

### 10.5 Control mapping

| Framework | Control | How this module meets it |
|---|---|---|
| PCI DSS v4.0 | 7.2.1–7.2.2: access by job function, least privilege, approved by authorized personnel | Requested per person, manager + PCI owner approval, justification recorded |
| PCI DSS v4.0 | 7.2.4: review access at least every 6 months | 90-day expiry forces a fresh request inside one review period |
| NIST SP 800-53 | AC-5 Separation of duties; AC-6 Least privilege; PS-5 Personnel transfer | ADD-06 ↔ ADD-01 incompatibility; JML-M2 at the department change |
| CIS Controls v8 | 6.1 Establish an access granting process; 6.2 Establish an access revoking process | Request + approval + expiry; automatic revocation on move |

### 10.6 Evidence (`evidence/M2.5/`)

| File | Shows |
|---|---|
| 01a/01b-add06-policy.png, 02-add06-incompatible.png, 03-add06-assignments.png | ADD-06 policy, incompatibility, assignments |
| requested_packages_config_2026-11-03_0107.txt | Both packages read back: 12/12 |
| request_E00001_* / request_E00013_* / request_E00034_* | Delivered (Morgan, Finley) and SoD-rejected (Alex) |
| pci_mover_workflow_*.txt | JML-M2 config and outcome: 8/8 → 7/8 (Finley outside) → 8/8 with runs |
| 05-m2-history.png / 06-m1-history-finley.png | Both mover workflows ran for Finley on the same department change |
| person_access_before_move_* / person_access_after_move_* | Finley, every layer, before and after |
| access_packages_*_1643 / _1700, group_counts_*.csv | Side checks: 30/33 → 33/33; BR-02 157, BR-03 19 |

Lab deviations (one approver for all roles, admin direct assignment): `docs/lab-environment.md`.
