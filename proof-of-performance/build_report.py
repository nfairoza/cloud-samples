#!/usr/bin/env python3
"""
Proof of Performance - report builder (cloud-agnostic).

Reads one or more "long" CSV files produced by the per-cloud export scripts and
builds a single Excel workbook that shows how vCPUs are distributed across CPU
vendors/architectures (Intel / AMD / ARM) over the last 12 months - month by
month AND quarter by quarter, at the account level and broken down by region.

Input CSV schema (header row required, one row per group):

    cloud,year,month,region,arch,family,vcpu_hours

  cloud       e.g. AWS | Azure | GCP
  year        4-digit year (int)
  month       1-12 (int)
  region      provider region short code (e.g. us-east-1, eastus, us-central1)
  arch        Intel | AMD | ARM
  family      instance family (e.g. m7a, c7g, Dasv5, n2d) - detail only
  vcpu_hours  SUM(instance-hours x vCPUs-per-instance) for that group (float)

Two metrics are reported for every bucket:
  * vCPU-hours    = the raw consumption number from the CSV.
  * Avg vCPUs     = vCPU-hours / (hours in the period) = the average number of
                    vCPUs running concurrently (the intuitive "how many vCPUs").

Usage:
    python3 build_report.py aws_pop_long.csv [gcp_pop_long.csv ...] -o pop_report.xlsx
    python3 build_report.py *_pop_long.csv          # combine every cloud
"""

import argparse
import calendar
import csv
import glob
import sys
from collections import defaultdict

try:
    import openpyxl
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter
except ImportError:
    sys.exit(
        "ERROR: openpyxl is required.\n"
        "Install it with:  pip install --user openpyxl\n"
        "(In Cloud Shell this works without admin rights.)"
    )

ARCHS = ["Intel", "AMD", "ARM"]

HEADER_FILL = PatternFill("solid", fgColor="1F4E78")
HEADER_FONT = Font(bold=True, color="FFFFFF")
SUBHEAD_FILL = PatternFill("solid", fgColor="D9E1F2")
NUM_FMT = "#,##0"
PCT_FMT = "0.0%"


def hours_in_month(year, month):
    return calendar.monthrange(year, month)[1] * 24


def quarter_of(month):
    return (month - 1) // 3 + 1


# --------------------------------------------------------------------------- #
# Load
# --------------------------------------------------------------------------- #
def load_records(files):
    records = []
    for pattern in files:
        matched = glob.glob(pattern)
        if not matched:
            matched = [pattern]  # let the open() call raise a clear error
        for path in matched:
            with open(path, newline="", encoding="utf-8-sig") as fh:
                reader = csv.DictReader(fh)
                required = {"cloud", "year", "month", "region", "arch", "vcpu_hours"}
                missing = required - set(h.strip() for h in (reader.fieldnames or []))
                if missing:
                    sys.exit(f"ERROR: {path} is missing columns: {sorted(missing)}")
                for row in reader:
                    try:
                        vh = float(row.get("vcpu_hours") or 0)
                    except ValueError:
                        vh = 0.0
                    if vh <= 0:
                        continue
                    arch = (row.get("arch") or "").strip()
                    if arch not in ARCHS:
                        arch = "Intel"
                    records.append(
                        {
                            "cloud": (row.get("cloud") or "Unknown").strip(),
                            "year": int(float(row["year"])),
                            "month": int(float(row["month"])),
                            "region": (row.get("region") or "unknown").strip() or "unknown",
                            "arch": arch,
                            "family": (row.get("family") or "").strip(),
                            "vcpu_hours": vh,
                        }
                    )
    if not records:
        sys.exit("ERROR: no usable rows found in the input CSV(s).")
    return records


# --------------------------------------------------------------------------- #
# Aggregations
# --------------------------------------------------------------------------- #
def aggregate(records):
    # keyed dicts: key -> {arch: vcpu_hours}
    acct_month = defaultdict(lambda: defaultdict(float))   # (cloud, y, m)
    reg_month = defaultdict(lambda: defaultdict(float))    # (cloud, region, y, m)
    acct_qtr = defaultdict(lambda: defaultdict(float))     # (cloud, y, q)
    reg_qtr = defaultdict(lambda: defaultdict(float))      # (cloud, region, y, q)
    family = defaultdict(float)                            # (cloud, region, y, m, arch, family)

    # track which (year, month) actually appear, per quarter grouping, so the
    # quarterly "Avg vCPUs" denominator only counts months we have data for.
    acct_qtr_months = defaultdict(set)   # (cloud, y, q) -> {(y, m)}
    reg_qtr_months = defaultdict(set)    # (cloud, region, y, q) -> {(y, m)}

    for r in records:
        c, y, m, reg, arch, fam, vh = (
            r["cloud"], r["year"], r["month"], r["region"],
            r["arch"], r["family"], r["vcpu_hours"],
        )
        q = quarter_of(m)
        acct_month[(c, y, m)][arch] += vh
        reg_month[(c, reg, y, m)][arch] += vh
        acct_qtr[(c, y, q)][arch] += vh
        reg_qtr[(c, reg, y, q)][arch] += vh
        family[(c, reg, y, m, arch, fam)] += vh
        acct_qtr_months[(c, y, q)].add((y, m))
        reg_qtr_months[(c, reg, y, q)].add((y, m))

    return {
        "acct_month": acct_month,
        "reg_month": reg_month,
        "acct_qtr": acct_qtr,
        "reg_qtr": reg_qtr,
        "family": family,
        "acct_qtr_months": acct_qtr_months,
        "reg_qtr_months": reg_qtr_months,
    }


# --------------------------------------------------------------------------- #
# Sheet writing helpers
# --------------------------------------------------------------------------- #
def style_header(ws, ncols, row=1):
    for c in range(1, ncols + 1):
        cell = ws.cell(row=row, column=c)
        cell.fill = HEADER_FILL
        cell.font = HEADER_FONT
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def autosize(ws):
    for col in ws.columns:
        width = 10
        for cell in col:
            if cell.value is not None:
                width = max(width, len(str(cell.value)) + 2)
        ws.column_dimensions[get_column_letter(col[0].column)].width = min(width, 26)


def arch_metric_headers(prefix_cols):
    """Build the shared column header list."""
    cols = list(prefix_cols)
    for a in ARCHS:
        cols.append(f"{a} vCPU-hrs")
    cols.append("Total vCPU-hrs")
    for a in ARCHS:
        cols.append(f"{a} avg vCPUs")
    cols.append("Total avg vCPUs")
    cols.append("AMD % (vCPU-hrs)")
    cols.append("ARM % (vCPU-hrs)")
    return cols


def write_metric_row(ws, row_idx, prefix_values, arch_hours, period_hours):
    """period_hours = number of wall-clock hours in the period (for avg vCPUs)."""
    col = 1
    for v in prefix_values:
        ws.cell(row=row_idx, column=col, value=v)
        col += 1

    total_h = sum(arch_hours.get(a, 0.0) for a in ARCHS)
    # vCPU-hours block
    for a in ARCHS:
        cell = ws.cell(row=row_idx, column=col, value=round(arch_hours.get(a, 0.0)))
        cell.number_format = NUM_FMT
        col += 1
    ws.cell(row=row_idx, column=col, value=round(total_h)).number_format = NUM_FMT
    col += 1
    # avg vCPUs block
    for a in ARCHS:
        avg = arch_hours.get(a, 0.0) / period_hours if period_hours else 0
        cell = ws.cell(row=row_idx, column=col, value=round(avg))
        cell.number_format = NUM_FMT
        col += 1
    total_avg = total_h / period_hours if period_hours else 0
    ws.cell(row=row_idx, column=col, value=round(total_avg)).number_format = NUM_FMT
    col += 1
    # percentages
    amd_pct = (arch_hours.get("AMD", 0.0) / total_h) if total_h else 0
    arm_pct = (arch_hours.get("ARM", 0.0) / total_h) if total_h else 0
    ws.cell(row=row_idx, column=col, value=amd_pct).number_format = PCT_FMT
    col += 1
    ws.cell(row=row_idx, column=col, value=arm_pct).number_format = PCT_FMT
    col += 1


def build_monthly_sheet(wb, title, data_by_key, prefix_cols, key_prefix_fields):
    """Generic month sheet. key = (..prefix.., year, month)."""
    ws = wb.create_sheet(title)
    headers = arch_metric_headers(prefix_cols)
    ws.append(headers)
    style_header(ws, len(headers))
    ws.freeze_panes = "A2"

    for key in sorted(data_by_key.keys()):
        *prefix, year, month = key
        prefix_values = list(prefix) + [year, calendar.month_abbr[month], f"Q{quarter_of(month)}"]
        write_metric_row(
            ws, ws.max_row + 1, prefix_values,
            data_by_key[key], hours_in_month(year, month),
        )
    autosize(ws)
    return ws


def build_quarterly_sheet(wb, title, data_by_key, months_by_key, prefix_cols):
    """Generic quarter sheet. key = (..prefix.., year, quarter)."""
    ws = wb.create_sheet(title)
    headers = arch_metric_headers(prefix_cols)
    ws.append(headers)
    style_header(ws, len(headers))
    ws.freeze_panes = "A2"

    for key in sorted(data_by_key.keys()):
        *prefix, year, quarter = key
        months = months_by_key.get(key, set())
        period_hours = sum(hours_in_month(y, m) for (y, m) in months)
        prefix_values = list(prefix) + [year, f"Q{quarter}"]
        write_metric_row(ws, ws.max_row + 1, prefix_values, data_by_key[key], period_hours)
    autosize(ws)
    return ws


def build_family_sheet(wb, family_data):
    ws = wb.create_sheet("Family-Detail")
    headers = ["Cloud", "Region", "Year", "Month", "Quarter", "Arch", "Family",
               "vCPU-hrs", "Avg vCPUs"]
    ws.append(headers)
    style_header(ws, len(headers))
    ws.freeze_panes = "A2"
    for key in sorted(family_data.keys()):
        cloud, region, year, month, arch, fam = key
        vh = family_data[key]
        avg = vh / hours_in_month(year, month)
        ws.append([cloud, region, year, calendar.month_abbr[month], f"Q{quarter_of(month)}",
                   arch, fam, round(vh), round(avg)])
        ws.cell(row=ws.max_row, column=8).number_format = NUM_FMT
        ws.cell(row=ws.max_row, column=9).number_format = NUM_FMT
    autosize(ws)
    return ws


def build_readme_sheet(wb):
    ws = wb.create_sheet("About", 0)
    lines = [
        ("Proof of Performance - vCPU migration report", True),
        ("", False),
        ("Tracks how compute vCPUs are split across CPU vendors (Intel / AMD / ARM)", False),
        ("over the last 12 months, to show migration toward AMD.", False),
        ("", False),
        ("Two metrics per bucket:", True),
        ("  vCPU-hrs   = SUM(instance-hours x vCPUs per instance). Real consumption.", False),
        ("  avg vCPUs  = vCPU-hrs / hours in the period = average concurrent vCPUs", False),
        ("               (the intuitive 'how many vCPUs', prorated for part-month usage).", False),
        ("", False),
        ("Sheets:", True),
        ("  Account-Monthly    : per cloud, one row per month.", False),
        ("  Region-Monthly     : per cloud + region, one row per month.", False),
        ("  Account-Quarterly  : per cloud, one row per quarter.", False),
        ("  Region-Quarterly   : per cloud + region, one row per quarter.", False),
        ("  Family-Detail      : per cloud/region/month/arch/family breakdown.", False),
        ("", False),
        ("Arch = ARM covers AWS Graviton, GCP Axion/Tau (ARM), Azure Ampere.", False),
        ("Reserved/committed capacity is NOT a separate bucket here - this measures", False),
        ("the vendor of the silicon, which is what 'proof of performance' cares about.", False),
    ]
    for text, bold in lines:
        ws.append([text])
        if bold:
            ws.cell(row=ws.max_row, column=1).font = Font(bold=True)
    ws.column_dimensions["A"].width = 90
    return ws


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Build the Proof of Performance Excel report.")
    ap.add_argument("inputs", nargs="+", help="one or more *_pop_long.csv files (globs ok)")
    ap.add_argument("-o", "--output", default="pop_report.xlsx", help="output .xlsx path")
    args = ap.parse_args()

    records = load_records(args.inputs)
    agg = aggregate(records)

    wb = openpyxl.Workbook()
    wb.remove(wb.active)  # drop default sheet; we add our own

    build_readme_sheet(wb)
    build_monthly_sheet(wb, "Account-Monthly", agg["acct_month"],
                        ["Cloud", "Year", "Month", "Quarter"], ["cloud"])
    build_monthly_sheet(wb, "Region-Monthly", agg["reg_month"],
                        ["Cloud", "Region", "Year", "Month", "Quarter"], ["cloud", "region"])
    build_quarterly_sheet(wb, "Account-Quarterly", agg["acct_qtr"],
                          agg["acct_qtr_months"], ["Cloud", "Year", "Quarter"])
    build_quarterly_sheet(wb, "Region-Quarterly", agg["reg_qtr"],
                          agg["reg_qtr_months"], ["Cloud", "Region", "Year", "Quarter"])
    build_family_sheet(wb, agg["family"])

    wb.save(args.output)
    print(f"Wrote {args.output}")
    print(f"  {len(records)} input rows across {len({r['cloud'] for r in records})} cloud(s)")
    months = sorted({(r["year"], r["month"]) for r in records})
    if months:
        print(f"  covering {months[0][0]}-{months[0][1]:02d} to {months[-1][0]}-{months[-1][1]:02d}")


if __name__ == "__main__":
    main()
