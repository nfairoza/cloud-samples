# Azure CLI Setup

Installs and configures the **Azure CLI (`az`)** on a Linux workstation or Azure VM.

The script installs from **Microsoft's package repository**, not the `aka.ms/InstallAzureCLIDeb` one-liner. The repo path means upgrades arrive with your normal `apt upgrade` / `dnf update`, and the packages bundle their own Python runtime so the CLI never fights the system Python. The one-liner is still available with `--script` for throwaway containers and CI images.

> **Don't want to run a script?** [**manual-setup.md**](manual-setup.md) walks through the same thing by hand — install the CLI, enable a managed identity or register a service principal in the Portal, assign a role, configure the CLI, and verify. Use it on a locked-down machine, on Windows/macOS, or when you'd rather see exactly what's happening.

## Quick start

```bash
chmod +x startup.sh
./startup.sh --login
```

That installs the CLI and starts a device-code login, which works over SSH where a browser pop-up can't.

Install without logging in:

```bash
./startup.sh
```

## Usage

| Flag | Purpose |
|------|---------|
| `-u`, `--update` | Upgrade an existing install (`az upgrade`, falling back to the package manager) |
| `--script` | Install via Microsoft's one-liner script instead of the package repo |
| `--login` | Interactive device-code login |
| `--identity` | Log in with the VM's managed identity |
| `--identity-client-id ID` | Use a specific user-assigned managed identity |
| `--service-principal APP_ID` | Log in as a service principal (needs `--tenant` + `--sp-secret` or `--sp-cert`) |
| `--sp-secret SECRET` | Service principal client secret |
| `--sp-cert PATH` | Service principal certificate (`.pem`) |
| `-s`, `--subscription` | Subscription ID or name to set as default |
| `-t`, `--tenant` | Tenant ID to authenticate against |
| `-g`, `--resource-group` | Default resource group |
| `-l`, `--location` | Default location, e.g. `eastus` |
| `-o`, `--output` | Output format: `json` (default), `jsonc`, `table`, `tsv`, `yaml` |
| `-h`, `--help` | Display help and exit |

### Examples

Install, log in, and set defaults so you can stop typing `-g` and `-l`:
```bash
./startup.sh --login -g amd-benchmarks -l eastus -o table
```

On an Azure VM with a system-assigned managed identity:
```bash
./startup.sh --identity
```

With a user-assigned identity:
```bash
./startup.sh --identity-client-id 00000000-1111-2222-3333-444444444444
```

Service principal, for CI or a headless runner:
```bash
./startup.sh --service-principal "$APP_ID" --tenant "$TENANT_ID" --sp-secret "$CLIENT_SECRET"
```

Pick a subscription when your account has several:
```bash
./startup.sh --login -s "AMD Cloud Engineering"
```

Upgrade:
```bash
./startup.sh --update
```

## Choosing an authentication method

| Where you're running | Use this |
|----------------------|----------|
| **Azure VM / AKS node** | **Managed identity** (`--identity`). No secret on disk, token rotates automatically. Enable it on the VM first: *Identity → System assigned → On*. |
| **Laptop or SSH session** | `--login` (device code). You get a code to paste at `microsoft.com/devicelogin`; no browser needed on the remote host. |
| **CI / GitHub Actions** | OIDC federated credentials (`azure/login` action) — no stored secret. Falls back to a service principal if federation isn't set up. |
| **Headless automation** | `--service-principal` with a **certificate** (`--sp-cert`) in preference to a secret. |
| **Last resort** | Service principal with a client secret. Set an expiry and rotate it. |

Passing `--sp-secret` on the command line puts the secret in your shell history and in `ps` output while the script runs. Read it from the environment instead:

```bash
./startup.sh --service-principal "$APP_ID" --tenant "$TENANT_ID" --sp-secret "$CLIENT_SECRET"
```

## Supported platforms

| Distribution | Method |
|--------------|--------|
| Ubuntu, Debian, Mint, Pop!_OS | `apt` repo, deb822 `.sources` format, key in `/etc/apt/keyrings` |
| RHEL, CentOS Stream, AlmaLinux, Rocky, Fedora, Azure Linux | `dnf`/`yum` repo via `packages-microsoft-prod.rpm` |
| SLES, openSUSE | `zypper` repo |
| Anything else | `--script` |

Two distro quirks the script handles for you:

- **Unpublished codenames.** Microsoft doesn't publish a repo for every Ubuntu/Debian codename — Mint's codenames and brand-new Ubuntu releases return something `packages.microsoft.com` has never heard of. The script detects that and falls back to `jammy` (or `bookworm` on Debian), which is what Microsoft's own docs tell you to do by hand.
- **RHEL major version.** It maps `VERSION_ID` to the matching RHEL repo (8/9/10), defaulting to 9 for derivatives that report something unexpected.

> **CentOS 7 / RHEL 7 are end of life.** Azure CLI 2.38.2 was the last version supported there and gets no fixes. The script will try the RHEL 9 repo, which generally won't work on 7 — move to RHEL 9+ or CentOS Stream 9+.

> For a Windows or macOS workstation, use the MSI / Homebrew install from the Microsoft docs — this script is Linux-only.

## Verifying it works

```bash
az version
az account show -o table
az vm list-sizes --location eastus -o table | head
```

The script runs `az account show` itself at the end and prints the active subscription, so a successful run already confirms auth.

## Behind a proxy

The install reads `HTTP_PROXY` / `HTTPS_PROXY` from the environment — export them before running, including under `sudo` if your `sudo` doesn't preserve them (`sudo -E`).

## Related

- [`../aws/`](../aws/) · [`../gcp/`](../gcp/) · [`../oci/`](../oci/) — the same setup for the other clouds
- [`../../cca-export/azure/`](../../cca-export/azure/) — pull your Azure compute inventory for a Cloud Cost Assessment
- [`../../amd-iam-policies/azure/`](../../amd-iam-policies/azure/) — Azure Policy to steer new VMs toward AMD EPYC
