#!/usr/bin/env bash
# Build the deployment zip for AWS Lambda (and the Azure/GCP/OCI container
# contexts, which use the same two files).
#
#   ./automation/package.sh              -> automation/build/lambda.zip
#   ./automation/package.sh --upload BKT -> also copies it to s3://BKT/
#
# The zip holds exactly two files: generate.py (the policy logic, unchanged
# from the one a human runs by hand) and runner.py (the headless wrapper).
# boto3 is already present in the Lambda runtime, so there is nothing to
# vendor and no build container needed - which is also why this is a shell
# script and not a Dockerfile.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
BUILD="$HERE/build"
ZIP="$BUILD/lambda.zip"

mkdir -p "$BUILD"
rm -f "$ZIP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$REPO/generate.py" "$STAGE/"
cp "$HERE/runner.py"   "$STAGE/"

# Deterministic zip: fixed timestamps and sorted entries mean an unchanged
# source tree produces a byte-identical artifact, so source_code_hash does not
# churn and Terraform does not redeploy a function that did not change.
#
# Built through Python rather than the zip(1) binary: the runtime is Python
# everywhere this runs, whereas zip is absent on Windows and on slim CI images.
python3 - "$STAGE" "$ZIP" <<'PY'
import hashlib, os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(out), exist_ok=True)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(stage)):
        zi = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
        zi.external_attr = 0o644 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(stage, name), 'rb') as fh:
            z.writestr(zi, fh.read())
print(f'built  {out}')
print(f'sha256 {hashlib.sha256(open(out,"rb").read()).hexdigest()}')
with zipfile.ZipFile(out) as z:
    for i in z.infolist():
        print(f'       {i.file_size:>8}  {i.filename}')
PY

if [[ "${1:-}" == "--upload" ]]; then
  BUCKET="${2:?usage: package.sh --upload BUCKET [KEY]}"
  KEY="${3:-amd-iam-policies/lambda.zip}"
  aws s3 cp "$ZIP" "s3://$BUCKET/$KEY"
  echo "uploaded s3://$BUCKET/$KEY"
fi
