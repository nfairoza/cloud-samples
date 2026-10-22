# Azure — Azure Policy

Denies creation of Intel VMs and scale sets **in the regions where AMD CCA confirms an AMD EPYC equivalent is available**, and nowhere else.

| File | What it is |
|------|------------|
| [`policy-definition-deny-intel-amd-available.json`](policy-definition-deny-intel-amd-available.json) | The policy definition. `effect` is a parameter, defaulting to `Audit` |
| [`policy-assignment-example.json`](policy-assignment-example.json) | Assignment template with `notScopes` and `enforcementMode` |
| [`exemption-grandfather-example.json`](exemption-grandfather-example.json) | Per-resource waiver with a built-in expiry |
| [`deny-matrix.csv`](deny-matrix.csv) | Every region × family, the probe used, and the verdict |

## What this policy does

Matches `Microsoft.Compute/virtualMachines` and `Microsoft.Compute/virtualMachineScaleSets` where **both** conditions hold: `location` is in a region AMD has reached, and `sku.name` is in that region's Intel deny-list.

```json
{
  "allOf": [
    { "field": "location", "in": ["eastus", "westus2"] },
    { "field": "Microsoft.Compute/virtualMachines/sku.name",
      "in": ["Standard_D8s_v5", "Standard_D16s_v5", "..."] }
  ]
}
```

The `sku.name` alias **does not support wildcards**, so families have to be expanded into exact SKU lists. 13,994 region → SKU pairs collapse into 20 distinct SKU-sets. The resulting definition is ~198 KB — comfortably inside Azure's 1,048,576-byte request-body limit, with nesting depth around 41 against the 512 cap.

48 Intel families are denied, across all 53 regions. Azure is the one cloud where every region has at least one family with an AMD equivalent — there is no fully-exempt region here, unlike AWS and GCP.

### The carve-outs, as guarantees

**13 Intel families have no AMD equivalent anywhere and appear in no SKU list:**

| Family | Regions offering it | Why |
|--------|--------------------|-----|
| `Standard_D*_v7`, `Standard_D*s_v7`, `Standard_D*ds_v7` | 24 | Newest Intel generation; no AMD counterpart in CCA yet |
| `Standard_D*ls_v7`, `Standard_D*lds_v7` | 24 | ″ |
| `Standard_E*_v7`, `Standard_E*s_v7`, `Standard_E*ds_v7` | 24 | ″ |
| `Standard_E*is_v7`, `Standard_E*ids_v7` | 24 | ″ |
| `Standard_DC*_v2`, `Standard_DC*s_v2` | 14 | Intel SGX confidential compute — no AMD counterpart |
| `Standard_A*_v2`, `Standard_D*_v2` | 52 | Legacy; CCA returns no recommendation |
| `Standard_B*ts_v2` | 51 | Burstable tier; no recommendation |

These will become deniable as AMD equivalents ship. Re-run `generate.py` to pick that up.

> **Confidential compute is partially denied, and that's intentional.** `DC*s_v3` and `DC*es_v6` *are* in the deny-list, because CCA maps them to `EC*as_v6` — AMD SEV-SNP, a real confidential-compute equivalent. Only the SGX-based `_v2` generation has no counterpart. If your workload depends on SGX enclave attestation specifically rather than on confidential compute generally, exempt those VMs before enforcing — SEV-SNP is a different trust model, not a drop-in for enclave code.

**ARM is untouched.** Any SKU with a `p` attribute (`Standard_D8ps_v5`, Cobalt/Ampere) is classified ARM, never probed, and appears in no list.

Per-region, per-family detail is in [`deny-matrix.csv`](deny-matrix.csv).

## How the list was derived

2,630 probes against AMD CCA on **2026-10-21** — one per region × Intel family, at 16 vCPU where offered. A family key is prefix + attributes + version (`Standard_D*s_v5`), deliberately excluding vCPU count: `standard_d2s_v5` through `standard_d64s_v5` all return the same AMD series, so size is not part of the decision.

Constrained-vCPU SKUs (`Standard_E8-4s_v5`) are a pricing variant of their parent family, not a separate family — a plain SKU is preferred as the probe, and the constrained variants still land in the expanded deny-list.

## How to apply it

### 1. Create the definition

At a management group (recommended — it's the only scope that covers multiple subscriptions):

```bash
az policy definition create \
  --name deny-intel-amd-available \
  --display-name "Deny Intel VM SKUs where an AMD equivalent exists" \
  --management-group <MG_ID> \
  --rules @policy-definition-deny-intel-amd-available.json \
  --mode Indexed
```

Or scoped to a single subscription with `--subscription <SUB_ID>` instead.

### 2. Assign it — audit first

```bash
az policy assignment create \
  --name enforce-amd-where-available \
  --policy deny-intel-amd-available \
  --scope /providers/Microsoft.Management/managementGroups/<MG_ID> \
  --params '{"effect":{"value":"Audit"}}' \
  --enforcement-mode DoNotEnforce
```

Three scope forms, all valid:

| Scope | `--scope` value |
|-------|-----------------|
| Management group | `/providers/Microsoft.Management/managementGroups/<MG_ID>` |
| Subscription | `/subscriptions/<SUB_ID>` |
| Resource group | `/subscriptions/<SUB_ID>/resourceGroups/<RG>` |

### 3. Read the compliance report, then enforce

```bash
az policy state summarize --policy-assignment enforce-amd-where-available
```

Non-compliant resources are the Intel VMs the policy would have blocked. Once that list matches what you expect, switch to enforcing:

```bash
az policy assignment update \
  --name enforce-amd-where-available \
  --params '{"effect":{"value":"Deny"}}' \
  --enforcement-mode Default
```

### Grandfathering existing VMs

**This matters more on Azure than anywhere else.** Azure Policy's `Deny` evaluates on **update**, not just create. An existing Intel VM that matches the policy can be blocked from routine operations — resize, disk attach, even some tag changes — because those are `PUT` calls against a non-compliant resource.

Three escape hatches, in order of preference:

**Exemption** — per-resource, with a deadline. This is the right tool for a VM you intend to migrate:

```bash
az policy exemption create \
  --name grandfather-legacy-vm \
  --policy-assignment <ASSIGNMENT_ID> \
  --exemption-category Waiver \
  --scope /subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Compute/virtualMachines/<VM> \
  --expires-on 2027-10-21
```

See [`exemption-grandfather-example.json`](exemption-grandfather-example.json). The expiry is the point — a waiver without one is just a hole.

**`notScopes`** — exclude a whole subscription or resource group from the assignment. Blunt, but right for a legacy estate you're not migrating yet. See [`policy-assignment-example.json`](policy-assignment-example.json).

**`enforcementMode: DoNotEnforce`** — the policy evaluates and reports but never blocks. Use this for the dry run, not as a permanent state.

## What it does *not* do

**It does not touch running VMs.** `Deny` blocks `PUT` requests. A VM that already exists keeps running, and deallocate/start cycles are not creates.

**It does not block ARM.** Cobalt and Ampere SKUs are unaffected by design.

**It can block updates to existing Intel VMs.** This is the one place a create-time guard leaks into day-2 operations, and it's why the grandfathering section above exists. Plan for it before switching `effect` to `Deny`.

**It does not cover every Azure compute surface.** The definition matches VMs and scale sets. AKS node pools created through `Microsoft.ContainerService` and Batch pools have their own resource types and are not evaluated here.

**It does not expire.** The SKU lists reflect AMD availability on 2026-10-21. Re-run `generate.py` from the repo root and update the definition to pick up new regions and new families.
