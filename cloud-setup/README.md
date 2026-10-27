# Cloud Setup

Install and configure the command-line tooling for **AWS, Azure, GCP, and OCI** on a Linux workstation or cloud instance — one script per cloud, same shape, same flags where the concepts line up.

This is the first thing to run before anything else in this repo. Most other folders here — [`cca-export/`](../cca-export/), [`proof-of-performance/`](../proof-of-performance/), [`ec2-cli-samples/`](../ec2-cli-samples/), [`amd-iam-policies/`](../amd-iam-policies/) — assume the relevant CLI is already installed and authenticated.

## Pick your cloud

| Cloud | Folder | CLI | Install source | Preferred auth on an instance |
|-------|--------|-----|----------------|-------------------------------|
| **AWS** | [`aws/`](aws/) | `aws` (v2) | Official zip installer, optional PGP verify | IAM role via IMDS |
| **Azure** | [`azure/`](azure/) | `az` | Microsoft package repo | Managed identity |
| **GCP** | [`gcp/`](gcp/) | `gcloud` | Google package repo | Attached service account via metadata |
| **OCI** | [`oci/`](oci/) | `oci` | Oracle `install.sh` (own virtualenv) | Instance principal |

> Each folder's README covers prerequisites, every flag, the authentication options ranked by preference, and how to verify the install.

## Same shape everywhere

```bash
cd <cloud>
chmod +x startup.sh
./startup.sh --help
```

Each script installs the CLI, optionally authenticates, optionally sets defaults, then **proves it worked** by making a real API call and printing the identity it authenticated as. A clean run means you're ready to go — there's no separate "now check it worked" step.

Flags that mean the same thing in every folder:

| Flag | Everywhere |
|------|------------|
| `-h`, `--help` | Full usage |
| `-u`, `--update` | Upgrade an existing install |
| `-r`, `--region` | Default region (`-l`/`--location` on Azure, matching `az`'s own vocabulary) |

The rest follow each cloud's own vocabulary rather than a forced common denominator — `--project` on GCP, `--subscription` on Azure, `--profile` on AWS, `--tenancy` on OCI. These aren't the same concept and pretending otherwise causes mistakes.

## Don't put a static key on an instance

Every cloud has a way to give a VM an identity without a credential on disk, and all four scripts default to using it:

| Cloud | Mechanism | How to enable |
|-------|-----------|---------------|
| AWS | IAM role via IMDS | Attach an instance profile — run `./startup.sh` with no credential flags |
| Azure | Managed identity | *Identity → System assigned → On*, then `./startup.sh --identity` |
| GCP | Attached service account | Set it at instance creation — nothing to run |
| OCI | Instance principal | Dynamic group + policy, then `./startup.sh --instance-principal` |

These rotate automatically, never touch disk, and can't leak through a shell history or a committed dotfile. A long-lived access key does all three. The scripts still support static credentials, because sometimes that's genuinely all you have — but every README ranks them last, and says why.

On a **laptop**, the equivalent is a short-lived browser login: `aws configure sso`, `az login`, `gcloud auth login`, `oci session authenticate`.

## Install source, and why not just `apt install`

| Cloud | What the script does | Why |
|-------|----------------------|-----|
| **AWS** | Official zip installer | Distro packages ship v1 or a stale v2; the zip is what AWS's own docs use. Adds optional signature verification. |
| **Azure** | Microsoft package repo | Upgrades come with `apt upgrade`/`dnf update`, and the packages bundle their own Python so the CLI never fights the system one. The `aka.ms` one-liner is still there behind `--script` for containers. |
| **GCP** | Google package repo | Same upgrade argument. `--archive` switches to the tarball when you need `gcloud components install`, which a package install disables. |
| **OCI** | Oracle `install.sh` | Installs into its own virtualenv and brings a private Python when the system one is too old — which it usually is on EL8. |

## Three things that bite people

Each is handled in the script, documented in the folder README, and worth knowing about anyway:

- **GCP: the CLI credential and ADC are different things.** `gcloud auth login` does not authenticate Terraform or the client libraries — those read Application Default Credentials. Pass `--adc` to write both.
- **OCI: file permissions are enforced.** The CLI refuses to use a `~/.oci/config` or key file that's group- or world-readable. The script chmods them for you.
- **AWS: `gpg` exits 0 on an expired signing key.** It reports `EXPKEYSIG` instead of `GOODSIG`, so checking `$?` alone silently accepts it. `--verify` parses the status output instead.

## Files

```
cloud-setup/
  aws/    startup.sh - AWS CLI v2, zip installer, optional PGP verify, profiles
  azure/  startup.sh - az from the Microsoft repo, device-code / managed identity / SP
  gcp/    startup.sh - gcloud from the Google repo, user / SA / ADC login
  oci/    startup.sh - oci via Oracle's installer, API key setup or instance principal
```

Every folder has its own README with the full flag reference and examples.
