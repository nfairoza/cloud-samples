# AWS — Service Control Policy

Denies `ec2:RunInstances` for Intel instance families **in the regions where AMD CCA confirms an AMD EPYC equivalent is available**, and nowhere else.

| File | What it is |
|------|------------|
| [`scp-deny-intel-amd-available-1.json`](scp-deny-intel-amd-available-1.json) | SCP, 15 statements, 5,036 bytes |
| [`scp-deny-intel-amd-available-2.json`](scp-deny-intel-amd-available-2.json) | SCP, 3 statements, 782 bytes — the overflow from the 5,120-byte limit |
| [`declarative-policy-allowed-instance-types.json`](declarative-policy-allowed-instance-types.json) | Declarative Policy — covers the Auto Scaling gap, **read the notes first** |
| [`declarative-policy-NOTES.md`](declarative-policy-NOTES.md) | Why that file is stricter than the SCP and what you must add before applying it |
| [`deny-matrix.csv`](deny-matrix.csv) | Every region × family, the probe used, and the verdict |

Both SCPs attach at the same target and compose. The split exists only because AWS caps an SCP at 5,120 bytes.

## What this policy does

Blocks `RunInstances` for 24 Intel families across 22 regions — 291 region × family combinations. A statement looks like this:

```json
{
  "Sid": "DenyIntelWhereAmdEquivalentExists1",
  "Effect": "Deny",
  "Action": "ec2:RunInstances",
  "Resource": "arn:aws:ec2:*:*:instance/*",
  "Condition": {
    "StringLike": { "ec2:InstanceType": ["c5.*", "m5.*", "r5.*", "t3.*"] },
    "StringEquals": { "aws:RequestedRegion": ["us-east-1", "us-west-2"] }
  }
}
```

`Resource` is scoped to `instance/*` deliberately. A single `RunInstances` call touches the AMI, subnet, security group and ENI ARNs as well — `"Resource": "*"` would deny all of them and block **every** launch, including the AMD ones you're trying to encourage.

Regions that share an identical deny-set are collapsed into one statement, which is what keeps this inside the byte limit.

### The two carve-outs, as guarantees

**Regions where Intel is fully allowed** — CCA found no AMD equivalent for any family, so these regions appear in no statement:

```
af-south-1       ap-northeast-3   ap-southeast-3   ap-southeast-4
ap-southeast-5   ap-southeast-6   ap-southeast-7   ca-west-1
eu-central-2     me-central-1     mx-central-1
```

**Families allowed in some regions and denied in others** — the policy is per region, so a family denied in `us-east-1` can still launch in `ap-northeast-2`:

| Family | Denied in | Allowed in | Family | Denied in | Allowed in |
|--------|-----------|------------|--------|-----------|------------|
| `c1` | 8 | 0 | `m6i` | 17 | 14 |
| `c3` | 9 | 0 | `m7i` | 12 | 20 |
| `c4` | 10 | 5 | `m8i` | 11 | 10 |
| `c5` | 17 | 11 | `r3` | 10 | 2 |
| `c6i` | 16 | 12 | `r4` | 12 | 4 |
| `c7i` | 11 | 22 | `r5` | 15 | 13 |
| `c8i` | 11 | 10 | `r6i` | 15 | 15 |
| `m1` | 8 | 0 | `r7i` | 11 | 16 |
| `m2` | 8 | 0 | `r8i` | 10 | 16 |
| `m3` | 9 | 0 | `t1` | 8 | 0 |
| `m4` | 13 | 2 | `t2` | 15 | 1 |
| `m5` | 18 | 10 | `t3` | 17 | 15 |

Per-region detail is in [`deny-matrix.csv`](deny-matrix.csv).

## How the list was derived

489 probes against AMD CCA on **2026-10-21** — one per region × Intel family, at a representative large size (`8xlarge` where offered, falling back down a preference ladder). A Best Match recommendation means an AMD equivalent is available in that region; no recommendation means there isn't one.

Size is not a factor. All eight `af-south-1` c5 sizes return nothing; all eight `us-east-1` m5 sizes return a recommendation. Even the extremes agree — `t3.nano` → `t3a.nano`, `m5.metal` → `m8a.metal-24xl`, `r8i.metal-48xl` → `r8a.metal-48xl`.

Graviton families (`a1`, `c6g`, `c7g`, `c8g`, `m6g`, `m7g`, `m8g`, `r6g`, `r7g`, `r8g`, `t4g`) are filtered out before probing and appear in no statement.

CCA's catalog covers 48 general-purpose, compute-optimized and memory-optimized families. Storage, GPU, HPC and accelerated families — `i3`, `i4i`, `m5d`, `r5d`, `d3`, `g4dn`, `g5`, `p5`, `inf2`, `trn1`, `x2idn`, `z1d`, `u-*`, `hpc6a` — are **not in the catalog**, were never probed, and are named in no statement. They launch normally.

## How to apply it

### Enable SCPs (once per organization)

```bash
aws organizations enable-policy-type \
  --root-id r-xxxx --policy-type SERVICE_CONTROL_POLICY
```

### Create and attach both policies

```bash
aws organizations create-policy \
  --name AMD-Deny-Intel-1 --type SERVICE_CONTROL_POLICY \
  --description "Deny Intel where an AMD equivalent exists (1/2)" \
  --content file://scp-deny-intel-amd-available-1.json
```

```bash
aws organizations create-policy \
  --name AMD-Deny-Intel-2 --type SERVICE_CONTROL_POLICY \
  --description "Deny Intel where an AMD equivalent exists (2/2)" \
  --content file://scp-deny-intel-amd-available-2.json
```

```bash
aws organizations attach-policy --policy-id p-xxxx --target-id ou-xxxx-xxxxxxxx
```

`--target-id` takes an **OU id**, an **account id**, or the root id — that's your scope control.

**Attach at an OU, not the root.** A root attachment also covers the management account, where SCPs famously don't apply the way people expect, and leaves you no escape hatch if the policy misbehaves. Put your break-glass account in an OU that doesn't carry this policy.

### Verify before enforcing

```bash
aws accessanalyzer validate-policy \
  --policy-type SERVICE_CONTROL_POLICY \
  --policy-document file://scp-deny-intel-amd-available-1.json
```

Then confirm the behaviour in both directions:

```bash
aws ec2 run-instances --dry-run --region us-east-1 \
  --instance-type m5.large --image-id ami-xxxxxxxx
```

Expect `UnauthorizedOperation` in `us-east-1` (denied) and `DryRunOperation` in `af-south-1` (allowed). Check any pair against [`deny-matrix.csv`](deny-matrix.csv) first.

## What it does *not* do

**It does not touch running instances.** `RunInstances` is a create-time action. Existing Intel instances keep running, keep restarting, and keep resizing. There is no sweep and no termination anywhere in this folder.

**It does not block ARM.** Graviton is unaffected by design.

**It does not cover Auto Scaling.** When an ASG scales out through the `AWSServiceRoleForAutoScaling` service-linked role, that launch **is not evaluated against SCPs**. An ASG with an Intel launch template keeps scaling regardless of this policy. Two ways to close that:

- Restrict which instance types your launch templates and ASG mixed-instances policies may reference. This is the targeted fix and it keeps the regional carve-outs intact.
- Apply [`declarative-policy-allowed-instance-types.json`](declarative-policy-allowed-instance-types.json), which **does** cover the SLR — but read [`declarative-policy-NOTES.md`](declarative-policy-NOTES.md) first. Declarative Policies have no region condition key and only know the families CCA prices, so applying that file as-is is **stricter than this policy**: it enforces the deny set in every region, and it blocks GPU/storage/HPC families unless you append them.

**It does not stop a `RunInstances` call that never reaches the account** — SCPs filter what principals in the account may do; they are not a billing or marketplace control.

**It does not expire.** The list reflects AMD availability on 2026-10-21. As AMD lands in new regions, more families become deniable. Re-run `generate.py` from the repo root and re-upload both policies to pick that up.
