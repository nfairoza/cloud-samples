# GCP — Custom Organization Policy Constraints

Denies creation of Intel machine types **in the regions where AMD CCA confirms an AMD EPYC equivalent is available**, and nowhere else.

| File | What it is |
|------|------------|
| [`custom-constraint-deny-intel-amd-available.yaml`](custom-constraint-deny-intel-amd-available.yaml) | 15 families denied in every region that offers them (CEL: 734 chars) |
| [`custom-constraint-c4-standard.yaml`](custom-constraint-c4-standard.yaml) | `c4-standard`, with a zone guard for its two carve-out regions (CEL: 144 chars) |
| [`org-policy-example.yaml`](org-policy-example.yaml) | The policies that turn both constraints on |
| [`deny-matrix.csv`](deny-matrix.csv) | Every region × family, the probe used, and the verdict |

Two constraints against GCP's ~20-per-resource-type cap, both well inside the 1,000-character CEL limit.

## What these constraints do

Both target `compute.googleapis.com/Instance` with `methodTypes: [CREATE]` and `actionType: DENY`, matching on `resource.machineType`:

```yaml
condition: "(resource.machineType.contains('/n2-standard-') || ...)"
actionType: DENY
```

655 region × family combinations denied across 42 regions.

**The first constraint** covers 15 families that have an AMD equivalent in every region offering them, so it needs no regional logic:

```
c2-standard   c3-highcpu   c3-highmem   c3-standard
e2-highcpu    e2-highmem   e2-medium    e2-small      e2-standard
n1-highcpu    n1-highmem   n1-standard
n2-highcpu    n2-highmem   n2-standard
```

**The second constraint** is `c4-standard`, which has an AMD equivalent in 41 regions but not in `asia-southeast3` or `europe-west10`. It carries a zone guard so those two stay open:

```
(resource.machineType.contains('/c4-standard-'))
  && !(resource.zone.contains('/asia-southeast3-')
       || resource.zone.contains('/europe-west10-'))
```

### Watch the substring matching

`contains()` is a plain substring test, with two traps the generator handles:

**Both delimiters are required.** `contains('n2-standard')` would also match `n2d-standard-8` — and `n2d` is AMD. Every pattern is written as `'/n2-standard-'` with the leading slash and trailing hyphen so the match can't bleed into a neighbouring series.

**Shared-core types have no trailing segment.** `e2-medium` and `e2-small` are complete machine type names; `'/e2-medium-'` would never match anything. Those use `endsWith('/e2-medium')` instead.

### The carve-outs, as guarantees

**Six families appear in no constraint** — CCA found no AMD equivalent for them in any region:

```
c4-highcpu    c4-highmem    e2-micro
n4-highcpu    n4-highmem    n4-standard
```

**`asia-southeast3` has no denials at all.** It's the one GCP region where Intel is fully permitted — `c4-standard` was its only candidate, and the zone guard excludes it.

**ARM is untouched.** Axion (`c4a`, `n4a`) and `t2a` are classified ARM, never probed, and appear in no constraint. `t2d` is AMD EPYC Milan despite its naming and is likewise excluded from the deny set.

Per-region detail is in [`deny-matrix.csv`](deny-matrix.csv).

## How the list was derived

908 probes against AMD CCA on **2026-10-21** — one per region × Intel family-class, at 16 vCPU where offered. Probing is at family-class granularity (`n2-standard`, `c3-highmem`) rather than series, because CCA's answer differs between classes: `c4-standard` has an equivalent in 41 regions while `c4-highcpu` and `c4-highmem` have none anywhere.

Size is not a factor — within a class, every vCPU count returns the same AMD series.

GPU and accelerator-attached machine types (`a2-*`, `a3-*`, `g2-*`) are not in CCA's catalog, were never probed, and are named in no constraint.

## How to apply it

### 1. Create both custom constraints

Replace `ORGANIZATION_ID` in each file first, then:

```bash
gcloud org-policies set-custom-constraint custom-constraint-deny-intel-amd-available.yaml
```

```bash
gcloud org-policies set-custom-constraint custom-constraint-c4-standard.yaml
```

Custom constraints are always defined at the **organization** level — that's a GCP requirement, not a choice.

### 2. Dry-run before enforcing

```bash
gcloud org-policies set-policy org-policy-example.yaml --dry-run
```

Then check what it would have blocked:

```bash
gcloud logging read \
  'protoPayload.status.message=~"customConstraints/custom.denyIntel"' \
  --limit 50 --format json
```

### 3. Enforce, at whatever scope you want

The constraint is org-level; the **policy** that enables it can be attached anywhere:

| Scope | `name:` in the policy file |
|-------|---------------------------|
| Organization | `organizations/<ORG_ID>/policies/custom.denyIntelWhereAmdAvailable` |
| Folder | `folders/<FOLDER_ID>/policies/custom.denyIntelWhereAmdAvailable` |
| Project | `projects/<PROJECT_ID>/policies/custom.denyIntelWhereAmdAvailable` |

```bash
gcloud org-policies set-policy org-policy-example.yaml
```

To exempt a project under an enforcing organization, set a policy at that project with `enforce: false`:

```yaml
name: projects/<PROJECT_ID>/policies/custom.denyIntelWhereAmdAvailable
spec:
  rules:
    - enforce: false
```

## What it does *not* do

**It does not touch running instances.** `methodTypes: [CREATE]` means the constraint is evaluated only on instance creation. Existing instances keep running, and stop/start cycles are not creates.

**It does not block ARM.** Axion is unaffected by design.

**It does not cover `UPDATE`.** Changing an existing instance's machine type to a denied Intel type is not blocked, because the constraint only registers for `CREATE`. Adding `UPDATE` to `methodTypes` would close that — but it would also catch legitimate maintenance on existing Intel instances, which is exactly the disruption this pack avoids. The trade-off is deliberate; change it if your rollout is far enough along.

**It does not cover GKE node pools directly.** A node pool creates instances through a managed instance group, and whether the constraint fires depends on how the MIG issues the call. Test in a dry-run project before assuming coverage.

**It does not expire.** The lists reflect AMD availability on 2026-10-21 — notably, `c4-highcpu`, `c4-highmem` and the whole `n4` series have no AMD equivalent *yet*. Re-run `generate.py` from the repo root to pick up changes.
