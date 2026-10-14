# Lessons — Keystone Entra Governance Program

Pacing: check in before each lesson, extra-detailed steps. Resume from the first unchecked item.

## Progress

### M0 — Pre-trial prep
- [x] M0.1 Repo and data foundation (2026-10-14 — verify passed: 1641 assignments, answer key ignored, no leaks)
- [x] M0.2 Lab email alias, ServiceNow PDI request, lab environment plan (tenant creation moved to M1.1 to protect the trial clock)

### M2 Part A — Role mining (pre-trial)
- [ ] M2.1 Build the user × entitlement matrix
- [ ] M2.2 Similarity clustering and candidate roles
- [ ] M2.3 Birthright vs requested; coverage metrics

### M1 — Identity foundation & lifecycle management
- [ ] M1.1 Activate Governance trial; load HR feed with Graph PowerShell
- [ ] M1.2 Dynamic groups (attribute-based birthright)
- [ ] M1.3 Lifecycle Workflows: joiner, mover, leaver
- [ ] M1.4 Snapshot T0 + integration analysis memo (StoreOps Portal)

### M2 Part B — Access packages
- [ ] M2.4 Catalog, birthright auto-assignment packages
- [ ] M2.5 Requested packages, approvals, expiry, incompatible packages

### M3 — Certifications
- [ ] M3.1 PCI access package review (recommendations, auto-apply)
- [ ] M3.2 Multi-stage privileged role review + inactive-users-only review
- [ ] M3.3 Certifier support desk + certification report

### M4 — Trend reporting
- [ ] M4.1 Snapshot T1 export
- [ ] M4.2 KPI and anomaly notebook
- [ ] M4.3 Governance trend report + escalation table

### M5 — Policy, SOPs, ServiceNow, on-call
- [ ] M5.1 IAM Access Control Policy + request workflow
- [ ] M5.2 SOPs + end-user guide
- [ ] M5.3 ServiceNow catalog item + 6 incidents
- [ ] M5.4 Triage runbook + escalation matrix

### M6 — Privileged access (optional stretch)
- [ ] M6.1 PIM just-in-time activation
- [ ] M6.2 Break-glass accounts + alert

## Things that broke

| Date | Lesson | What broke | Root cause | Fix | Interview story? |
|---|---|---|---|---|---|
| 2026-10-14 | M0.1 | Generator run failed: "No such file or directory" | Script was still in Downloads, not in `scripts\`; Python resolves paths relative to the current folder | Moved file with `Move-Item`, confirmed with `Get-ChildItem -Recurse`, reran | Minor — shows checking the working directory before debugging the tool |

| 2026-10-14 | M2.1 | gitleaks reported 30 leaks incl. a private key | `gitleaks dir` scans all files and ignores .gitignore; findings were in .venv (third-party packages + Tornado's public test key) | Triaged: all in ignored folder, none staged → false positives. Switched to scanning only what Git tracks | Yes — triaging scanner findings |

## Concept notes (from check questions)

- **M0.1:** A leaver with an enabled account is a *true positive* ("terminated user with active access"), not a false positive. Deleting a committed secret does not remove it from Git history: rotate the secret first, then purge history. Seeds make the T0→T1 comparison reproducible.

- **M2.1:** Roles are templates copied to every future holder — mining from orphan/leaver access bakes errors in. High prevalence ≠ appropriate (sensitive/PCI access stays a requested, approved, reviewed role). Sparse matrix ≠ least privilege, but it means a few roles can cover many people. Department is too coarse: Store Ops = 3 jobs with different POS access.