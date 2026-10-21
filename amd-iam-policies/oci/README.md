# OCI — IAM Policy + Compartment Quotas

Restricts instance launches to **AMD EPYC and Ampere shapes**, because AMD CCA confirms every Intel shape family on OCI has an AMD equivalent in every region it appears in.

| File | What it is |
|------|------------|
| [`policy-allow-amd-shapes.txt`](policy-allow-amd-shapes.txt) | The IAM policy — the authoritative control |
| [`quota-policy-intel-zero.txt`](quota-policy-intel-zero.txt) | Compartment quota backstop |
| [`deny-matrix.csv`](deny-matrix.csv) | Every region × family, the probe used, and the verdict |

## What this policy does

**OCI IAM has no `Deny` verb.** You can't write "deny Intel" — the only available shape is a grant. So enforcement is inverted: grant `manage instance-family` only for the shapes you want, and anything unlisted has no grant and therefore can't be launched.

```
Allow group <GROUP> to manage instance-family in compartment <COMPARTMENT> where any {
    target.instance.shape = 'vm.standard.e4.flex',
    target.instance.shape = 'vm.standard.e5.flex',
    ...
}
```

Shapes are matched **exactly**, so the list enumerates real shape names — `vm.standard.e2.1` through `vm.standard.e2.8` individually, because `vm.standard.e2` is a series name, not a launchable shape.

### The unconditioned `inspect` statement is mandatory

```
Allow group <GROUP> to inspect instance-family in compartment <COMPARTMENT>
Allow group <GROUP> to read instance-family in compartment <COMPARTMENT>
```

**Do not remove these.** A condition on a variable the request doesn't carry evaluates to *false*. `ListInstances` and `GetInstance` carry no `target.instance.shape`, so with only the conditional statement above, every list and get would be denied — the Console breaks, the CLI returns empty, and the group can't see the instances it owns.

### ARM is in the allow-list on purpose

```
target.instance.shape = 'vm.standard.a1.flex'
target.instance.shape = 'vm.standard.a2.flex'
target.instance.shape = 'vm.standard.a4.flex'
```

ARM is out of scope for this policy pack. On AWS, Azure and GCP that's automatic — those are deny-lists, and ARM simply isn't on them. On OCI, an allow-list means **omission is denial**. Dropping the Ampere shapes would block ARM, which is not the intent, so they're listed explicitly.

### The carve-outs

There are no regional carve-outs on OCI, and that's a finding rather than an omission. All four Intel shape families have an AMD equivalent (E4/E5/E6 Flex) in **every** region where they appear:

| Intel family | Regions denied | Regions allowed |
|--------------|----------------|-----------------|
| `vm.standard1` | 3 | 0 |
| `vm.standard2` | 33 | 0 |
| `vm.standard3.flex` | 43 | 0 |
| `vm.standard.b1` | 6 | 0 |

Two regions — `af-casablanca-1` and `eu-turin-1` — offer no Intel shapes at all, so there's nothing to deny there.

## How the list was derived

85 probes against AMD CCA on **2026-10-21** — one per region × Intel shape family. OCI flex shapes are rejected by the API without explicit `ocpu` and `memory` values, so probes are submitted at 8 OCPU / 64 GB; CCA normalizes those to sized names (`vm.standard.e4.flex.8-64`) in its response.

Every recommendation was confirmed present in the catalog of the region it was issued for.

## How to apply it

### 1. Edit the placeholders

Replace `<GROUP>` and `<COMPARTMENT>` throughout [`policy-allow-amd-shapes.txt`](policy-allow-amd-shapes.txt). Use `tenancy` instead of `in compartment <COMPARTMENT>` for tenancy-wide scope.

### 2. Create the policy

```bash
oci iam policy create \
  --compartment-id <COMPARTMENT_OCID> \
  --name enforce-amd-shapes \
  --description "Restrict launches to AMD EPYC and Ampere shapes" \
  --statements file://policy-allow-amd-shapes.txt
```

The `--statements` file must be a JSON array of strings — strip the comment lines first, or paste the statements into the Console policy editor, which handles them directly.

**Scope is set by where you attach it.** A policy in the tenancy (root compartment) applies everywhere; a policy in a child compartment applies to that subtree.

### 3. Test on a non-production group first

Create a test group, attach the policy to a sandbox compartment, and confirm both directions:

```bash
oci compute instance launch --shape VM.Standard.E5.Flex \
  --compartment-id <SANDBOX_OCID> ... # expect success
```

```bash
oci compute instance launch --shape VM.Standard3.Flex \
  --compartment-id <SANDBOX_OCID> ... # expect NotAuthorizedOrNotFound
```

Also confirm the Console still lists instances — that's the check that the unconditioned `inspect` statement is doing its job.

### 4. Optional: add the quota backstop

```bash
oci limits quota create \
  --compartment-id <TENANCY_OCID> \
  --name zero-intel-cores \
  --description "Zero Intel compute cores; allow AMD and Ampere" \
  --statements file://quota-policy-intel-zero.txt
```

[`quota-policy-intel-zero.txt`](quota-policy-intel-zero.txt) uses Oracle's documented allow-list idiom — zero the whole `compute-core` family, then `unset` the series that should stay available:

```
zero compute-core quotas in compartment <COMPARTMENT>
unset compute-core quota standard-e5-core-count in compartment <COMPARTMENT>
unset compute-core quota standard-a1-core-count in compartment <COMPARTMENT>
```

That's deliberately safer than naming Intel series to zero: a series nobody thought to list defaults to blocked rather than silently open.

**It's also stricter than the IAM policy.** CCA doesn't price GPU, HPC or dense-I/O series, so they aren't in the `unset` list and would stay at zero. Add the series you actually run before applying — the file notes this inline.

## What it does *not* do

**It does not touch running instances.** Removing a grant stops *new* launches. Existing instances keep running. A zeroed quota blocks new core allocation; it does not reclaim allocated cores.

**It does not block ARM.** Ampere shapes are explicitly allowed.

**It does not restrict shapes CCA doesn't price.** GPU (`vm.gpu*`, `bm.gpu*`), HPC (`bm.optimized3.36`) and dense-I/O (`vm.dense*`) shapes are absent from CCA's catalog, so they're absent from the allow-list — which on an allow-list means they're **blocked**. If you run them, add them to the `where any { ... }` block before applying.

**It does not override a broader grant elsewhere.** OCI evaluates the union of all policies that apply. If another policy grants the same group unconditional `manage instance-family` on an ancestor compartment, that grant wins and this one adds nothing. Audit for overlapping grants before relying on this:

```bash
oci iam policy list --compartment-id <TENANCY_OCID> --all
```

The quota backstop exists precisely for this case — it constrains consumption regardless of what the IAM grants say.

**It does not expire.** The shape list reflects the CCA catalog on 2026-10-21. Re-run `generate.py` from the repo root to pick up new AMD shapes.
