#!/usr/bin/env python3
"""Generate synthetic identity and access data for IAM / IGA portfolio labs.

Produces an HR feed (authoritative source), a directory account export, application
entitlement assignments, and SoD rules, with deliberately planted problems:
orphaned accounts, dormant accounts, terminated users with active access, SoD
violations, excessive privilege, and role drift. An answer key is written to
ground_truth.json so analysis results can be checked.

All data is fictional. Standard library only (Python 3.9+).

Example:
    python generate_identities.py --users 300 --out data/sample --seed 42
"""
from __future__ import annotations

import argparse
import csv
import json
import random
from datetime import date, timedelta
from pathlib import Path

FIRST = ["Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Jamie", "Avery", "Quinn", "Drew",
         "Sam", "Reese", "Cameron", "Skyler", "Rowan", "Emerson", "Hayden", "Parker", "Logan", "Dakota",
         "Kendall", "Finley", "Harper", "Blake", "Elliot", "Sawyer", "Peyton", "Marley", "Kai", "Shawn"]
LAST = ["Miller", "Novak", "Reyes", "Okafor", "Lindqvist", "Patel", "Brennan", "Kowalski", "Tanaka",
        "Moreau", "Haddad", "Sullivan", "Ivanova", "Mensah", "Fischer", "Castillo", "Byrne", "Nguyen",
        "Larsen", "Achebe", "Romano", "Schultz", "Duarte", "Kaur", "Whitaker", "Abara", "Yilmaz", "Stone"]

# Industry profiles: department -> (job titles, weight, birthright entitlements, title-specific entitlements)
PROFILES = {
    "retail": {
        "org": "Keystone Quick Mart (fictional)",
        "domain": "kqm-lab.example",
        "departments": {
            "Store Operations": (["Store Associate", "Shift Lead", "Store Manager"], 55,
                                  ["APP-Timeclock", "APP-Email", "APP-LearningPortal"],
                                  {"Store Associate": ["POS-Cashier"],
                                   "Shift Lead": ["POS-Cashier", "POS-Refunds"],
                                   "Store Manager": ["POS-Manager", "Inventory-Approver",
                                                     "Scheduling-Admin", "SafeCount-Operator"]}),
            "Fuel Operations": (["Fuel Technician", "Fuel Operations Manager"], 6,
                                 ["APP-Email", "APP-Timeclock"],
                                 {"Fuel Technician": ["FuelPricing-View", "TankMonitor-Operator"],
                                  "Fuel Operations Manager": ["FuelPricing-Edit", "TankMonitor-Admin"]}),
            "Finance": (["AP Specialist", "AR Specialist", "Accounting Manager"], 8,
                        ["APP-Email", "APP-ERP-Read"],
                        {"AP Specialist": ["ERP-VendorPayment-Create"],
                         "AR Specialist": ["ERP-Receivables-Edit"],
                         "Accounting Manager": ["ERP-VendorPayment-Approve", "ERP-GL-Post"]}),
            "Procurement": (["Buyer", "Procurement Manager"], 5,
                            ["APP-Email", "APP-ERP-Read"],
                            {"Buyer": ["ERP-Vendor-Create", "ERP-PO-Create"],
                             "Procurement Manager": ["ERP-PO-Approve", "ERP-Vendor-Create"]}),
            "Human Resources": (["HR Generalist", "HR Manager"], 5,
                                ["APP-Email", "HRIS-Read"],
                                {"HR Generalist": ["HRIS-Employee-Edit"],
                                 "HR Manager": ["HRIS-Employee-Edit", "HRIS-Payroll-Approve"]}),
            "Information Technology": (["Service Desk Analyst", "Systems Administrator", "IAM Analyst"], 10,
                                       ["APP-Email", "ITSM-Agent"],
                                       {"Service Desk Analyst": ["Directory-PasswordReset"],
                                        "Systems Administrator": ["Directory-Admin", "Server-Admin"],
                                        "IAM Analyst": ["IGA-Reviewer-Admin", "Directory-Read"]}),
            "Payments / PCI": (["Payments Analyst", "Payments Manager"], 4,
                               ["APP-Email", "PCI-CDE-Jumpbox"],
                               {"Payments Analyst": ["Payments-Gateway-Read", "Chargeback-Edit"],
                                "Payments Manager": ["Payments-Gateway-Admin", "Chargeback-Approve"]}),
        },
        # Pairs that must not be held by the same person
        "sod": [
            ("ERP-VendorPayment-Create", "ERP-VendorPayment-Approve", "Create and approve vendor payments"),
            ("ERP-Vendor-Create", "ERP-VendorPayment-Approve", "Create vendor and approve payment to it"),
            ("ERP-PO-Create", "ERP-PO-Approve", "Create and approve purchase orders"),
            ("HRIS-Employee-Edit", "HRIS-Payroll-Approve", "Edit employee records and approve payroll"),
            ("POS-Refunds", "SafeCount-Operator", "Issue refunds and count the safe"),
            ("Directory-Admin", "IGA-Reviewer-Admin", "Administer directory and control access reviews"),
        ],
        "privileged": ["Directory-Admin", "Server-Admin", "Payments-Gateway-Admin", "TankMonitor-Admin",
                       "ERP-GL-Post", "IGA-Reviewer-Admin"],
        "pci_scoped": ["PCI-CDE-Jumpbox", "Payments-Gateway-Read", "Payments-Gateway-Admin",
                       "Chargeback-Edit", "Chargeback-Approve", "POS-Manager"],
    }
}


def pick_weighted(rng: random.Random, departments: dict) -> str:
    names = list(departments)
    weights = [departments[n][1] for n in names]
    return rng.choices(names, weights=weights, k=1)[0]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--users", type=int, default=300, help="number of HR identities (default 300)")
    ap.add_argument("--industry", choices=sorted(PROFILES), default="retail")
    ap.add_argument("--out", default="data/sample", help="output folder")
    ap.add_argument("--seed", type=int, default=42, help="random seed for repeatable data")
    ap.add_argument("--as-of", default=None, help="snapshot date YYYY-MM-DD (default today)")
    ap.add_argument("--terminated-pct", type=float, default=0.08, help="share of HR records terminated")
    ap.add_argument("--leaver-miss-pct", type=float, default=0.35,
                    help="share of terminated users whose account was NOT disabled")
    ap.add_argument("--orphans", type=int, default=12, help="directory accounts with no HR record")
    ap.add_argument("--dormant-pct", type=float, default=0.10, help="share of active users with no sign-in > 90 days")
    ap.add_argument("--sod-violations", type=int, default=8, help="users given a toxic entitlement pair")
    ap.add_argument("--excess-pct", type=float, default=0.07,
                    help="share of users with extra out-of-role entitlements (incl. privileged)")
    ap.add_argument("--movers-pct", type=float, default=0.06,
                    help="share of users who changed department but kept old access (role drift)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    as_of = date.fromisoformat(args.as_of) if args.as_of else date.today()
    prof = PROFILES[args.industry]
    depts = prof["departments"]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    truth: dict[str, list] = {k: [] for k in
                              ["orphaned_accounts", "terminated_with_active_access", "dormant_accounts",
                               "sod_violations", "excessive_access", "movers_with_residual_access",
                               "shared_generic_accounts"]}

    # ---- HR feed -------------------------------------------------------------------------------
    hr, used = [], set()
    for i in range(1, args.users + 1):
        while True:
            fn, ln = rng.choice(FIRST), rng.choice(LAST)
            base = f"{fn}.{ln}".lower()
            uname = base if base not in used else f"{base}{rng.randint(2, 99)}"
            if uname not in used:
                used.add(uname)
                break
        dept = pick_weighted(rng, depts)
        title = rng.choice(depts[dept][0])
        hire = as_of - timedelta(days=rng.randint(30, 3650))
        hr.append({"employee_id": f"E{i:05d}", "first_name": fn, "last_name": ln,
                   "upn": f"{uname}@{prof['domain']}", "department": dept, "job_title": title,
                   "manager_id": "", "location": f"Store-{rng.randint(1, 40):03d}" if dept == "Store Operations" else "Corporate",
                   "employment_type": rng.choices(["Full-time", "Part-time", "Contractor"], [60, 32, 8])[0],
                   "hire_date": hire.isoformat(), "status": "Active", "termination_date": ""})

    # managers: first manager-ish title in same dept, else any
    mgr_titles = ("Manager", "Lead")
    for p in hr:
        candidates = [m for m in hr if m["department"] == p["department"] and m is not p
                      and any(t in m["job_title"] for t in mgr_titles)]
        p["manager_id"] = rng.choice(candidates)["employee_id"] if candidates else ""

    # terminations
    n_term = int(len(hr) * args.terminated_pct)
    terminated = rng.sample(hr, n_term)
    for p in terminated:
        p["status"] = "Terminated"
        p["termination_date"] = (as_of - timedelta(days=rng.randint(3, 180))).isoformat()

    # movers: changed department in HR, but access still reflects old dept (set below)
    active = [p for p in hr if p["status"] == "Active"]
    movers = {}
    for p in rng.sample(active, int(len(active) * args.movers_pct)):
        old_dept, old_title = p["department"], p["job_title"]
        new_dept = rng.choice([d for d in depts if d != old_dept])
        p["department"], p["job_title"] = new_dept, rng.choice(depts[new_dept][0])
        movers[p["employee_id"]] = (old_dept, old_title)

    # ---- Directory accounts ---------------------------------------------------------------------
    accounts = []
    leaver_missed = set(p["employee_id"] for p in rng.sample(terminated, int(len(terminated) * args.leaver_miss_pct)))
    for p in hr:
        enabled = p["status"] == "Active" or p["employee_id"] in leaver_missed
        created = date.fromisoformat(p["hire_date"])
        last = as_of - timedelta(days=rng.randint(0, 20))
        if p["status"] == "Terminated":
            term = date.fromisoformat(p["termination_date"])
            last = min(last, term - timedelta(days=rng.randint(0, 5)))
        accounts.append({"account_id": f"A-{p['employee_id']}", "upn": p["upn"], "employee_id": p["employee_id"],
                         "display_name": f"{p['first_name']} {p['last_name']}", "account_type": "User",
                         "enabled": str(enabled).lower(), "created_date": created.isoformat(),
                         "last_sign_in": last.isoformat()})
        if p["employee_id"] in leaver_missed:
            truth["terminated_with_active_access"].append(p["upn"])

    # dormant: active people, no sign-in > 90 days
    for a in rng.sample([a for a in accounts if a["enabled"] == "true"
                         and a["employee_id"] not in leaver_missed], int(len(active) * args.dormant_pct)):
        a["last_sign_in"] = (as_of - timedelta(days=rng.randint(91, 400))).isoformat()
        truth["dormant_accounts"].append(a["upn"])

    # orphans: accounts with no HR record
    for i in range(args.orphans):
        fn, ln = rng.choice(FIRST), rng.choice(LAST)
        upn = f"{fn}.{ln}.old{i}@{prof['domain']}".lower()
        accounts.append({"account_id": f"A-ORPH{i:03d}", "upn": upn, "employee_id": "",
                         "display_name": f"{fn} {ln}", "account_type": "User", "enabled": "true",
                         "created_date": (as_of - timedelta(days=rng.randint(400, 2500))).isoformat(),
                         "last_sign_in": (as_of - timedelta(days=rng.randint(0, 300))).isoformat()})
        truth["orphaned_accounts"].append(upn)

    # shared / generic accounts
    for name in ["store.kiosk", "frontdesk", "svc.backup", "temp.admin"]:
        upn = f"{name}@{prof['domain']}"
        accounts.append({"account_id": f"A-GEN-{name}", "upn": upn, "employee_id": "",
                         "display_name": name, "account_type": "Service" if name.startswith("svc") else "Shared",
                         "enabled": "true", "created_date": (as_of - timedelta(days=rng.randint(200, 2000))).isoformat(),
                         "last_sign_in": (as_of - timedelta(days=rng.randint(0, 60))).isoformat()})
        truth["shared_generic_accounts"].append(upn)

    # ---- Entitlements ---------------------------------------------------------------------------
    all_ents = sorted({e for d in depts.values() for e in d[2]} |
                      {e for d in depts.values() for lst in d[3].values() for e in lst})
    ents_by_upn: dict[str, set] = {}
    hr_by_id = {p["employee_id"]: p for p in hr}
    for a in accounts:
        p = hr_by_id.get(a["employee_id"])
        if p:
            dept, title = movers.get(p["employee_id"], (p["department"], p["job_title"]))
            s = set(depts[dept][2]) | set(depts[dept][3].get(title, []))
            if p["employee_id"] in movers:  # keep old access AND add new birthright
                s |= set(depts[p["department"]][2]) | set(depts[p["department"]][3].get(p["job_title"], []))
                truth["movers_with_residual_access"].append(
                    {"upn": p["upn"], "old_department": dept, "new_department": p["department"]})
        else:
            s = set(rng.sample(all_ents, rng.randint(2, 5)))
        ents_by_upn[a["upn"]] = s

    people_upns = [p["upn"] for p in hr if p["status"] == "Active"]
    for upn in rng.sample(people_upns, int(len(people_upns) * args.excess_pct)):
        extra = set(rng.sample(prof["privileged"], 1)) | set(rng.sample(all_ents, rng.randint(1, 2)))
        added = extra - ents_by_upn[upn]
        if added:
            ents_by_upn[upn] |= added
            truth["excessive_access"].append({"upn": upn, "extra_entitlements": sorted(added)})

    for upn in rng.sample(people_upns, min(args.sod_violations, len(people_upns))):
        a_ent, b_ent, desc = rng.choice(prof["sod"])
        ents_by_upn[upn] |= {a_ent, b_ent}

    # compute SoD truth after all assignments (includes ones created naturally by drift/excess)
    for upn, s in ents_by_upn.items():
        for a_ent, b_ent, desc in prof["sod"]:
            if a_ent in s and b_ent in s:
                truth["sod_violations"].append({"upn": upn, "rule": desc, "entitlements": [a_ent, b_ent]})

    created_by_upn = {a["upn"]: date.fromisoformat(a["created_date"]) for a in accounts}
    assignments = []
    for upn, s in ents_by_upn.items():
        span = max((as_of - created_by_upn[upn]).days, 1)
        for e in sorted(s):
            assignments.append({"upn": upn, "entitlement": e,
                                "granted_date": (created_by_upn[upn] + timedelta(days=rng.randint(0, span))).isoformat(),
                                "grant_source": rng.choices(["Birthright", "Request", "Manual"], [55, 35, 10])[0]})

    apps = []
    for e in all_ents:
        apps.append({"entitlement": e, "application": e.split("-")[0],
                     "privileged": str(e in prof["privileged"]).lower(),
                     "pci_scope": str(e in prof["pci_scoped"]).lower(),
                     "owner_department": next((d for d, v in depts.items()
                                               if e in v[2] or any(e in l for l in v[3].values())), "")})

    # ---- Write ----------------------------------------------------------------------------------
    def write(name: str, rows: list[dict]) -> None:
        with open(out / name, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)

    write("hr_feed.csv", hr)
    write("directory_accounts.csv", accounts)
    write("entitlement_assignments.csv", assignments)
    write("entitlement_catalog.csv", apps)
    write("sod_rules.csv", [{"entitlement_a": a, "entitlement_b": b, "description": d} for a, b, d in prof["sod"]])
    truth_meta = {"organization": prof["org"], "as_of": as_of.isoformat(), "seed": args.seed,
                  "counts": {k: len(v) for k, v in truth.items()}, "details": truth}
    (out / "ground_truth.json").write_text(json.dumps(truth_meta, indent=2), encoding="utf-8")

    print(f"Wrote {len(hr)} HR records, {len(accounts)} accounts, {len(assignments)} assignments to {out}/")
    for k, v in truth_meta["counts"].items():
        print(f"  {k}: {v}")
    print("Answer key: ground_truth.json (keep it out of the learner's view until their analysis is done)")


if __name__ == "__main__":
    main()
