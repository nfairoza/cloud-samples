# Cloud Setup

Install and configure the command-line tooling for **AWS, Azure, GCP, and OCI** on a Linux workstation or cloud instance — one script per cloud, same shape, same flags where the concepts line up.

This is the first thing to run before anything else in this repo. Most other folders here — [`cca-export/`](../cca-export/), [`proof-of-performance/`](../proof-of-performance/), [`ec2-cli-samples/`](../ec2-cli-samples/), [`amd-iam-policies/`](../amd-iam-policies/) — assume the relevant CLI is already installed and authenticated.

## Pick your cloud

| Cloud | Folder | CLI | Scripted | By hand | Preferred auth on an instance |
|-------|--------|-----|----------|---------|-------------------------------|
| **AWS** | [`aws/`](aws/) | `aws` (v2) | [`startup.sh`](aws/startup.sh) | [manual-setup](aws/manual-setup.md) | IAM role via IMDS |
| **Azure** | [`azure/`](azure/) | `az` | [`startup.sh`](azure/startup.sh) | [manual-setup](azure/manual-setup.md) | Managed identity |
| **GCP** | [`gcp/`](gcp/) | `gcloud` | [`startup.sh`](gcp/startup.sh) | [manual-setup](gcp/manual-setup.md) | Attached service account |
| **OCI** | [`oci/`](oci/) | `oci` | [`startup.sh`](oci/startup.sh) | [manual-setup](oci/manual-setup.md) | Instance principal |

> Each folder's README covers prerequisites, every flag, the authentication options ranked by preference, and how to verify the install.

## Two ways to do this

**Run the script** — one command, installs and authenticates, verifies itself. Start here if you can.

**Do it by hand** — every folder has a `manual-setup.md` covering the same ground step by step: install the CLI on Linux/macOS/Windows, create the credential **in the cloud's web console** (IAM user, service principal, service account, API key — with the exact click path), configure the CLI, verify, and fix the common errors. Use it when you're on a locked-down machine, not on Linux, need to hand the Console steps to someone else, or just want to see what the script is doing before you trust it.

Both end in the same place. The manual guides also cover the Console-side work the scripts *can't* do for you — creating an IAM role, enabling a managed identity, uploading an OCI public key, granting roles.

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

## Using this with cloud-instance-manager

The `cloud-instance-manager` skill drives these CLIs to launch, tag, inventory, and sweep instances. It supports **AWS, GCP, and Azure** (not OCI).

Set the CLI up first — scripted or by hand — then:

```bash
cd ~/.claude/skills/cloud-instance-manager
cp config.example.yaml config.yaml     # set owner, project/subscription, SSH key
python scripts/manager.py doctor
```

`doctor` checks each enabled cloud's CLI and credentials and tells you exactly what's missing. Each `manual-setup.md` ends with an appendix listing what that skill needs beyond a basic login — the SSH key pair, the specific IAM actions, and the APIs to enable.

## Files

```
cloud-setup/
  aws/    startup.sh + manual-setup.md - AWS CLI v2, zip installer, optional PGP verify
  azure/  startup.sh + manual-setup.md - az from the Microsoft repo, device code / MI / SP
  gcp/    startup.sh + manual-setup.md - gcloud from the Google repo, user / SA / ADC
  oci/    startup.sh + manual-setup.md - oci via Oracle's installer, API key or instance principal
```

Every folder has its own README with the full flag reference and examples.
