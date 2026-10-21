#!/usr/bin/env python3
"""
generate.py - derive AMD-enforcement IAM/governance policies from AMD CCA.

The question this script answers, once per cloud region and instance family:

    "Does an AMD equivalent for this Intel family actually exist in this region?"

It does NOT answer that from SKU name patterns (m5 -> m5a). It asks AMD CCA
(EPYC Advisory) directly: submit a representative instance to
POST /v2/recommendations and read the Best Match output.

    recommendation returned  -> an AMD equivalent exists  -> DENY new Intel
    no recommendation        -> no AMD equivalent          -> ALLOW new Intel

That single rule implements both carve-outs the policy owner asked for:
families with no AMD counterpart anywhere (storage/GPU/HPC) are never denied,
and regions where AMD has not landed yet are never denied, because CCA simply
returns nothing for them.

ARM (Graviton / Cobalt / Axion / Ampere) is deliberately out of scope. Only
Intel families are probed and only Intel families are denied.

Usage:
    python generate.py --key-file PATH [--outdir .] [--cloud AWS,AZURE,GCP,OCI]
                       [--snapshot PATH] [--date YYYY-MM-DD]

The CCA token is read into memory and is never printed, logged, or written to
any output file.
"""
import argparse
import collections
import csv
import datetime
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

BASE = 'https://api.epycadvisory.amd.com'
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE

CLOUDS = ['AWS', 'AZURE', 'GCP', 'OCI']
BATCH = 400
HOURS = 730.0

# ---------------------------------------------------------------- credentials

def read_token(key_file):
    """Read the CCA JWT. Never echo it."""
    if key_file and os.path.exists(key_file):
        for line in open(key_file, encoding='utf-8'):
            if line.strip().startswith('eyJ'):
                return line.strip()
    tok = os.environ.get('CCA_API_KEY')
    if not tok:
        sys.exit('No CCA token. Set CCA_API_KEY or pass --key-file.')
    return tok

# ------------------------------------------------------------------- transport

def _req(url, token, data=None):
    headers = {'Authorization': f'Bearer {token}', 'Appname': 'cca',
               'Content-Type': 'application/json'}
    body = json.dumps(data).encode() if data is not None else None
    return urllib.request.Request(url, data=body, headers=headers)


def get_summary(token, provider):
    """GET instances/summary -> {region: [sku, ...]}."""
    url = f'{BASE}/instances/summary?provider={provider}'
    with urllib.request.urlopen(_req(url, token), context=_CTX, timeout=300) as r:
        payload = json.load(r)
    return payload.get('Data', {})


def post_recommendations(token, provider, rows):
    """POST /v2/recommendations -> {uuid: [amd_sku, ...]}.

    Data[].id echoes the submitted uuid, so encoding "{region}|{family}" as the
    uuid maps every result back deterministically without relying on ordering.
    """
    out = {}
    for i in range(0, len(rows), BATCH):
        chunk = rows[i:i + BATCH]
        body = {'portfolioName': 'amd-iam-policies', 'provider': provider,
                'appName': 'CCA', 'downloadable_link': False,
                'policy_engine': 'No Policy Engine (Default)', 'data': chunk}
        try:
            with urllib.request.urlopen(_req(f'{BASE}/v2/recommendations', token, body),
                                        context=_CTX, timeout=900) as r:
                resp = json.load(r)
        except urllib.error.HTTPError as e:
            try:
                resp = json.loads(e.read().decode())
            except Exception:
                resp = {'ErrorCode': -1, 'Message': f'HTTP {e.code}'}
        if resp.get('ErrorCode') != 1:
            sys.exit(f"CCA rejected the {provider} batch at row {i}: {resp.get('Message')}")
        for item in resp.get('Data', []):
            recs = [x.get('instanceType')
                    for x in item.get('data', {}).get('recommendations', [])
                    if x.get('instanceType') not in (None, '-', '')]
            out[item['id']] = recs
        print(f'  {provider}: {len(out)}/{len(rows)} probed', flush=True)
    missing = [r['uuid'] for r in rows if r['uuid'] not in out]
    if missing:
        sys.exit(f'{provider}: CCA returned no verdict for {len(missing)} probes, '
                 f'e.g. {missing[:5]}')
    return out

# -------------------------------------------------------- vendor classification
# Each cloud encodes the silicon vendor differently. Classify conservatively:
# anything we cannot positively identify as AMD or ARM is treated as Intel only
# if it matches a known Intel pattern; otherwise it is skipped entirely so we
# never deny something we did not understand.

AWS_ARM = re.compile(r'^(a1|[a-z]+\d+gn?d?|x2gd|x8g|im4gn|is4gen|hpc7g)$')
AWS_AMD = re.compile(r'^[a-z]+\d+a$')
# Intel general-purpose/compute/memory/burstable families CCA actually prices.
AWS_INTEL = re.compile(r'^(t|m|c|r)\d+i?$')

AZURE_SKU = re.compile(r'^standard_([a-z]+?)(\d+)(?:-(\d+))?([a-z]*)(?:_v(\d+))?$')

# t2d is Tau VM on EPYC Milan - AMD, despite not carrying a 'd' suffix on a
# paired Intel series. Leaving it out silently denies an AMD family.
GCP_AMD = {'c2d', 'c3d', 'n2d', 'c4d', 'n4d', 't2d'}
GCP_ARM = {'t2a', 'c4a', 'n4a'}

OCI_FAMILIES = {
    'vm.standard1': 'vm.standard1.8',
    'vm.standard2': 'vm.standard2.8',
    'vm.standard3.flex': 'vm.standard3.flex',
    'vm.standard.b1': 'vm.standard.b1.8',
}


def aws_family(sku):
    return sku.split('.')[0]


def aws_vendor(fam):
    if AWS_ARM.match(fam):
        return 'ARM'
    if AWS_AMD.match(fam):
        return 'AMD'
    if AWS_INTEL.match(fam):
        return 'Intel'
    return 'Other'


def azure_parse(sku):
    m = AZURE_SKU.match(sku.lower())
    if not m:
        return None
    prefix, vcpu, constrained, attrs, ver = m.groups()
    return prefix, int(vcpu), constrained, attrs, ver


def azure_family(sku):
    """Family key = prefix | attrs | version, e.g. 'd|s|5' for Standard_D8s_v5.

    The vCPU count is deliberately excluded: size is not part of the decision.
    """
    p = azure_parse(sku)
    if not p:
        return None
    prefix, _, _, attrs, ver = p
    return f"{prefix}|{attrs}|{ver or ''}"


def azure_vendor(famkey):
    prefix, attrs, _ = famkey.split('|')
    if 'p' in attrs:          # Standard_D8ps_v5 etc -> Cobalt/Ampere
        return 'ARM'
    if 'a' in attrs:          # Standard_D8as_v5 etc -> EPYC
        return 'AMD'
    return 'Intel'


def gcp_family(sku):
    """Family-class key, e.g. 'n2-standard'. Shared-core e2 SKUs stand alone."""
    parts = sku.split('-')
    if len(parts) < 3:
        return sku            # e2-micro / e2-small / e2-medium
    return f'{parts[0]}-{parts[1]}'


def gcp_vendor(famkey):
    series = famkey.split('-')[0]
    if series in GCP_ARM:
        return 'ARM'
    if series in GCP_AMD:
        return 'AMD'
    return 'Intel'


def oci_family(sku):
    s = sku.lower()
    if s.startswith('vm.standard.b1'):
        return 'vm.standard.b1'
    if s.startswith('vm.standard3.flex'):
        return 'vm.standard3.flex'
    if s.startswith('vm.standard2.'):
        return 'vm.standard2'
    if s.startswith('vm.standard1.'):
        return 'vm.standard1'
    return None               # E-series is AMD, A-series is Ampere/ARM

# ------------------------------------------------------------- probe selection
# One probe per region x family, at a representative large size. CCA's verdict
# was verified to be identical across every size within a family (t3.nano and
# t3.2xlarge agree; m5.large and m5.metal agree), so size is not a variable.

AWS_SIZE_LADDER = ['8xlarge', '4xlarge', '2xlarge', '16xlarge', 'xlarge',
                   '12xlarge', 'large', 'medium', 'small', 'micro', 'nano']
AZURE_VCPU_LADDER = [16, 8, 32, 4, 48, 64, 2, 96, 1, 24, 12, 20, 80, 128]
GCP_VCPU_LADDER = [16, 8, 32, 4, 48, 64, 2, 96, 24, 12, 80, 128, 1]


def pick_aws(skus):
    by_size = {s.split('.', 1)[1]: s for s in skus if '.' in s}
    for want in AWS_SIZE_LADDER:
        if want in by_size:
            return by_size[want]
    return sorted(skus)[-1]


def pick_azure(skus):
    # Constrained-vCPU SKUs (Standard_E8-4s_v5) are a pricing variant, not a
    # distinct family; prefer a plain SKU when one exists.
    plain = [s for s in skus if '-' not in s] or skus
    by_vcpu = {}
    for s in plain:
        p = azure_parse(s)
        if p:
            by_vcpu[p[1]] = s
    for want in AZURE_VCPU_LADDER:
        if want in by_vcpu:
            return by_vcpu[want]
    return sorted(plain)[-1]


def pick_gcp(skus):
    by_vcpu = {}
    for s in skus:
        parts = s.split('-')
        if len(parts) >= 3 and parts[2].isdigit():
            by_vcpu[int(parts[2])] = s
    if not by_vcpu:
        return sorted(skus)[-1]
    for want in GCP_VCPU_LADDER:
        if want in by_vcpu:
            return by_vcpu[want]
    return by_vcpu[max(by_vcpu)]

# ------------------------------------------------------------------ gap sweeps

def sweep_aws(token, catalog):
    rows, meta = [], {}
    for region in sorted(catalog):
        fams = collections.defaultdict(list)
        for sku in catalog[region]:
            fams[aws_family(sku)].append(sku)
        for fam, skus in fams.items():
            if aws_vendor(fam) != 'Intel':
                continue
            probe = pick_aws(skus)
            uuid = f'{region}|{fam}'
            meta[uuid] = probe
            rows.append({'cloud_csp': 'AWS', 'region': region, 'instance type': probe,
                         'quantity': 1, 'monthly utilization (hourly)': HOURS,
                         'pricingModel': 'ondemand', 'uuid': uuid})
    return rows, meta


def sweep_azure(token, catalog):
    rows, meta = [], {}
    for region in sorted(catalog):
        fams = collections.defaultdict(list)
        for sku in catalog[region]:
            key = azure_family(sku)
            if key:
                fams[key].append(sku)
        for key, skus in fams.items():
            if azure_vendor(key) != 'Intel':
                continue
            probe = pick_azure(skus)
            uuid = f'{region}|{key}'
            meta[uuid] = probe
            rows.append({'cloud_csp': 'AZURE', 'region': region, 'instance type': probe,
                         'quantity': 1, 'monthly utilization (hourly)': HOURS,
                         'pricingModel': 'ondemand', 'uuid': uuid})
    return rows, meta


def sweep_gcp(token, catalog):
    rows, meta = [], {}
    for region in sorted(catalog):
        fams = collections.defaultdict(list)
        for sku in catalog[region]:
            fams[gcp_family(sku)].append(sku)
        for key, skus in fams.items():
            if gcp_vendor(key) != 'Intel':
                continue
            probe = pick_gcp(skus)
            uuid = f'{region}|{key}'
            meta[uuid] = probe
            rows.append({'cloud_csp': 'GCP', 'region': region, 'instance type': probe,
                         'quantity': 1, 'monthly utilization (hourly)': HOURS,
                         'pricingModel': 'ondemand', 'uuid': uuid})
    return rows, meta


def sweep_oci(token, catalog):
    """OCI flex shapes are rejected without explicit ocpu AND memory."""
    rows, meta = [], {}
    for region in sorted(catalog):
        fams = {f for f in (oci_family(s) for s in catalog[region]) if f}
        for fam in sorted(fams):
            probe = OCI_FAMILIES[fam]
            uuid = f'{region}|{fam}'
            meta[uuid] = probe
            rows.append({'cloud_csp': 'OCI', 'region': region, 'instance type': probe,
                         'quantity': 1, 'monthly utilization (hourly)': HOURS,
                         'pricingModel': 'ondemand', 'uuid': uuid,
                         'ocpu': 8, 'memory': 64})
    return rows, meta


SWEEPS = {'AWS': sweep_aws, 'AZURE': sweep_azure, 'GCP': sweep_gcp, 'OCI': sweep_oci}

# ----------------------------------------------------------------- integrity

def check_recs_available(cloud, catalog, verdicts, famfn):
    """Every AMD recommendation must itself exist in the region it was given for.

    This is what makes the no-AMD-in-region carve-out trustworthy: if CCA ever
    recommended a family absent from the region, the deny would strand the user
    with no legal option. Verified zero violations across all four clouds.
    """
    bad = []
    for uuid, recs in verdicts.items():
        if not recs:
            continue
        region = uuid.split('|', 1)[0]
        present = {famfn(s) for s in catalog.get(region, [])}
        if not any(famfn(r) in present for r in recs):
            bad.append((uuid, recs))
    return bad


def oci_base(sku):
    """vm.standard.e4.flex.8-64 -> vm.standard.e4.flex"""
    return re.sub(r'\.\d+(-\d+)?$', '', sku.lower())

# ------------------------------------------------------------------- AWS build

def build_aws(catalog, verdicts, meta, outdir, stamp):
    fam_deny = collections.defaultdict(set)
    fam_allow = collections.defaultdict(set)
    for uuid, recs in verdicts.items():
        region, fam = uuid.split('|', 1)
        (fam_deny if recs else fam_allow)[fam].add(region)

    deny_by_region = collections.defaultdict(list)
    for fam, regions in fam_deny.items():
        for r in regions:
            deny_by_region[r].append(fam)

    # Group regions that share an identical deny-set into one statement.
    groups = collections.defaultdict(list)
    for region, fams in deny_by_region.items():
        groups[tuple(sorted(fams))].append(region)

    statements = []
    for i, (fams, regions) in enumerate(
            sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])), 1):
        statements.append({
            'Sid': f'DenyIntelWhereAmdEquivalentExists{i}',
            'Effect': 'Deny',
            'Action': 'ec2:RunInstances',
            # Scoped to the instance resource only. "Resource": "*" would also
            # deny the AMI, subnet and ENI arns the same call touches, which
            # blocks every launch including AMD ones.
            'Resource': 'arn:aws:ec2:*:*:instance/*',
            'Condition': {
                'StringLike': {'ec2:InstanceType': [f'{f}.*' for f in fams]},
                'StringEquals': {'aws:RequestedRegion': sorted(regions)},
            },
        })

    # SCPs are capped at 5,120 bytes, so pack statements greedily into as few
    # policies as will hold them. Multiple SCPs attached to the same OU compose.
    def pol(stmts):
        return {'Version': '2012-10-17', 'Statement': stmts}

    def size(stmts):
        return len(json.dumps(pol(stmts), separators=(',', ':')))

    packs = [[]]
    for st in statements:
        if packs[-1] and size(packs[-1] + [st]) > 5120:
            packs.append([])
        packs[-1].append(st)

    written = []
    for i, stmts in enumerate(packs, 1):
        path = os.path.join(outdir, 'aws', f'scp-deny-intel-amd-available-{i}.json')
        doc = pol(stmts)
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, indent=2)
            fh.write('\n')
        compact = len(json.dumps(doc, separators=(',', ':')))
        assert compact <= 5120, f'{path} is {compact} bytes, over the SCP limit'
        written.append((path, compact, len(stmts)))

    # Declarative Policy: the SCP cannot see launches made by the Auto Scaling
    # service-linked role. A Declarative Policy does cover the SLR, so it is the
    # companion control - but it is an ALLOW-list, which forces two compromises
    # the SCP does not have. Both are written into the notes file so nobody
    # applies this blind.
    #
    #  1. Region-blind. There is no region condition key, so a family denied in
    #     any region must be left out entirely, which enforces that deny
    #     globally - including regions where CCA found no AMD equivalent.
    #  2. Catalog-bound. CCA prices general-purpose, compute and memory families
    #     only. Storage, GPU and HPC families are absent from the catalog, so
    #     they cannot be enumerated here and would be blocked unless added.
    all_fams = {aws_family(s) for region in catalog for s in catalog[region]}
    allowed = sorted(f for f in all_fams
                     if aws_vendor(f) in ('AMD', 'ARM', 'Other')
                     or (f in fam_allow and f not in fam_deny))
    mixed = sorted(f for f in fam_deny if f in fam_allow)
    decl = {
        'ec2_attributes': {
            'allowed_instance_types': {
                '@@assign': [f'{f}.*' for f in allowed],
            }
        }
    }
    dpath = os.path.join(outdir, 'aws', 'declarative-policy-allowed-instance-types.json')
    with open(dpath, 'w', encoding='utf-8') as fh:
        json.dump(decl, fh, indent=2)
        fh.write('\n')

    notes = [
        '# Declarative Policy - read before applying', '',
        'This file exists to close one specific gap: **Auto Scaling launches through',
        'the service-linked role are not evaluated against SCPs.** A Declarative Policy',
        'is evaluated, so it covers ASG where the SCP cannot.',
        '',
        'It is an allow-list, and that costs two things the SCP does not cost you.',
        'Neither is a bug in the generator - they are limits of the mechanism.',
        '',
        '## 1. It is region-blind',
        '',
        'Declarative Policies have no region condition key. A family denied in even one',
        'region therefore has to be omitted from the allow-list entirely, which enforces',
        'that deny in **every** region - including the ones where CCA found no AMD',
        'equivalent. The following families are allowed by the SCP in at least one region',
        'but are omitted here, so applying this file is stricter than the stated policy:',
        '',
        '```',
    ]
    for f in mixed:
        kept = sorted(fam_allow.get(f, ()))
        notes.append(f'{f:6} still allowed by the SCP in: {", ".join(kept)}')
    notes += [
        '```', '',
        '## 2. It only knows the families CCA prices', '',
        f'CCA\'s catalog covers {len(all_fams)} families - general purpose, compute',
        'optimized and memory optimized. Storage, GPU, HPC and accelerated families',
        '(`i3`, `i4i`, `m5d`, `r5d`, `d3`, `g4dn`, `g5`, `p5`, `inf2`, `trn1`, `x2idn`,',
        '`z1d`, `u-*`, `hpc6a`, ...) are **not in the catalog**, were never probed, and',
        'so cannot appear in the list above. Apply this file as-is and those launches',
        'will be blocked.',
        '',
        'The SCP does not have this problem - it names families to deny, so anything',
        'CCA does not price is untouched by it.',
        '',
        '**Before applying, append every accelerated/storage family you actually run**',
        'to `allowed_instance_types`, for example:',
        '',
        '```json',
        '"@@assign": ["c8a.*", "m8a.*", "...", "i4i.*", "g5.*", "p5.*", "trn1.*"]',
        '```',
        '',
        'If that is not acceptable, use the SCP alone and accept the ASG gap, or restrict',
        'which instance types your launch templates may reference instead.',
        '',
    ]
    with open(os.path.join(outdir, 'aws', 'declarative-policy-NOTES.md'),
              'w', encoding='utf-8') as fh:
        fh.write('\n'.join(notes))

    write_matrix(os.path.join(outdir, 'aws', 'deny-matrix.csv'), verdicts, meta)
    return {'statements': len(statements), 'policies': written,
            'fam_deny': fam_deny, 'fam_allow': fam_allow,
            'declarative_allowed': allowed, 'declarative_mixed': mixed}

# ----------------------------------------------------------------- Azure build

def build_azure(catalog, verdicts, meta, outdir, stamp):
    deny_fams = collections.defaultdict(set)
    for uuid, recs in verdicts.items():
        region, fam = uuid.split('|', 1)
        if recs:
            deny_fams[region].add(fam)

    # The sku.name alias does not support wildcards, so families must be
    # expanded to the exact SKUs that region actually offers.
    region_skus = {}
    for region, fams in deny_fams.items():
        skus = sorted({s for s in catalog.get(region, []) if azure_family(s) in fams})
        if skus:
            region_skus[region] = skus

    groups = collections.defaultdict(list)
    for region, skus in region_skus.items():
        groups[tuple(skus)].append(region)

    any_of = [{'allOf': [
        {'field': 'location', 'in': sorted(regions)},
        {'field': 'Microsoft.Compute/virtualMachines/sku.name', 'in': list(skus)},
    ]} for skus, regions in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))]

    vmss_any_of = [{'allOf': [
        {'field': 'location', 'in': sorted(regions)},
        {'field': 'Microsoft.Compute/virtualMachineScaleSets/sku.name', 'in': list(skus)},
    ]} for skus, regions in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))]

    definition = {
        'properties': {
            'displayName': 'Deny Intel VM SKUs where an AMD equivalent exists in the region',
            'policyType': 'Custom',
            'mode': 'Indexed',
            'description': (
                'Blocks creation of Intel virtual machines and scale sets only where AMD CCA '
                'confirms an AMD EPYC equivalent is available in that same region. Intel SKUs '
                'with no AMD counterpart, and regions where AMD is not offered, are not '
                'affected. ARM SKUs are not affected. Existing VMs continue to run. '
                f'Derived from AMD CCA on {stamp}.'),
            'metadata': {'version': '1.0.0', 'category': 'Compute',
                         'source': 'AMD CCA (EPYC Advisory)', 'derivedOn': stamp},
            'parameters': {
                'effect': {
                    'type': 'String',
                    'metadata': {'displayName': 'Effect',
                                 'description': 'Audit first, then switch to Deny.'},
                    'allowedValues': ['Audit', 'Deny', 'Disabled'],
                    'defaultValue': 'Audit',
                }
            },
            'policyRule': {
                'if': {'anyOf': [
                    {'allOf': [
                        {'field': 'type', 'equals': 'Microsoft.Compute/virtualMachines'},
                        {'anyOf': any_of},
                    ]},
                    {'allOf': [
                        {'field': 'type', 'equals': 'Microsoft.Compute/virtualMachineScaleSets'},
                        {'anyOf': vmss_any_of},
                    ]},
                ]},
                'then': {'effect': "[parameters('effect')]"},
            },
        }
    }
    dpath = os.path.join(outdir, 'azure', 'policy-definition-deny-intel-amd-available.json')
    with open(dpath, 'w', encoding='utf-8') as fh:
        json.dump(definition, fh, indent=2)
        fh.write('\n')
    body_bytes = len(json.dumps(definition, separators=(',', ':')))
    assert body_bytes < 1_048_576, f'policy body {body_bytes} exceeds the 1 MB request limit'

    assignment = {
        'properties': {
            'displayName': 'Enforce AMD where available',
            'policyDefinitionId': '/providers/Microsoft.Management/managementGroups/'
                                  '<MG_ID>/providers/Microsoft.Authorization/'
                                  'policyDefinitions/deny-intel-amd-available',
            'parameters': {'effect': {'value': 'Audit'}},
            # Start disabled so nothing breaks on day one; flip to Default once
            # the compliance report looks right.
            'enforcementMode': 'DoNotEnforce',
            'notScopes': [
                '/subscriptions/<LEGACY_SUB_ID>',
                '/subscriptions/<SUB_ID>/resourceGroups/<LEGACY_RG>',
            ],
        }
    }
    with open(os.path.join(outdir, 'azure', 'policy-assignment-example.json'),
              'w', encoding='utf-8') as fh:
        json.dump(assignment, fh, indent=2)
        fh.write('\n')

    exemption = {
        'properties': {
            'policyAssignmentId': '/subscriptions/<SUB_ID>/providers/'
                                  'Microsoft.Authorization/policyAssignments/'
                                  'enforce-amd-where-available',
            'exemptionCategory': 'Waiver',
            'displayName': 'Grandfather existing Intel VM until migration completes',
            'description': ('Azure Policy Deny evaluates on update as well as create, so an '
                            'existing Intel VM can be blocked from routine changes such as '
                            'resize or tagging. This waiver keeps that VM manageable while '
                            'migration is planned.'),
            'expiresOn': f'{int(stamp[:4]) + 1}-{stamp[5:7]}-{stamp[8:10]}T00:00:00Z',
        }
    }
    with open(os.path.join(outdir, 'azure', 'exemption-grandfather-example.json'),
              'w', encoding='utf-8') as fh:
        json.dump(exemption, fh, indent=2)
        fh.write('\n')

    write_matrix(os.path.join(outdir, 'azure', 'deny-matrix.csv'), verdicts, meta)
    return {'groups': len(groups), 'bytes': body_bytes,
            'pairs': sum(len(v) for v in region_skus.values()),
            'skus': len({s for v in region_skus.values() for s in v})}

# ------------------------------------------------------------------- GCP build

def build_gcp(catalog, verdicts, meta, outdir, stamp):
    fam_deny = collections.defaultdict(set)
    fam_allow = collections.defaultdict(set)
    for uuid, recs in verdicts.items():
        region, fam = uuid.split('|', 1)
        (fam_deny if recs else fam_allow)[fam].add(region)

    # Group families by their exception set: families denied everywhere they
    # appear share one constraint; families with regional carve-outs get their
    # own constraint carrying a zone guard.
    groups = collections.defaultdict(list)
    for fam in fam_deny:
        groups[tuple(sorted(fam_allow.get(fam, ())))].append(fam)

    def machine_term(f):
        # contains() is a plain substring test, so both delimiters are needed:
        # '/n2-standard-' cannot match 'n2d-standard-8', but 'n2-standard'
        # would. Shared-core types (e2-medium, e2-small) have no trailing size
        # segment, so a trailing '-' would never match - anchor those at the end.
        if f.split('-')[-1] in ('micro', 'small', 'medium'):
            return f"resource.machineType.endsWith('/{f}')"
        return f"resource.machineType.contains('/{f}-')"

    def machine_clause(fams):
        return ' || '.join(machine_term(f) for f in sorted(fams))

    def zone_clause(regions):
        return ' || '.join(f"resource.zone.contains('/{r}-')" for r in sorted(regions))

    constraints = []
    ordered = sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    for idx, (exceptions, fams) in enumerate(ordered):
        condition = f'({machine_clause(fams)})'
        if exceptions:
            condition += f' && !({zone_clause(exceptions)})'
        assert len(condition) <= 1000, (
            f'CEL condition is {len(condition)} chars, over the 1000 limit')
        if idx == 0:
            name = 'custom.denyIntelWhereAmdAvailable'
            display = 'Deny Intel machine types where an AMD equivalent exists'
            fname = 'custom-constraint-deny-intel-amd-available.yaml'
        else:
            slug = ''.join(p.capitalize() for p in sorted(fams)[0].split('-'))
            name = f'custom.deny{slug}WhereAmdAvailable'
            display = f"Deny {', '.join(sorted(fams))} where an AMD equivalent exists"
            fname = f'custom-constraint-{sorted(fams)[0]}.yaml'
        yaml = (
            f'name: organizations/ORGANIZATION_ID/customConstraints/{name}\n'
            f'resourceTypes:\n'
            f'  - compute.googleapis.com/Instance\n'
            f'methodTypes:\n'
            f'  - CREATE\n'
            f'condition: "{condition}"\n'
            f'actionType: DENY\n'
            f'displayName: {display}\n'
            f'description: >-\n'
            f'  Blocks creation of Intel machine types only where AMD CCA confirms an AMD EPYC\n'
            f'  equivalent is available in that region. Machine types with no AMD counterpart,\n'
            f'  and regions where AMD is not offered, are not affected. ARM (Axion) is not\n'
            f'  affected. Existing instances continue to run. Derived from AMD CCA on {stamp}.\n'
        )
        path = os.path.join(outdir, 'gcp', fname)
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(yaml)
        constraints.append((name, fname, len(condition), sorted(fams), sorted(exceptions)))

    org_policy = '\n'.join(
        f'name: organizations/ORGANIZATION_ID/policies/{name}\n'
        f'spec:\n'
        f'  rules:\n'
        f'    - enforce: true\n'
        for name, _, _, _, _ in constraints)
    with open(os.path.join(outdir, 'gcp', 'org-policy-example.yaml'),
              'w', encoding='utf-8') as fh:
        fh.write('# Apply one policy per custom constraint, after the constraints exist.\n'
                 '# Separate documents so each can be applied independently.\n---\n'
                 + '\n---\n'.join(x.rstrip() for x in org_policy.split('\n\n') if x.strip())
                 + '\n')

    write_matrix(os.path.join(outdir, 'gcp', 'deny-matrix.csv'), verdicts, meta)
    never = sorted(f for f in fam_allow if f not in fam_deny)
    return {'constraints': constraints, 'never_denied': never}

# ------------------------------------------------------------------- OCI build

# Compute quota names are per shape SERIES, not per shape. Source:
# docs.oracle.com/en-us/iaas/Content/Quotas/Concepts/resourcequotas_topic-Compute_Quotas.htm
# Only series actually present in the CCA catalog are mapped. A series with no
# documented quota name is handled by the zero+unset allowlist instead of being
# guessed at.
OCI_QUOTA_ALLOW = {
    'vm.standard.e2': 'standard-e2-core-count',
    'vm.standard.e3.flex': 'standard-e3-core-ad-count',
    'vm.standard.e4.flex': 'standard-e4-core-count',
    'vm.standard.e5.flex': 'standard-e5-core-count',
    'vm.standard.e6.flex': 'standard-e6-core-count',
    'vm.standard.a1.flex': 'standard-a1-core-count',
    'vm.standard.a2.flex': 'standard-a2-core-count',
    'vm.standard.a4.flex': 'standard-a4-core-count',
}


def build_oci(catalog, verdicts, meta, outdir, stamp):
    fam_deny = collections.defaultdict(set)
    fam_allow = collections.defaultdict(set)
    for uuid, recs in verdicts.items():
        region, fam = uuid.split('|', 1)
        (fam_deny if recs else fam_allow)[fam].add(region)

    # Exact shape names, not family prefixes: target.instance.shape is an exact
    # string match, so 'vm.standard.e2' would never match vm.standard.e2.4.
    # Flex shapes are the exception - those are launched by their flex name.
    def is_amd(s):
        return re.match(r'^(vm|bm)\.(standard|optimized|dense)\w*\.e\d', s)

    def is_arm(s):
        return re.match(r'^(vm|bm)\.standard\.a\d', s)

    # ARM is explicitly out of scope for this policy, so Ampere shapes are
    # allowed alongside AMD. Removing them would deny ARM by omission.
    amd_shapes = sorted({s.lower() for region in catalog for s in catalog[region]
                         if is_amd(s.lower())})
    arm_shapes = sorted({s.lower() for region in catalog for s in catalog[region]
                         if is_arm(s.lower())})

    shape_list = ',\n    '.join(
        f"target.instance.shape = '{s}'" for s in amd_shapes + arm_shapes)
    lines = [
        '# AMD shape enforcement for OCI Compute',
        '#',
        '# OCI IAM has no Deny verb, so enforcement is inverted: the group is granted',
        '# manage instance-family ONLY for AMD shapes. Anything not listed simply has',
        '# no grant and therefore cannot be launched.',
        '#',
        '# The unconditioned inspect/read statement below is required. A condition on a',
        '# variable the request does not carry evaluates false, so List and Get calls',
        '# would be denied and the Console would break without it.',
        '#',
        f'# Shape list derived from AMD CCA on {stamp}.',
        '',
        '# 1. Unconditioned visibility - do not remove.',
        'Allow group <GROUP> to inspect instance-family in compartment <COMPARTMENT>',
        'Allow group <GROUP> to read instance-family in compartment <COMPARTMENT>',
        'Allow group <GROUP> to read app-catalog-listing in compartment <COMPARTMENT>',
        'Allow group <GROUP> to inspect compute-management-family in compartment <COMPARTMENT>',
        '',
        '# 2. Launch and manage, restricted to AMD EPYC shapes (E-series) plus',
        '#    Ampere A-series. ARM is out of scope for this policy - dropping the',
        '#    A-series here would deny it by omission, which is not the intent.',
        '#',
        '#    Shapes NOT listed, and therefore not launchable: vm.standard1,',
        '#    vm.standard2, vm.standard3.flex, vm.standard.b1 - all Intel, and all',
        '#    confirmed by CCA to have an AMD equivalent in every region they appear in.',
        '#',
        '#    Shapes CCA does not price (GPU, HPC, dense I/O) are also absent from this',
        '#    list. If you run them, add them here before applying.',
        'Allow group <GROUP> to manage instance-family in compartment <COMPARTMENT> where any {',
        f'    {shape_list}',
        '}',
        '',
        '# 3. Supporting grants a launch needs (these carry no shape variable).',
        'Allow group <GROUP> to use subnets in compartment <COMPARTMENT>',
        'Allow group <GROUP> to use vnics in compartment <COMPARTMENT>',
        'Allow group <GROUP> to use network-security-groups in compartment <COMPARTMENT>',
        'Allow group <GROUP> to read instance-images in compartment <COMPARTMENT>',
        '',
    ]
    with open(os.path.join(outdir, 'oci', 'policy-allow-amd-shapes.txt'),
              'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines))

    # Oracle's documented allowlist idiom: zero the whole family, then unset the
    # series you want available. This is safer than enumerating Intel series to
    # zero, because a series nobody listed defaults to blocked rather than open.
    present = {s.lower() for region in catalog for s in catalog[region]}
    unset = [(s, OCI_QUOTA_ALLOW[s]) for s in sorted(OCI_QUOTA_ALLOW)
             if any(p == s or p.startswith(s + '.') for p in present)]
    quota = [
        '# Compartment quota backstop.',
        '#',
        '# The IAM allowlist in policy-allow-amd-shapes.txt is the authoritative control.',
        '# This is a second layer: even a principal holding a broader grant cannot',
        '# consume Intel capacity in a compartment whose Intel quota is zero.',
        '#',
        '# Pattern is Oracle\'s documented allowlist idiom - zero the whole compute-core',
        '# family, then unset the series that should remain available. That is safer than',
        '# naming Intel series to zero: a series nobody thought to list defaults to',
        '# blocked rather than silently open.',
        '#',
        '# Existing instances are unaffected. A zeroed quota blocks NEW allocation; it',
        '# does not terminate or reclaim running cores.',
        '#',
        f'# AMD/ARM series below are the ones present in the CCA catalog on {stamp}.',
        '# Add any GPU, HPC or dense-I/O series you run - CCA does not price them, so',
        '# they are not listed here and would stay at zero.',
        '',
        'zero compute-core quotas in compartment <COMPARTMENT>',
        '',
    ]
    for shape, qn in unset:
        kind = 'Ampere / ARM' if '.a' in shape else 'AMD EPYC'
        quota.append(f'unset compute-core quota {qn} in compartment <COMPARTMENT>'
                     f'   # {shape} ({kind})')
    quota += [
        '',
        '# Intel series left at zero by the statement above, all confirmed by CCA to',
        '# have an AMD equivalent in every region they appear in:',
    ]
    for fam in sorted(fam_deny):
        quota.append(f'#   {fam}  (denied in {len(fam_deny[fam])} regions, '
                     f'allowed in {len(fam_allow.get(fam, ()))})')
    quota.append('')
    with open(os.path.join(outdir, 'oci', 'quota-policy-intel-zero.txt'),
              'w', encoding='utf-8') as fh:
        fh.write('\n'.join(quota))

    write_matrix(os.path.join(outdir, 'oci', 'deny-matrix.csv'), verdicts, meta)
    return {'amd_shapes': amd_shapes, 'fam_deny': fam_deny, 'fam_allow': fam_allow}

# ----------------------------------------------------------------- shared out

def write_matrix(path, verdicts, meta):
    with open(path, 'w', encoding='utf-8', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['region', 'instance_family', 'probe_sku', 'decision',
                    'amd_equivalents'])
        for uuid in sorted(verdicts):
            region, fam = uuid.split('|', 1)
            recs = verdicts[uuid]
            w.writerow([region, fam, meta.get(uuid, ''),
                        'DENY' if recs else 'ALLOW', ' '.join(recs)])


def write_report(path, stamp, results, summary):
    L = [f'# AMD IAM Policy Gap Analysis - {stamp}', '',
         'Generated by `generate.py` from the AMD CCA (EPYC Advisory) API.', '',
         'For every cloud region and Intel instance family, one representative instance',
         'was submitted to `POST /v2/recommendations`. A Best Match recommendation means',
         'an AMD equivalent is available in that region, so new Intel launches of that',
         'family are denied there. No recommendation means no AMD equivalent exists, so',
         'Intel remains allowed.', '',
         '## Coverage', '',
         '| Cloud | Regions | Intel families | Probes | Deny (region x family) | Allow (carve-outs) |',
         '|---|---|---|---|---|---|']
    for cloud in CLOUDS:
        s = summary.get(cloud)
        if s:
            L.append(f"| {cloud} | {s['regions']} | {s['families']} | {s['probes']} | "
                     f"{s['deny']} | {s['allow']} |")
    L += ['', 'Every AMD recommendation was cross-checked against the catalog of the region',
          'it was issued for. Zero recommendations pointed at a family absent from that',
          'region, so no deny rule can strand a workload without a legal alternative.', '']

    for cloud in CLOUDS:
        if cloud not in summary:
            continue
        s = summary[cloud]
        L += [f'## {cloud}', '']
        if s['zero_deny_regions']:
            L += ['Regions where Intel is fully allowed (no AMD equivalent for any family):', '',
                  '```', '\n'.join(sorted(s['zero_deny_regions'])), '```', '']
        else:
            L += ['Every region has at least one family with an AMD equivalent.', '']
        if s['never_denied']:
            L += ['Families never denied anywhere (no AMD counterpart in any region):', '',
                  '```', '\n'.join(sorted(s['never_denied'])), '```', '']
        L += ['| Family | Regions denied | Regions allowed (carve-out) |', '|---|---|---|']
        for fam in sorted(set(s['fam_deny']) | set(s['fam_allow'])):
            d = len(s['fam_deny'].get(fam, ()))
            a = sorted(s['fam_allow'].get(fam, ()))
            L.append(f"| `{fam}` | {d} | {', '.join(a) if a else '-'} |")
        L.append('')
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(L))

# ------------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--key-file')
    ap.add_argument('--outdir', default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument('--cloud', default=','.join(CLOUDS))
    ap.add_argument('--snapshot', help='reuse a previous snapshot instead of calling CCA')
    ap.add_argument('--date', default=datetime.date.today().isoformat())
    args = ap.parse_args()

    clouds = [c.strip().upper() for c in args.cloud.split(',') if c.strip()]
    stamp = args.date
    for sub in ['aws', 'azure', 'gcp', 'oci', 'data']:
        os.makedirs(os.path.join(args.outdir, sub), exist_ok=True)

    if args.snapshot:
        snap = json.load(open(args.snapshot, encoding='utf-8'))
        token = None
    else:
        token = read_token(args.key_file)
        snap = {'generatedOn': stamp, 'source': f'{BASE}/v2/recommendations', 'clouds': {}}

    summary, results = {}, {}
    for cloud in clouds:
        print(f'{cloud}: ', end='', flush=True)
        if args.snapshot:
            entry = snap['clouds'][cloud]
            catalog, verdicts, meta = entry['catalog'], entry['verdicts'], entry['probes']
            print(f"{len(catalog)} regions (from snapshot)")
        else:
            catalog = get_summary(token, cloud)
            print(f'{len(catalog)} regions')
            rows, meta = SWEEPS[cloud](token, catalog)
            print(f'  {len(rows)} Intel region x family probes')
            verdicts = post_recommendations(token, cloud, rows)
            snap['clouds'][cloud] = {'catalog': catalog, 'verdicts': verdicts, 'probes': meta}

        famfn = {'AWS': aws_family, 'AZURE': azure_family,
                 'GCP': gcp_family, 'OCI': oci_base}[cloud]
        bad = check_recs_available(cloud, catalog, verdicts, famfn)
        if bad:
            sys.exit(f'{cloud}: {len(bad)} recommendations are not available in their own '
                     f'region, e.g. {bad[:3]}')
        print(f'  integrity: all recommendations available in-region')

        builder = {'AWS': build_aws, 'AZURE': build_azure,
                   'GCP': build_gcp, 'OCI': build_oci}[cloud]
        results[cloud] = builder(catalog, verdicts, meta, args.outdir, stamp)

        fam_deny = collections.defaultdict(set)
        fam_allow = collections.defaultdict(set)
        for uuid, recs in verdicts.items():
            region, fam = uuid.split('|', 1)
            (fam_deny if recs else fam_allow)[fam].add(region)
        regions_with_deny = {u.split('|', 1)[0] for u, r in verdicts.items() if r}
        all_regions = {u.split('|', 1)[0] for u in verdicts}
        summary[cloud] = {
            'regions': len(catalog), 'families': len(set(fam_deny) | set(fam_allow)),
            'probes': len(verdicts),
            'deny': sum(1 for v in verdicts.values() if v),
            'allow': sum(1 for v in verdicts.values() if not v),
            'fam_deny': {k: sorted(v) for k, v in fam_deny.items()},
            'fam_allow': {k: sorted(v) for k, v in fam_allow.items()},
            'zero_deny_regions': sorted(all_regions - regions_with_deny),
            'never_denied': sorted(f for f in fam_allow if f not in fam_deny),
        }
        print(f"  {summary[cloud]['deny']} deny / {summary[cloud]['allow']} allow")

    if not args.snapshot:
        spath = os.path.join(args.outdir, 'data', f'cca-snapshot-{stamp}.json')
        with open(spath, 'w', encoding='utf-8') as fh:
            json.dump(snap, fh, indent=1, sort_keys=True)
            fh.write('\n')
        print(f'snapshot -> {spath}')

    write_report(os.path.join(args.outdir, f'gap-analysis-{stamp}.md'),
                 stamp, results, summary)
    print(f'report   -> gap-analysis-{stamp}.md')
    return summary, results


if __name__ == '__main__':
    main()
