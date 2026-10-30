# Title-Based Access Packages — Keystone Fuel & Market

*Module M2.4 · Built in a lab tenant (Microsoft Entra ID Governance trial) · Last updated 2026-10-30*

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

Requested packages are handled differently. Employees who move to a new position are allowed to keep their access for 15 days to give them time to finish their current work and pass their responsibilities on to someone else (M1.3). The exception is PCI packages, which must be removed immediately on the employee's last day in that role (day 0) because of the requirements in open item 7.4 (M2.5).

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
| 8.3 | Re-evaluation latency (up to 32 min observed). Accept for ADD-01; for PCI requested packages, remove at the time of change (M2.5) | IAM |
| 8.4 | Licensing: 173 people in scope vs 25 trial Governance licenses (lab deviation) | IT |

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
