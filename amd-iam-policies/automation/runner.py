#!/usr/bin/env python3
"""
runner.py - run generate.py unattended, on a schedule, in any of the four clouds.

generate.py is written for a human at a terminal: it reads a key file, writes
into the repo, and calls sys.exit() when something is wrong. None of that suits
a Lambda. This wrapper adapts it without changing its logic:

    secret store  ->  CCA token          (never an environment variable in the
                                          template, never in the repo)
    /tmp          ->  scratch outdir     (the only writable path in a Lambda)
    object store  ->  previous + current artifacts
    diff          ->  did the policy actually change?
    notify        ->  only when it did

The last point is the one that makes a weekly schedule tolerable. AMD adds
regions and families a few times a year, so ~50 of 52 runs produce no change at
all. A job that emails every week gets filtered into a folder nobody reads; a
job that stays silent until a policy genuinely moves gets read every time.

Exit codes (container mode):
    0  ran, no policy change
    0  ran, policy changed (the change is reported, not an error)
    1  the run failed

Usage, container / cron:
    python runner.py --backend aws   --bucket my-bucket --prefix amd-iam-policies
    python runner.py --backend azure --container policies --account mystorage
    python runner.py --backend gcp   --bucket my-bucket
    python runner.py --backend oci   --bucket my-bucket --namespace mytenancy
    python runner.py --backend local --outdir ./out        # no cloud at all

Usage, AWS Lambda:
    handler = runner.lambda_handler
"""
import argparse
import datetime
import difflib
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if REPO not in sys.path:
    sys.path.insert(0, REPO)

# The files whose content decides "did the policy change?". Deliberately not
# the snapshot or the gap report: the snapshot carries CCA's full response and
# the report carries a date line, so both differ on every run even when the
# enforced policy is byte-for-byte the same. Diffing those would make the
# change-detection fire every week and train everyone to ignore it.
POLICY_FILES = [
    'aws/scp-deny-intel-amd-available-1.json',
    'aws/scp-deny-intel-amd-available-2.json',
    'aws/declarative-policy-allowed-instance-types.json',
    'aws/deny-matrix.csv',
    'azure/policy-definition-deny-intel-amd-available.json',
    'azure/deny-matrix.csv',
    'gcp/custom-constraint-deny-intel-amd-available.yaml',
    'gcp/custom-constraint-c4-standard.yaml',
    'gcp/deny-matrix.csv',
    'oci/policy-allow-amd-shapes.txt',
    'oci/quota-policy-intel-zero.txt',
    'oci/deny-matrix.csv',
]

SUBDIRS = ['aws', 'azure', 'gcp', 'oci', 'data']


# --------------------------------------------------------------- secret stores
#
# Four backends, one shape: return the JWT as a string, never log it.
# Each import is local so a Lambda only needs its own cloud's SDK in the layer.

def _secret_aws(ref):
    """ref: Secrets Manager secret name or ARN."""
    import boto3
    sm = boto3.client('secretsmanager')
    val = sm.get_secret_value(SecretId=ref)['SecretString']
    # Accept either a bare JWT or {"CCA_API_KEY": "..."} - both are things
    # people reasonably put in a secret, and guessing wrong costs a run.
    if val.lstrip().startswith('{'):
        d = json.loads(val)
        val = d.get('CCA_API_KEY') or d.get('cca_api_key') or next(iter(d.values()))
    return val.strip()


def _secret_azure(ref):
    """ref: 'https://<vault>.vault.azure.net/|<secret-name>'."""
    from azure.identity import DefaultAzureCredential
    from azure.keyvault.secrets import SecretClient
    vault, name = ref.split('|', 1)
    client = SecretClient(vault_url=vault, credential=DefaultAzureCredential())
    return client.get_secret(name).value.strip()


def _secret_gcp(ref):
    """ref: 'projects/<p>/secrets/<s>/versions/latest'."""
    from google.cloud import secretmanager
    client = secretmanager.SecretManagerServiceClient()
    return client.access_secret_version(name=ref).payload.data.decode().strip()


def _secret_oci(ref):
    """ref: Vault secret OCID."""
    import base64
    import oci
    signer = oci.auth.signers.get_resource_principals_signer()
    client = oci.secrets.SecretsClient({}, signer=signer)
    bundle = client.get_secret_bundle(secret_id=ref).data
    return base64.b64decode(bundle.secret_bundle_content.content).decode().strip()


def _secret_local(ref):
    """ref: path to a file containing the JWT, or None to use $CCA_API_KEY."""
    if ref and os.path.exists(ref):
        for line in open(ref, encoding='utf-8'):
            if line.strip().startswith('eyJ'):
                return line.strip()
    tok = os.environ.get('CCA_API_KEY')
    if not tok:
        raise RuntimeError('No CCA token: set CCA_API_KEY or pass --secret PATH')
    return tok.strip()


SECRETS = {'aws': _secret_aws, 'azure': _secret_azure, 'gcp': _secret_gcp,
           'oci': _secret_oci, 'local': _secret_local}


# --------------------------------------------------------------- object stores
#
# get() returns bytes or None (None = not there yet, i.e. first run).
# put() writes bytes. Nothing here is cloud-specific beyond the client call.

class LocalStore:
    def __init__(self, root, **_):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def get(self, key):
        p = os.path.join(self.root, key)
        return open(p, 'rb').read() if os.path.exists(p) else None

    def put(self, key, data, content_type='text/plain'):
        p = os.path.join(self.root, key)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as fh:
            fh.write(data)


class S3Store:
    def __init__(self, bucket, prefix='', **_):
        import boto3
        self.c = boto3.client('s3')
        self.bucket, self.prefix = bucket, prefix.strip('/')

    def _k(self, key):
        return f'{self.prefix}/{key}' if self.prefix else key

    def get(self, key):
        import botocore.exceptions
        try:
            return self.c.get_object(Bucket=self.bucket, Key=self._k(key))['Body'].read()
        except botocore.exceptions.ClientError as e:
            if e.response['Error']['Code'] in ('NoSuchKey', '404'):
                return None
            raise

    def put(self, key, data, content_type='text/plain'):
        self.c.put_object(Bucket=self.bucket, Key=self._k(key), Body=data,
                          ContentType=content_type)


class AzureStore:
    def __init__(self, account, container, prefix='', **_):
        from azure.identity import DefaultAzureCredential
        from azure.storage.blob import BlobServiceClient
        url = f'https://{account}.blob.core.windows.net'
        self.c = BlobServiceClient(url, credential=DefaultAzureCredential())
        self.container, self.prefix = container, prefix.strip('/')

    def _k(self, key):
        return f'{self.prefix}/{key}' if self.prefix else key

    def get(self, key):
        from azure.core.exceptions import ResourceNotFoundError
        try:
            return self.c.get_blob_client(self.container, self._k(key)).download_blob().readall()
        except ResourceNotFoundError:
            return None

    def put(self, key, data, content_type='text/plain'):
        self.c.get_blob_client(self.container, self._k(key)).upload_blob(data, overwrite=True)


class GCSStore:
    def __init__(self, bucket, prefix='', **_):
        from google.cloud import storage
        self.b = storage.Client().bucket(bucket)
        self.prefix = prefix.strip('/')

    def _k(self, key):
        return f'{self.prefix}/{key}' if self.prefix else key

    def get(self, key):
        blob = self.b.blob(self._k(key))
        return blob.download_as_bytes() if blob.exists() else None

    def put(self, key, data, content_type='text/plain'):
        self.b.blob(self._k(key)).upload_from_string(data, content_type=content_type)


class OCIStore:
    def __init__(self, bucket, namespace, prefix='', **_):
        import oci
        signer = oci.auth.signers.get_resource_principals_signer()
        self.c = oci.object_storage.ObjectStorageClient({}, signer=signer)
        self.bucket, self.ns, self.prefix = bucket, namespace, prefix.strip('/')

    def _k(self, key):
        return f'{self.prefix}/{key}' if self.prefix else key

    def get(self, key):
        import oci
        try:
            return self.c.get_object(self.ns, self.bucket, self._k(key)).data.content
        except oci.exceptions.ServiceError as e:
            if e.status == 404:
                return None
            raise

    def put(self, key, data, content_type='text/plain'):
        self.c.put_object(self.ns, self.bucket, self._k(key), io.BytesIO(data))


# ------------------------------------------------------------------ notifiers

def _notify_aws(target, subject, body):
    import boto3
    boto3.client('sns').publish(TopicArn=target, Subject=subject[:100], Message=body)


def _notify_gcp(target, subject, body):
    from google.cloud import pubsub_v1
    pubsub_v1.PublisherClient().publish(
        target, json.dumps({'subject': subject, 'body': body}).encode()).result()


def _notify_oci(target, subject, body):
    import oci
    signer = oci.auth.signers.get_resource_principals_signer()
    oci.ons.NotificationDataPlaneClient({}, signer=signer).publish_message(
        target, oci.ons.models.MessageDetails(title=subject[:128], body=body))


def _notify_log(target, subject, body):
    print(f'=== {subject} ===\n{body}')


NOTIFIERS = {'aws': _notify_aws, 'gcp': _notify_gcp, 'oci': _notify_oci}


# ----------------------------------------------------------------------- core

def _sha(data):
    return hashlib.sha256(data).hexdigest()[:12]


def run(backend, secret_ref, store, notify_target=None, clouds=None,
        insecure=False, stamp=None, secret_backend=None):
    """Generate, compare against the stored copy, upload, report.

    Returns a result dict. Raises on failure - callers decide what that means.

    secret_backend defaults to backend. Overriding it lets you dry-run the
    cloud object-store path with a local key file, which is how you find out
    whether your bucket permissions are right without first wiring up a vault.
    """
    import generate

    if insecure:
        generate.set_insecure()

    stamp = stamp or datetime.date.today().isoformat()
    token = SECRETS[secret_backend or backend](secret_ref)

    workdir = tempfile.mkdtemp(prefix='amd-iam-', dir='/tmp')
    try:
        for sub in SUBDIRS:
            os.makedirs(os.path.join(workdir, sub), exist_ok=True)

        # generate.main() parses sys.argv. Swap it rather than refactor the
        # generator - this keeps the scheduled path and the manual path running
        # literally the same code, which is the point of the exercise.
        argv = sys.argv
        sys.argv = ['generate.py', '--outdir', workdir, '--date', stamp]
        if clouds:
            sys.argv += ['--cloud', ','.join(clouds)]
        try:
            os.environ['CCA_API_KEY'] = token
            summary, _ = generate.main()
        finally:
            sys.argv = argv
            os.environ.pop('CCA_API_KEY', None)
            del token

        changed, diffs, uploaded = [], {}, 0
        for rel in POLICY_FILES:
            path = os.path.join(workdir, rel)
            if not os.path.exists(path):
                continue            # --cloud narrowed the run; not an error
            new = open(path, 'rb').read()
            old = store.get(f'current/{rel}')
            if old is None or _sha(old) != _sha(new):
                changed.append(rel)
                if old is not None:
                    diffs[rel] = _summarize_diff(rel, old, new)
            ctype = ('application/json' if rel.endswith('.json')
                     else 'text/csv' if rel.endswith('.csv') else 'text/plain')
            store.put(f'current/{rel}', new, ctype)
            store.put(f'history/{stamp}/{rel}', new, ctype)
            uploaded += 1

        for extra in (f'data/cca-snapshot-{stamp}.json', f'gap-analysis-{stamp}.md'):
            path = os.path.join(workdir, extra)
            if os.path.exists(path):
                store.put(f'history/{stamp}/{os.path.basename(extra)}',
                          open(path, 'rb').read())

        result = {'date': stamp, 'changed': changed, 'uploaded': uploaded,
                  'summary': {c: {k: v for k, v in s.items()
                                  if k in ('regions', 'families', 'probes',
                                           'deny', 'allow')}
                              for c, s in summary.items()}}

        if changed and notify_target:
            NOTIFIERS.get(backend, _notify_log)(
                notify_target,
                f'AMD IAM policies changed ({len(changed)} files) - {stamp}',
                _report(result, diffs))
        elif changed:
            _notify_log(None, f'AMD IAM policies changed - {stamp}', _report(result, diffs))
        else:
            print(f'{stamp}: no policy change ({uploaded} files checked)')

        return result
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _summarize_diff(rel, old, new):
    """A few lines of context, capped. Full artifacts are in the store."""
    try:
        o = old.decode('utf-8').splitlines()
        n = new.decode('utf-8').splitlines()
    except UnicodeDecodeError:
        return '(binary)'
    if rel.endswith('.csv'):
        # Report the matrices by verdict transition, not as raw line adds. The
        # news a reviewer wants is "this family became deniable in this region"
        # - and crucially, an added row is NOT automatically a new denial; it
        # may be a newly-catalogued family that CCA still has no AMD match for.
        # Keying on region+family and reading the decision column says which.
        def rows(lines):
            out = {}
            for line in lines[1:]:
                f = line.split(',')
                if len(f) >= 4:
                    out[(f[0], f[1])] = (f[3], ','.join(f[4:]))
            return out

        a, b = rows(o), rows(n)
        newly_denied, newly_allowed, appeared, vanished = [], [], [], []
        for k, (dec, amd) in sorted(b.items()):
            if k not in a:
                appeared.append(f'{k[0]} {k[1]} -> {dec}')
            elif a[k][0] != dec:
                (newly_denied if dec == 'DENY' else newly_allowed).append(
                    f'{k[0]} {k[1]}: {a[k][0]} -> {dec}'
                    + (f'  ({amd})' if dec == 'DENY' and amd else ''))
        for k in sorted(set(a) - set(b)):
            vanished.append(f'{k[0]} {k[1]} (was {a[k][0]})')

        parts = []
        for label, rows_ in (('NEWLY DENIED (AMD equivalent now exists)', newly_denied),
                             ('NEWLY ALLOWED (AMD equivalent withdrawn)', newly_allowed),
                             ('new region/family in catalog', appeared),
                             ('dropped from catalog', vanished)):
            if rows_:
                shown = rows_[:15]
                more = f'\n    ... and {len(rows_) - 15} more' if len(rows_) > 15 else ''
                parts.append(f'  {label} [{len(rows_)}]:\n'
                             + '\n'.join(f'    {r}' for r in shown) + more)
        return '\n'.join(parts) or '  (reordered only)'
    diff = list(difflib.unified_diff(o, n, lineterm='', n=1))[:40]
    return '\n'.join('  ' + d for d in diff)


def _report(result, diffs):
    L = [f"AMD IAM policy regeneration - {result['date']}", '']
    L.append('CCA verdicts this run:')
    for c, s in sorted(result['summary'].items()):
        L.append(f"  {c:<6} {s['probes']:>5} probes   "
                 f"{s['deny']:>5} deny   {s['allow']:>5} allow   "
                 f"({s['regions']} regions, {s['families']} families)")
    L += ['', f"Changed files ({len(result['changed'])}):"]
    for f in result['changed']:
        L.append(f'  {f}')
        if f in diffs:
            L.append(diffs[f])
    L += ['', 'These are generated artifacts, not applied policy. Review the diff,',
          'then re-upload the changed files to Organizations / Azure Policy /',
          'org-policies / IAM as described in each cloud README.']
    return '\n'.join(L)


# --------------------------------------------------------------- entry points

def lambda_handler(event, context):
    """AWS Lambda entry point. Config comes from the environment."""
    try:
        store = S3Store(os.environ['ARTIFACT_BUCKET'],
                        os.environ.get('ARTIFACT_PREFIX', 'amd-iam-policies'))
        result = run(backend='aws',
                     secret_ref=os.environ['CCA_SECRET_ID'],
                     store=store,
                     notify_target=os.environ.get('NOTIFY_TOPIC_ARN'),
                     clouds=[c for c in os.environ.get('CLOUDS', '').split(',') if c],
                     insecure=os.environ.get('INSECURE_TLS') == 'true')
        return {'statusCode': 200, 'body': json.dumps(result)}
    except Exception:
        # Print the traceback so it lands in CloudWatch, then re-raise so the
        # invocation is recorded as a failure and the EventBridge/Lambda error
        # metric actually fires. Returning 500 here would look like success to
        # every alarm you would reasonably set.
        traceback.print_exc()
        raise


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--backend', required=True,
                    choices=['aws', 'azure', 'gcp', 'oci', 'local'])
    ap.add_argument('--secret', help='secret id/OCID/path; see the backend docstrings')
    ap.add_argument('--bucket')
    ap.add_argument('--container', help='Azure blob container')
    ap.add_argument('--account', help='Azure storage account')
    ap.add_argument('--namespace', help='OCI object storage namespace')
    ap.add_argument('--prefix', default='amd-iam-policies')
    ap.add_argument('--outdir', help='local backend only')
    ap.add_argument('--notify', help='SNS topic ARN / Pub-Sub topic / ONS topic OCID')
    ap.add_argument('--cloud', help='restrict to AWS,AZURE,GCP,OCI')
    ap.add_argument('--insecure', action='store_true',
                    help='skip TLS verification (intercepting proxies only)')
    ap.add_argument('--date')
    a = ap.parse_args()

    if a.backend == 'local':
        store = LocalStore(a.outdir or os.path.join(HERE, 'runs'))
    elif a.backend == 'aws':
        store = S3Store(a.bucket, a.prefix)
    elif a.backend == 'azure':
        store = AzureStore(a.account, a.container, a.prefix)
    elif a.backend == 'gcp':
        store = GCSStore(a.bucket, a.prefix)
    else:
        store = OCIStore(a.bucket, a.namespace, a.prefix)

    # A --secret that names an existing file is a local key file, whatever the
    # storage backend is. That makes "upload to S3, but read the token off my
    # laptop" a one-flag dry run instead of a code change.
    secret_backend = 'local' if (a.secret is None or os.path.exists(a.secret)) else a.backend
    try:
        result = run(backend=a.backend,
                     secret_ref=a.secret,
                     store=store,
                     notify_target=a.notify,
                     clouds=[c for c in (a.cloud or '').split(',') if c],
                     insecure=a.insecure,
                     stamp=a.date,
                     secret_backend=secret_backend)
    except Exception as e:
        print(f'FAILED: {type(e).__name__}: {e}', file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
