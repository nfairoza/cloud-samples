#!/usr/bin/env python3
"""
Proof of Performance - Azure export parser.

Azure has no single queryable billing table like AWS CUR or GCP BigQuery, so the
reliable way to get 12 months of region + VM size + hours history is a
**Cost Management export** (Azure's CUR equivalent) written to a storage account.
This script reads those export CSV(s) and produces the normalized long schema
consumed by ../build_report.py:

    cloud,year,month,region,arch,family,vcpu_hours,vcpus

vcpu_hours = usage hours (Quantity) x vCPUs per instance.
vcpus      = provisioned vCPUs that month = sum over DISTINCT instances
             (by ResourceId) of each instance's vCPUs. A real headcount of the
             vCPUs that existed that month, not a time-average. Blank if the
             export has no ResourceId column to identify instances.
  * vCPUs come from the export's AdditionalInfo JSON ("VCPUs") when present.
  * Otherwise they are looked up from the VM size (AdditionalInfo "ServiceType")
    using the optional size->vCPU map file (see --vcpu-map / build it with:
        az vm list-skus --resource-type virtualMachines --all -o json > skus.json
    then this script derives the map automatically if you pass --skus skus.json).

Architecture is inferred from the VM size name:
  * a 'p' in the size sub-family  -> ARM  (Ampere)     e.g. Standard_D2ps_v5
  * an 'a' in the size sub-family -> AMD               e.g. Standard_D2as_v5
  * otherwise                     -> Intel             e.g. Standard_D2s_v5

Usage:
    # 1. Create a Cost Management export (Actual cost, monthly) -> storage, then
    #    download the CSV(s) locally (see README.md).
    # 2. Run:
    python3 get-pop-export.py --exports "exports/*.csv" --skus skus.json -o azure_pop_long.csv
    python3 ../build_report.py azure_pop_long.csv -o pop_report.xlsx
"""

import argparse
import calendar
import csv
import glob
import json
import re
import sys
from collections import defaultdict
from datetime import datetime

# Candidate column names across Azure export schema variants (legacy vs FOCUS).
COLS = {
    "date": ["Date", "UsageDateTime", "BillingPeriodStartDate", "ChargePeriodStart", "date"],
    "meter_category": ["MeterCategory", "meterCategory", "x_ServiceCategory"],
    "consumed_service": ["ConsumedService", "consumedService"],
    "region": ["ResourceLocation", "resourceLocation", "Region", "region"],
    "quantity": ["Quantity", "UsageQuantity", "ConsumedQuantity", "quantity"],
    "additional_info": ["AdditionalInfo", "additionalInfo", "x_SkuDetails"],
    "meter_name": ["MeterName", "meterName"],
    "resource_id": ["ResourceId", "InstanceId", "resourceId", "instanceId"],
}


def pick(header, names):
    lower = {h.lower(): h for h in header}
    for n in names:
        if n.lower() in lower:
            return lower[n.lower()]
    return None


def parse_date(value):
    value = (value or "").strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%Y-%m-%dT%H:%M:%S", "%Y%m%d",
                "%m/%d/%Y %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            d = datetime.strptime(value[: len(fmt) + 4], fmt)
            return d.year, d.month
        except ValueError:
            continue
    # last resort: leading YYYY and MM
    m = re.match(r"(\d{4})[-/]?(\d{2})", value)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None


def classify_arch(size):
    """size like 'Standard_D2as_v5' -> AMD; 'Standard_D2ps_v5' -> ARM; else Intel."""
    if not size:
        return "Intel"
    s = size.replace("Standard_", "")
    # capture the lowercase sub-family letters that follow the leading family+number
    m = re.match(r"^[A-Za-z]+\d+(?:-\d+)?([a-z]*)", s)
    letters = m.group(1) if m else ""
    if "p" in letters:
        return "ARM"
    if "a" in letters:
        return "AMD"
    return "Intel"


def family_of(size):
    if not size:
        return "other"
    return size.replace("Standard_", "").split("_")[0] or "other"


def load_vcpu_map(skus_path, map_path):
    vmap = {}
    if map_path:
        with open(map_path, newline="", encoding="utf-8") as fh:
            for row in csv.reader(fh):
                if len(row) >= 2:
                    try:
                        vmap[row[0].strip()] = int(float(row[1]))
                    except ValueError:
                        pass
    if skus_path:
        with open(skus_path, encoding="utf-8") as fh:
            data = json.load(fh)
        for sku in data:
            name = sku.get("name")
            vcpus = None
            for cap in sku.get("capabilities", []) or []:
                if cap.get("name") == "vCPUs":
                    try:
                        vcpus = int(cap.get("value"))
                    except (TypeError, ValueError):
                        vcpus = None
            if name and vcpus:
                vmap[name] = vcpus
    return vmap


def extract_additional(info_raw):
    """Return (vcpus_or_None, service_type_or_None) from AdditionalInfo JSON."""
    if not info_raw:
        return None, None
    txt = info_raw.strip()
    # exports sometimes double-quote-escape the JSON
    if txt.startswith('"') and txt.endswith('"'):
        txt = txt[1:-1].replace('""', '"')
    try:
        info = json.loads(txt)
    except (json.JSONDecodeError, ValueError):
        return None, None
    vcpus = info.get("VCPUs") or info.get("vCPUs") or info.get("vCpus")
    service_type = info.get("ServiceType") or info.get("serviceType")
    try:
        vcpus = int(vcpus) if vcpus is not None else None
    except (TypeError, ValueError):
        vcpus = None
    return vcpus, service_type


def main():
    ap = argparse.ArgumentParser(description="Parse Azure Cost Management exports for Proof of Performance.")
    ap.add_argument("--exports", required=True, help="glob for the export CSV file(s), e.g. 'exports/*.csv'")
    ap.add_argument("--skus", help="JSON from 'az vm list-skus ... -o json' (for size->vCPU lookup)")
    ap.add_argument("--vcpu-map", help="optional CSV 'size,vcpus' to supplement the lookup")
    ap.add_argument("-o", "--output", default="azure_pop_long.csv", help="normalized output CSV")
    args = ap.parse_args()

    files = glob.glob(args.exports)
    if not files:
        sys.exit(f"ERROR: no files matched --exports '{args.exports}'")

    vcpu_map = load_vcpu_map(args.skus, args.vcpu_map)

    agg = defaultdict(float)  # (year, month, region, arch, family) -> vcpu_hours
    # (year, month, region, arch, family) -> {resource_id: vcpus} for the distinct
    # instance count. A machine's size is fixed, so storing vcpus-per-instance and
    # summing the values gives provisioned vCPUs without double-counting a VM that
    # appears on many daily rows.
    instances = defaultdict(dict)
    rows_seen = rows_used = missing_vcpu = 0
    saw_resource_id = False

    for path in files:
        with open(path, newline="", encoding="utf-8-sig") as fh:
            reader = csv.reader(fh)
            header = next(reader, None)
            if not header:
                continue
            idx = {k: (header.index(pick(header, v)) if pick(header, v) else None)
                   for k, v in COLS.items()}
            if idx["quantity"] is None or idx["date"] is None:
                print(f"WARNING: {path} missing Date/Quantity columns; skipped.", file=sys.stderr)
                continue
            for row in reader:
                rows_seen += 1
                if idx["meter_category"] is not None:
                    if "virtual machines" not in (row[idx["meter_category"]] or "").lower():
                        continue
                elif idx["consumed_service"] is not None:
                    if "compute" not in (row[idx["consumed_service"]] or "").lower():
                        continue
                ym = parse_date(row[idx["date"]])
                if not ym:
                    continue
                try:
                    qty = float(row[idx["quantity"]] or 0)
                except ValueError:
                    qty = 0.0
                if qty <= 0:
                    continue
                info_raw = row[idx["additional_info"]] if idx["additional_info"] is not None else ""
                vcpus, service_type = extract_additional(info_raw)
                size = service_type
                if vcpus is None and size:
                    vcpus = vcpu_map.get(size)
                if not vcpus:
                    missing_vcpu += 1
                    continue
                region = (row[idx["region"]] if idx["region"] is not None else "") or "unknown"
                arch = classify_arch(size)
                family = family_of(size)
                key = (ym[0], ym[1], region.strip(), arch, family)
                agg[key] += qty * vcpus
                rid = row[idx["resource_id"]] if idx["resource_id"] is not None else None
                if rid:
                    saw_resource_id = True
                    # last write wins if a resize occurred mid-month; vcpus is fixed per size
                    instances[key][rid.strip().lower()] = vcpus
                rows_used += 1

    if not agg:
        sys.exit("ERROR: no Virtual Machine usage rows with vCPU info were found. "
                 "Check that the export includes AdditionalInfo, or pass --skus.")

    with open(args.output, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["cloud", "year", "month", "region", "arch", "family", "vcpu_hours", "vcpus"])
        for key, vh in sorted(agg.items()):
            y, m, region, arch, family = key
            # provisioned vCPUs = sum of each distinct instance's vCPUs (real count).
            # Blank if the export carried no ResourceId to identify instances.
            prov = sum(instances[key].values()) if key in instances else ""
            w.writerow(["Azure", y, m, region, arch, family, round(vh, 2), prov])

    print(f"Wrote {args.output}")
    print(f"  rows scanned: {rows_seen}, VM rows used: {rows_used}, skipped (no vCPU): {missing_vcpu}")
    if missing_vcpu:
        print("  Tip: pass --skus skus.json to resolve sizes missing an AdditionalInfo VCPUs value.")
    if not saw_resource_id:
        print("  NOTE: no ResourceId/InstanceId column found, so 'vcpus' (provisioned vCPU")
        print("        count) is blank. Include ResourceId in the export to get real counts.")
    print(f"\nNext step - build the Excel report:\n  python3 ../build_report.py {args.output} -o pop_report.xlsx")


if __name__ == "__main__":
    main()
