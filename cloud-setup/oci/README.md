# OCI CLI Setup

Installs and configures the **OCI CLI (`oci`)** on a Linux workstation or OCI compute instance.

The script uses **Oracle's `install.sh` wrapper**, which puts the CLI in its own virtualenv — and pulls a private Python if the system one is too old — rather than installing into system site-packages. On Oracle Linux you can use the distro package instead with `--dnf`.

## Quick start

On a workstation — install, generate an API signing key, and write the config:

```bash
chmod +x startup.sh
./startup.sh --setup
```

On an **OCI compute instance** — no keys at all:

```bash
./startup.sh --instance-principal
```

Install without configuring:

```bash
./startup.sh
```

## Usage

| Flag | Purpose |
|------|---------|
| `-u`, `--update` | Reinstall/upgrade an existing install |
| `--dnf` | Install from the Oracle Linux repo instead of the install script |
| `--install-dir DIR` | Install location (default `~/lib/oracle-cli`) |
| `--bin-dir DIR` | Where to place the `oci` executable (default `~/bin`) |
| `--setup` | Run `oci setup config` — generates an API key pair and writes `~/.oci/config` |
| `--instance-principal` | Configure instance principal auth on OCI compute |
| `-r`, `--region` | Default region, e.g. `us-ashburn-1` |
| `-t`, `--tenancy` | Tenancy OCID (printed during `--setup` so you can paste it) |
| `--profile NAME` | Profile name (default `DEFAULT`) |
| `-h`, `--help` | Display help and exit |

### Examples

Workstation, full setup:
```bash
./startup.sh --setup -r us-ashburn-1
```

OCI compute instance:
```bash
./startup.sh --instance-principal -r us-ashburn-1
```

System-wide install rather than under `$HOME`:
```bash
sudo ./startup.sh --install-dir /opt/oci-cli --bin-dir /usr/local/bin
```

Upgrade:
```bash
./startup.sh --update
```

## Choosing an authentication method

| Where you're running | Use this |
|----------------------|----------|
| **OCI compute instance** | **Instance principal** (`--instance-principal`). No key pair to generate, upload, or rotate. Requires a dynamic group containing the instance plus a policy granting it access. |
| **OKE pod** | Resource principal — same idea, pod-scoped. |
| **Laptop, interactive** | Token-based auth: `oci session authenticate`. Short-lived, browser login, refresh with `oci session refresh`. |
| **Workstation, scripted** | `--setup` (API signing key). The key is long-lived and lives in `~/.oci` — rotate it on a schedule. |

`--instance-principal` checks the instance metadata service at `169.254.169.254` before writing anything, and fails with a clear message if you're not actually on an OCI instance — so it can't leave a workstation in a half-configured state.

### What `--setup` does

`oci setup config` prompts for your user OCID, tenancy OCID, and region, then generates an RSA key pair and writes `~/.oci/config`. Afterwards the script:

1. Tightens permissions — `chmod 700 ~/.oci`, `chmod 600` on the config and keys. The CLI **refuses to run** if these are group- or world-readable, which is the single most common "it worked yesterday" failure.
2. Prints your public key so you can paste it straight into the Console.

Then do the one manual step:

> **Console → Profile → My Profile → Resources → API keys → Add API key → Paste a public key**

Paste the contents of `~/.oci/oci_api_key_public.pem`. The Console then shows a config preview — if you'd rather use that, save it as `~/.oci/config` and point `key_file` at your private key.

### The config file

```ini
[DEFAULT]
user=ocid1.user.oc1..<unique_ID>
fingerprint=<your_fingerprint>
key_file=~/.oci/oci_api_key.pem
tenancy=ocid1.tenancy.oc1..<unique_ID>
region=us-ashburn-1
```

Don't put inline comments on these lines — the parser doesn't accept them. Comments must be on their own line.

## Supported platforms

| Distribution | Prereqs installed |
|--------------|-------------------|
| Ubuntu, Debian, Mint, Pop!_OS | `apt-get` — `python3`, `python3-venv`, `python3-pip` |
| Oracle Linux, RHEL, CentOS Stream, AlmaLinux, Rocky, Fedora | `dnf`/`yum` — `python3`, `python3-pip` |
| SLES, openSUSE | `zypper` |
| Anything else | Prereqs skipped; Oracle's installer fetches what it needs, including a private Python |

`--dnf` is Oracle Linux only and the script rejects it elsewhere. Oracle Linux 8 and 9 default to older Python builds; Oracle recommends 3.9+ for performance, and the install script handles that for you by bringing its own.

> For Windows, use `install.ps1` from the Oracle docs — this script is Linux-only.

## Verifying it works

```bash
oci --version
oci iam region list --output table
oci iam compartment list --output table
```

On an instance principal setup, add `--auth instance_principal` (or rely on the `OCI_CLI_AUTH` env var the script exports) :

```bash
oci iam region list --auth instance_principal --output table
```

The script runs `oci iam region list` itself at the end, so a successful run already confirms auth.

If `oci: command not found` straight after install, run `exec -l $SHELL` or open a new shell — the installer appends to `~/.bashrc`, which your current shell has already read.

## A note on persistent edits

Two flags write to your `~/.bashrc`:

- the installer adds `~/bin` to `PATH` and enables tab completion
- `--instance-principal` adds `export OCI_CLI_AUTH=instance_principal`

Both are idempotent — re-running won't duplicate the lines — but they are persistent. Remove them by hand if you later move the install or switch auth methods.

## Related

- [`../aws/`](../aws/) · [`../azure/`](../azure/) · [`../gcp/`](../gcp/) — the same setup for the other clouds
- [`../../amd-iam-policies/oci/`](../../amd-iam-policies/oci/) — IAM allow-list and compartment quotas to steer new instances toward AMD EPYC shapes
