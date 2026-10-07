#!/usr/bin/env python3
"""
Local CUR -> CCA export.

Reads an AWS Cost & Usage Report (CUR) that you've already downloaded as CSV
(single file, split files, or .csv.gz) sitting in THIS folder, and produces a
CSV in the exact CCA Portfolio Template column order -- the same output as the
Athena version (get-cca-export.sh), but with no S3 / Glue / Athena setup.

Usage:
    python get-cca-export-local.py                 # scan current folder for CUR CSVs
    python get-cca-export-local.py mycur.csv       # one specific file
    python get-cca-export-local.py ./cur_folder/   # a folder of CUR part files

Prerequisites: Python 3.7+ only. No pip installs, no AWS credentials.
Works with CUR 2.0 (underscore columns) and Legacy CUR (slash columns).
"""

import csv
import glob
import gzip
import os
import re
import sys

OUTPUT_FILE = "cur_results_local.csv"

# Logical field -> we match any header whose normalized form equals the key.
# Normalization strips case, slashes, underscores and dashes, so
# "line_item_availability_zone" and "lineItem/AvailabilityZone" both collapse
# to "lineitemavailabilityzone" and map to the same field.
FIELD_KEYS = {
    "availability_zone": "lineitemavailabilityzone",
    "instance_type":     "productinstancetype",
    "resource_id":       "lineitemresourceid",
    "usage_amount":      "lineitemusageamount",
    "purchase_option":   "pricingpurchaseoption",
    "line_item_type":    "lineitemlineitemtype",
    "product_code":      "lineitemproductcode",
    "usage_type":        "lineitemusagetype",
}


def normalize(header):
    return re.sub(r"[/_\-\s]", "", header.strip().lower())


def find_cur_files(arg):
    """Return a list of CUR csv/csv.gz files from a file, a folder, or cwd."""
    if arg and os.path.isfile(arg):
        return [arg]
    folder = arg if arg and os.path.isdir(arg) else "."
    files = []
    for pattern in ("*.csv", "*.csv.gz"):
        files.extend(glob.glob(os.path.join(folder, pattern)))
    # don't re-read our own output
    return sorted(f for f in files if os.path.basename(f) != OUTPUT_FILE)


def open_any(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8-sig", newline="")
    return open(path, "rt", encoding="utf-8-sig", newline="")


def map_pricing(value):
    v = (value or "").strip()
    if v == "Reserved":
        return "Reserved"
    if v == "Spot":
        return "Spot"
    return "On-Demand"


def region_from_az(az):
    # us-east-1a -> us-east-1 ; already-a-region values pass through unchanged
    return re.sub(r"[a-z]$", "", (az or "").strip())


def process(files):
    # grouped[(az, size, purchase_option)] = {"resource_ids": set, "hours": float}
    grouped = {}
    total_rows = 0
    kept_rows = 0

    for path in files:
        with open_any(path) as fh:
            reader = csv.reader(fh)
            try:
                header = next(reader)
            except StopIteration:
                continue

            norm = [normalize(h) for h in header]
            idx = {}
            for field, key in FIELD_KEYS.items():
                if key in norm:
                    idx[field] = norm.index(key)

            required = ("availability_zone", "instance_type", "usage_amount",
                        "line_item_type", "product_code", "usage_type")
            missing = [f for f in required if f not in idx]
            if missing:
                print(f"  ! Skipping {os.path.basename(path)} -- not a CUR file "
                      f"(missing columns: {', '.join(missing)})")
                continue

            print(f"  + Reading {os.path.basename(path)}")
            for row in reader:
                total_rows += 1
                if len(row) <= max(idx.values()):
                    continue

                def cell(field):
                    return row[idx[field]] if field in idx else ""

                # same filters as the Athena query
                if cell("line_item_type") != "Usage":
                    continue
                if cell("product_code") != "AmazonEC2":
                    continue
                if "BoxUsage" not in cell("usage_type"):
                    continue

                kept_rows += 1
                az = cell("availability_zone")
                size = cell("instance_type")
                purchase = map_pricing(cell("purchase_option"))
                key = (az, size, purchase)

                bucket = grouped.setdefault(key, {"ids": set(), "hours": 0.0})
                rid = cell("resource_id")
                if rid:
                    bucket["ids"].add(rid)
                try:
                    bucket["hours"] += float(cell("usage_amount") or 0)
                except ValueError:
                    pass

    return grouped, total_rows, kept_rows


def write_output(grouped):
    rows = []
    for (az, size, purchase), bucket in grouped.items():
        quantity = len(bucket["ids"]) if bucket["ids"] else 0
        rows.append([
            "AWS",
            region_from_az(az),
            size,
            quantity,
            int(round(bucket["hours"])),
            purchase,
        ])
    # ORDER BY Size, Region, Pricing Model
    rows.sort(key=lambda r: (r[2], r[1], r[5]))

    with open(OUTPUT_FILE, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["Cloud", "Region", "Size", "Quantity",
                         "Total number of hours per month", "Pricing Model"])
        writer.writerows(rows)
    return rows


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    files = find_cur_files(arg)
    if not files:
        print("No .csv / .csv.gz files found. Put the CUR file in this folder, "
              "or pass a path:\n  python get-cca-export-local.py <file-or-folder>")
        sys.exit(1)

    print(f"Found {len(files)} candidate file(s):")
    grouped, total_rows, kept_rows = process(files)

    if not grouped:
        print(f"\nRead {total_rows} rows but none matched the EC2 usage filters "
              "(line item type 'Usage', product 'AmazonEC2', usage type like "
              "'%BoxUsage%'). Check that this is an EC2 CUR for the right month.")
        sys.exit(1)

    rows = write_output(grouped)
    print(f"\nRead {total_rows} rows, kept {kept_rows} EC2 usage rows -> "
          f"{len(rows)} output rows.")
    print(f"Wrote {OUTPUT_FILE}. Preview:")
    print("  Cloud,Region,Size,Quantity,Hours,Pricing Model")
    for r in rows[:10]:
        print("  " + ",".join(str(c) for c in r))
    if len(rows) > 10:
        print(f"  ... ({len(rows) - 10} more)")
    print(f"\nPaste the rows from {OUTPUT_FILE} into AWS_AZURE_GCP.xlsx "
          "(or upload the CSV to the CCA portal).")


if __name__ == "__main__":
    main()
