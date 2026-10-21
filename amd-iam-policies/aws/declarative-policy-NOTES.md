# Declarative Policy - read before applying

This file exists to close one specific gap: **Auto Scaling launches through
the service-linked role are not evaluated against SCPs.** A Declarative Policy
is evaluated, so it covers ASG where the SCP cannot.

It is an allow-list, and that costs two things the SCP does not cost you.
Neither is a bug in the generator - they are limits of the mechanism.

## 1. It is region-blind

Declarative Policies have no region condition key. A family denied in even one
region therefore has to be omitted from the allow-list entirely, which enforces
that deny in **every** region - including the ones where CCA found no AMD
equivalent. The following families are allowed by the SCP in at least one region
but are omitted here, so applying this file is stricter than the stated policy:

```
c4     still allowed by the SCP in: ap-northeast-2, ap-northeast-3, ap-southeast-2, ca-central-1, sa-east-1
c5     still allowed by the SCP in: af-south-1, ap-northeast-2, ap-northeast-3, ap-southeast-3, ap-southeast-4, ca-west-1, eu-central-2, eu-south-1, eu-west-3, il-central-1, me-central-1
c6i    still allowed by the SCP in: af-south-1, ap-east-2, ap-northeast-2, ap-northeast-3, ap-southeast-5, ap-southeast-6, ap-southeast-7, ca-west-1, eu-south-1, eu-west-3, il-central-1, mx-central-1
c7i    still allowed by the SCP in: af-south-1, ap-east-1, ap-east-2, ap-northeast-2, ap-northeast-3, ap-south-1, ap-south-2, ap-southeast-2, ap-southeast-3, ap-southeast-4, ap-southeast-5, ap-southeast-6, ap-southeast-7, ca-central-1, ca-west-1, eu-central-2, eu-south-1, eu-west-3, il-central-1, me-central-1, mx-central-1, sa-east-1
c8i    still allowed by the SCP in: af-south-1, ap-northeast-2, ap-south-1, ap-south-2, ap-southeast-2, ap-southeast-5, ap-southeast-6, ca-central-1, eu-west-3, sa-east-1
m4     still allowed by the SCP in: ap-northeast-2, ap-northeast-3
m5     still allowed by the SCP in: af-south-1, ap-east-1, ap-northeast-2, ap-northeast-3, ap-southeast-3, ap-southeast-4, ca-west-1, eu-central-2, il-central-1, me-central-1
m6i    still allowed by the SCP in: af-south-1, ap-east-1, ap-east-2, ap-northeast-2, ap-northeast-3, ap-southeast-3, ap-southeast-5, ap-southeast-6, ap-southeast-7, ca-west-1, eu-central-2, il-central-1, me-central-1, mx-central-1
m7i    still allowed by the SCP in: af-south-1, ap-east-1, ap-east-2, ap-northeast-2, ap-northeast-3, ap-southeast-1, ap-southeast-3, ap-southeast-4, ap-southeast-5, ap-southeast-6, ap-southeast-7, ca-central-1, eu-central-2, eu-south-1, eu-west-3, il-central-1, me-central-1, mx-central-1, sa-east-1, us-west-1
m8i    still allowed by the SCP in: af-south-1, ap-northeast-2, ap-southeast-1, ap-southeast-5, ap-southeast-6, ca-central-1, ca-west-1, eu-west-3, sa-east-1, us-west-1
r3     still allowed by the SCP in: ap-northeast-2, sa-east-1
r4     still allowed by the SCP in: ap-northeast-2, ap-northeast-3, eu-west-3, sa-east-1
r5     still allowed by the SCP in: af-south-1, ap-east-1, ap-northeast-2, ap-northeast-3, ap-southeast-3, ap-southeast-4, ca-west-1, eu-central-2, eu-south-1, eu-west-3, il-central-1, me-central-1, sa-east-1
r6i    still allowed by the SCP in: af-south-1, ap-east-1, ap-northeast-2, ap-northeast-3, ap-southeast-5, ap-southeast-6, ap-southeast-7, ca-west-1, eu-central-2, eu-south-1, eu-west-3, il-central-1, me-central-1, mx-central-1, sa-east-1
r7i    still allowed by the SCP in: ap-northeast-2, ap-northeast-3, ap-south-1, ap-southeast-1, ap-southeast-2, ap-southeast-3, ap-southeast-4, ap-southeast-5, ap-southeast-6, ap-southeast-7, eu-south-1, eu-west-2, eu-west-3, mx-central-1, sa-east-1, us-west-1
r8i    still allowed by the SCP in: af-south-1, ap-northeast-2, ap-south-1, ap-southeast-1, ap-southeast-2, ap-southeast-5, ap-southeast-6, ca-west-1, eu-central-2, eu-south-1, eu-west-2, eu-west-3, il-central-1, me-central-1, sa-east-1, us-west-1
t2     still allowed by the SCP in: ap-northeast-3
t3     still allowed by the SCP in: af-south-1, ap-east-1, ap-east-2, ap-northeast-3, ap-south-2, ap-southeast-3, ap-southeast-4, ap-southeast-5, ap-southeast-6, ap-southeast-7, ca-west-1, eu-central-2, eu-north-1, eu-south-2, mx-central-1
```

## 2. It only knows the families CCA prices

CCA's catalog covers 48 families - general purpose, compute
optimized and memory optimized. Storage, GPU, HPC and accelerated families
(`i3`, `i4i`, `m5d`, `r5d`, `d3`, `g4dn`, `g5`, `p5`, `inf2`, `trn1`, `x2idn`,
`z1d`, `u-*`, `hpc6a`, ...) are **not in the catalog**, were never probed, and
so cannot appear in the list above. Apply this file as-is and those launches
will be blocked.

The SCP does not have this problem - it names families to deny, so anything
CCA does not price is untouched by it.

**Before applying, append every accelerated/storage family you actually run**
to `allowed_instance_types`, for example:

```json
"@@assign": ["c8a.*", "m8a.*", "...", "i4i.*", "g5.*", "p5.*", "trn1.*"]
```

If that is not acceptable, use the SCP alone and accept the ASG gap, or restrict
which instance types your launch templates may reference instead.
