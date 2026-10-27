# AWS CLI Setup

Installs and configures the **AWS CLI v2** on a Linux workstation or EC2 instance.

The script installs from the official AWS zip installer rather than a distro package — `apt`/`yum` ship v1 or a stale v2, and the AWS docs' own instructions use the zip. It can optionally verify the installer's PGP signature and write a named profile.

> **Don't want to run a script?** [**manual-setup.md**](manual-setup.md) walks through the same thing by hand — install the CLI, create an IAM user or role in the Console, upload/copy the credential, configure the CLI, and verify. Use it on a locked-down machine, on Windows/macOS, or when you'd rather see exactly what's happening.

## Quick start

```bash
chmod +x startup.sh
./startup.sh
```

That installs the CLI and stops. Authentication is a separate step — see below.

## Usage

| Flag | Purpose |
|------|---------|
| `-u`, `--update` | Update an existing AWS CLI v2 install in place |
| `--verify` | Verify the installer PGP signature before installing |
| `--version VER` | Install a specific version (e.g. `2.31.0`) instead of latest |
| `-k`, `--key` | AWS Access Key ID (must be paired with `-sk`) |
| `-sk`, `--secret-key` | AWS Secret Access Key (must be paired with `-k`) |
| `-r`, `--region` | Default region, e.g. `us-east-1` |
| `-p`, `--profile` | Write settings to a named profile instead of the default |
| `-o`, `--output` | Output format: `json` (default), `yaml`, `text`, `table` |
| `-h`, `--help` | Display help and exit |

### Examples

Install only:
```bash
./startup.sh
```

Install and set a default region:
```bash
./startup.sh -r us-east-1
```

Install with a static key pair (see the warning below):
```bash
./startup.sh -k YOUR_ACCESS_KEY -sk YOUR_SECRET_KEY -r us-east-1
```

Keep accounts separate with a named profile:
```bash
./startup.sh -k YOUR_ACCESS_KEY -sk YOUR_SECRET_KEY -p amd-demo
```
Then run commands against it with `aws ec2 describe-instances --profile amd-demo`, or export `AWS_PROFILE=amd-demo`.

Upgrade an existing install:
```bash
./startup.sh --update
```

Pin a version — useful when reproducing a benchmark run:
```bash
./startup.sh --version 2.31.0
```

## Choosing an authentication method

Static access keys are the *least* preferred option. They don't expire, they sit on disk in `~/.aws/credentials`, and a leaked pair stays valid until someone notices. Use them only when nothing else is available.

| Where you're running | Use this |
|----------------------|----------|
| **EC2 instance / EKS node** | **Attach an IAM role.** Credentials arrive through IMDS, rotate automatically, and never touch disk. Run `./startup.sh` with no credential flags. |
| **Laptop with AWS SSO / Identity Center** | `aws configure sso` — short-lived credentials, refreshed by `aws sso login`. |
| **Cross-account access** | A profile with `role_arn` + `source_profile` in `~/.aws/config`; the CLI assumes the role and rotates the session for you. |
| **CI / GitHub Actions** | OIDC federation (`AssumeRoleWithWebIdentity`) — no stored secret at all. |
| **Last resort** | Static key pair via `-k` / `-sk`. Scope the IAM user tightly and rotate on a schedule. |

If you do use static keys, pass them from the environment so they don't land in your shell history:

```bash
./startup.sh -k "$MY_KEY" -sk "$MY_SECRET" -r us-east-1
```

## Verifying the installer

`--verify` checks the installer's detached PGP signature before running it. Worth doing on anything long-lived or internet-exposed.

It needs AWS's public key, which AWS publishes **only inside a documentation page** — there is no stable raw URL to fetch, so the script will not download a key from anywhere. One-time setup:

1. Open the [AWS CLI install page](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
2. Copy the whole block from `-----BEGIN PGP PUBLIC KEY BLOCK-----` to `-----END PGP PUBLIC KEY BLOCK-----`.
3. Save it as `aws-cli-public-key.asc` next to `startup.sh`.

```bash
./startup.sh --verify
```

The script imports the key into a throwaway keyring (your own GPG keyring is untouched), confirms the fingerprint is:

```
FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C
```

…and then requires `GOODSIG` in the GPG status output. That last part matters: **`gpg` exits 0 for a signature made by an expired key**, reporting `EXPKEYSIG` instead. Checking `$?` alone would accept it. The copy of this key on `keyserver.ubuntu.com` is itself expired while the one in AWS's docs is not — the other reason the script won't pull from a keyserver.

## Supported platforms

| Distribution | Prereq install |
|--------------|----------------|
| Ubuntu, Debian | `apt-get` |
| RHEL, CentOS Stream, AlmaLinux, Rocky, Fedora, Amazon Linux | `dnf`, falling back to `yum` |
| SLES, openSUSE | `zypper` |

Architectures: `x86_64` and `aarch64`.

> For a Windows or macOS workstation, use the MSI / `.pkg` installer from the AWS docs — this script is Linux-only.

## Verifying it works

```bash
aws --version
aws sts get-caller-identity
aws ec2 describe-regions --output table
```

The script runs `get-caller-identity` itself at the end and prints the resulting ARN, so a successful run already tells you auth is working.

## Related

- [`../azure/`](../azure/) · [`../gcp/`](../gcp/) · [`../oci/`](../oci/) — the same setup for the other clouds
- [`../../ec2-cli-samples/`](../../ec2-cli-samples/) — EC2 commands to run once the CLI is up
- [`../../cca-export/aws/`](../../cca-export/aws/) — pull your AWS compute inventory for a Cloud Cost Assessment
