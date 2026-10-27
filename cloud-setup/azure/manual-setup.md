# Azure — manual setup (without the script)

Everything [`startup.sh`](startup.sh) does, done by hand: install the CLI, create a credential in the Portal, and configure the CLI to use it.

Use this when you can't or don't want to run the script — a locked-down workstation, a different OS, or you just want to see what's actually happening.

**Jump to:** [Install](#1-install-the-cli) · [Pick a credential](#2-pick-a-credential) · [Interactive login](#2a-interactive-login--preferred-on-a-laptop) · [Managed identity](#2b-managed-identity--preferred-on-a-vm) · [Service principal](#2c-service-principal--automation) · [Configure](#3-configure-the-cli) · [Verify](#4-verify) · [Permissions](#5-permissions-you-actually-need)

---

## 1. Install the CLI

### Ubuntu / Debian — package repo (recommended)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg

sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
sudo chmod go+r /etc/apt/keyrings/microsoft.gpg

AZ_DIST=$(lsb_release -cs)
sudo tee /etc/apt/sources.list.d/azure-cli.sources > /dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF

sudo apt-get update
sudo apt-get install -y azure-cli
```

> **If `apt-get update` 404s on the azure-cli repo**, `lsb_release -cs` returned a codename Microsoft doesn't publish — common on Mint, Pop!_OS, and brand-new Ubuntu releases. Set `AZ_DIST=jammy` (or `bookworm` on Debian) manually and redo the last three commands. This is Microsoft's own documented workaround, and it's what the script automates.

### RHEL / CentOS Stream / AlmaLinux / Rocky / Fedora

```bash
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm
sudo dnf install -y azure-cli
```

Use `/rhel/8/` for EL8. CentOS 7 and RHEL 7 are end of life — 2.38.2 was the last supported version there and it gets no fixes.

### One-liner (containers, CI)

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

Fine for an ephemeral image. On a machine you'll patch, prefer the repo — upgrades then come with `apt upgrade`.

### macOS

```bash
brew update && brew install azure-cli
```

### Windows

```powershell
winget install -e --id Microsoft.AzureCLI
```

Or download the MSI from the Microsoft docs. Open a **new** terminal afterwards.

### Verify

```bash
az version
```

> **Don't use `pip install azure-cli`.** The repo packages bundle their own Python runtime; the pip install fights your system Python and breaks on upgrades.

---

## 2. Pick a credential

In order of preference. Pick **one**.

| | Where | Expires | Secret on disk |
|---|---|---|---|
| [**Interactive login**](#2a-interactive-login--preferred-on-a-laptop) | Laptop, SSH session | Hours | No |
| [**Managed identity**](#2b-managed-identity--preferred-on-a-vm) | Azure VM, AKS | Minutes, auto-rotated | No |
| [**Service principal**](#2c-service-principal--automation) | CI, headless | Months (you set it) | **Yes** |

---

## 2a. Interactive login — preferred on a laptop

**Nothing to create in the Portal.** Your existing work account is the credential.

```bash
az login
```

A browser opens. On a **headless host or over SSH**, where no browser can open:

```bash
az login --use-device-code
```

You get a code to enter at `https://microsoft.com/devicelogin` from any machine — phone, laptop, whatever. This is the one to reach for on a remote box.

With more than one tenant:

```bash
az login --tenant 00000000-1111-2222-3333-444444444444
```

After login, `az` prints every subscription you can see. Pick a default:

```bash
az account list --output table
az account set --subscription "AMD Cloud Engineering"
```

---

## 2b. Managed identity — preferred on a VM

On an Azure VM, **don't create a service principal and paste its secret onto the box.** Turn on managed identity instead — Azure injects tokens through the instance metadata endpoint and rotates them for you.

### Enable it

**Portal:** VM → **Security** → **Identity** → **System assigned** → **Status: On** → **Save**

**CLI** (from a machine that's already logged in):
```bash
az vm identity assign --name my-vm --resource-group my-rg
```

### Grant it access

An identity with no role assignment can authenticate but do nothing. Give it a role:

1. Portal → the **resource group** (or subscription) it should manage
2. **Access control (IAM)** → **Add** → **Add role assignment**
3. **Role:** pick the least-privilege one ([§5](#5-permissions-you-actually-need))
4. **Members:** *Managed identity* → *Virtual machine* → your VM
5. **Review + assign**

Or:
```bash
az role assignment create \
  --assignee-object-id $(az vm identity show --name my-vm --resource-group my-rg --query principalId -o tsv) \
  --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" \
  --scope /subscriptions/<SUB_ID>/resourceGroups/my-rg
```

### Then on the VM

```bash
az login --identity
```

For a **user-assigned** identity, name which one:

```bash
az login --identity --client-id <CLIENT_ID_OF_THE_IDENTITY>
```

> Role assignments can take a minute or two to propagate. If `az login --identity` works but commands return `AuthorizationFailed`, wait and retry before changing anything.

---

## 2c. Service principal — automation

For CI and headless jobs. A service principal is an identity for an application rather than a person.

> If you're wiring up **GitHub Actions**, use **workload identity federation** instead — the `azure/login` action can authenticate with an OIDC token and no stored secret at all. Only fall back to a secret if federation isn't an option.

### Create it (Portal)

1. Portal → **Microsoft Entra ID** → **App registrations** → **New registration**
2. Name it, e.g. `cli-benchmark-sp`; leave redirect URI blank → **Register**
3. From the overview, copy:
   - **Application (client) ID** → this is `--username` / `-u`
   - **Directory (tenant) ID** → this is `--tenant`
4. **Certificates & secrets** → **New client secret** → set an expiry → **Add**
5. **Copy the secret Value now.** It's shown once. (Copy *Value*, not *Secret ID* — a very common mix-up.)
6. Assign it a role: go to the subscription or resource group → **Access control (IAM)** → **Add role assignment** → pick the role → **Members:** *User, group, or service principal* → search your app name

### Create it (one command)

If you're already logged in, this creates the app, the secret, and the role assignment together:

```bash
az ad sp create-for-rbac \
  --name cli-benchmark-sp \
  --role Contributor \
  --scopes /subscriptions/<SUB_ID>/resourceGroups/my-rg
```

Output — **the only time `password` is shown**:

```json
{
  "appId": "00000000-1111-2222-3333-444444444444",
  "displayName": "cli-benchmark-sp",
  "password": "abc~123...",
  "tenant": "99999999-8888-7777-6666-555555555555"
}
```

### Log in with it

```bash
az login --service-principal \
  -u "$APP_ID" \
  -p "$CLIENT_SECRET" \
  --tenant "$TENANT_ID"
```

Prefer a **certificate** over a secret where you can:

```bash
az login --service-principal -u "$APP_ID" --certificate ~/sp-cert.pem --tenant "$TENANT_ID"
```

Read the secret from an environment variable rather than typing it — a literal `-p` value lands in your shell history and is visible in `ps` while the command runs.

---

## 3. Configure the CLI

### Default subscription

```bash
az account list --output table
az account set --subscription "AMD Cloud Engineering"
```

### Defaults that save typing

```bash
az configure --defaults group=amd-benchmarks location=eastus
```

Now `az vm list` doesn't need `--resource-group`, and `az vm create` doesn't need `--location`. Clear one with `az configure --defaults group=`.

### Output format

```bash
az config set core.output=table
```

`table` is far more readable interactively; `json` and `tsv` are better for scripting.

### Where it's stored

`~/.azure/` (Windows: `%USERPROFILE%\.azure\`) holds `config`, the token cache, and `azureProfile.json`. To start clean: `az logout` then delete the folder.

---

## 4. Verify

```bash
az account show --output table
```

```
Name                     CloudName    SubscriptionId                        State    IsDefault
-----------------------  -----------  ------------------------------------  -------  ---------
AMD Cloud Engineering    AzureCloud   00000000-1111-2222-3333-444444444444  Enabled  True
```

Then something real:

```bash
az vm list-sizes --location eastus --output table | head
```

### When it doesn't work

| Message | Cause |
|---|---|
| `Please run 'az login' to setup account` | Not logged in, or the token cache was cleared. |
| `AADSTS50076` / MFA required | Needs interactive login — `az login --use-device-code`. |
| `The subscription ... could not be found` | Wrong tenant, or you lack access. `az account list --all`. |
| `AuthorizationFailed` | Authenticated fine, but no role assignment covers that action/scope. See [§5](#5-permissions-you-actually-need). |
| `ManagedIdentityCredential authentication unavailable` | `--identity` off an Azure VM, or identity not enabled on it. |
| `AADSTS7000215: Invalid client secret` | Wrong secret, or expired. Check you copied *Value*, not *Secret ID*. |
| `SSLError` / certificate failure | Trust-store problem — see below. |

**Corporate proxy and TLS.** `az` reads `HTTP_PROXY` / `HTTPS_PROXY` from the environment. For certificate failures, `az` is Python/requests-based, so it reads `REQUESTS_CA_BUNDLE`:

```bash
export REQUESTS_CA_BUNDLE="$HOME/ca-certs/combined-ca-bundle.pem"
```

That file needs the public roots **and** your corporate CA. Pointing it at an exported site chain replaces the public roots and breaks every Azure endpoint at once — [`../corporate-tls.md`](../corporate-tls.md) explains how to tell the two cases apart, and [`../make-ca-bundle.sh`](../make-ca-bundle.sh) builds a bundle that covers both.

If your `sudo` doesn't preserve the environment, install with `sudo -E`.

---

## 5. Permissions you actually need

Azure is role-based and scoped (management group → subscription → resource group → resource). Assign the **narrowest role at the narrowest scope** that works.

| What you're doing | Role | Scope |
|---|---|---|
| Read-only exploration | `Reader` | Subscription |
| Launch/stop VMs for benchmarks | `Virtual Machine Contributor` | One resource group |
| Create resource groups too | `Contributor` | Subscription |
| [`cca-export/azure/`](../../cca-export/azure/) | `Cost Management Reader` + `Reader` | Subscription |
| [`cloud-instance-manager`](#appendix-cloud-instance-manager) | See the appendix | One resource group |

`Owner` differs from `Contributor` in one way that matters: it can also grant roles to others. Automation almost never needs that.

---

## Appendix: cloud-instance-manager

The [`cloud-instance-manager`](https://github.com/nfairoza/cloud-samples) skill drives this CLI. Beyond the setup above it needs:

**A subscription ID** in the skill's `config.yaml`:

```yaml
azure:
  subscription: 00000000-1111-2222-3333-444444444444
  resource_group: cloud-instance-manager-rg
  ssh_user: azureuser
  ssh_private_key: ~/.ssh/id_rsa
```

Get it with `az account show --query id -o tsv`.

**An SSH key pair.** The skill passes your public key to `az vm create`:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/azure-poc
```

Point `ssh_private_key` at `~/.ssh/azure-poc`.

**A role that permits the operations it performs** — `vm create`, `vm start`, `vm deallocate`, `vm delete`, `vm list-sizes`, `vm get-instance-view`, `vm list-ip-addresses`, plus `group create`/`group show` (it creates the resource group if missing).

`Contributor` on the subscription covers all of it. To tighten: `Virtual Machine Contributor` on the resource group, plus the ability to create that group — note that **creating a resource group is a subscription-scope action**, so pre-create it yourself and then grant only resource-group scope:

```bash
az group create --name cloud-instance-manager-rg --location eastus
az role assignment create \
  --assignee <SP_OR_USER> \
  --role "Virtual Machine Contributor" \
  --scope /subscriptions/<SUB_ID>/resourceGroups/cloud-instance-manager-rg
```

Networking also matters: `az vm create` builds a VNet, NIC, public IP, and NSG on first use, which needs `Network Contributor` on the same scope.

Check it end to end with:

```bash
python scripts/manager.py doctor
```

---

## Related

- [`README.md`](README.md) — the scripted path
- [`../aws/manual-setup.md`](../aws/manual-setup.md) · [`../gcp/manual-setup.md`](../gcp/manual-setup.md) · [`../oci/manual-setup.md`](../oci/manual-setup.md)
