# GCP — manual setup (without the script)

Everything [`startup.sh`](startup.sh) does, done by hand: install the CLI, create a credential in the Console, and configure the CLI to use it.

Use this when you can't or don't want to run the script — a locked-down workstation, a different OS, or you just want to see what's actually happening.

**Jump to:** [Install](#1-install-the-cli) · [Pick a credential](#2-pick-a-credential) · [User login](#2a-user-login--preferred-on-a-laptop) · [Attached SA](#2b-attached-service-account--preferred-on-a-vm) · [SA key](#2c-service-account-key--last-resort) · [ADC](#3-application-default-credentials-the-one-that-confuses-everyone) · [Configure](#4-configure-the-cli) · [Verify](#5-verify) · [Permissions](#6-permissions-you-actually-need)

---

## 1. Install the CLI

### Ubuntu / Debian — package repo (recommended)

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates gnupg curl

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list

sudo apt-get update && sudo apt-get install -y google-cloud-cli
```

> Use `tee`, not `tee -a`, if you ever re-run this — otherwise you get duplicate repo entries and apt warns on every update.

### RHEL / CentOS Stream / AlmaLinux / Rocky / Fedora

```bash
sudo tee /etc/yum.repos.d/google-cloud-sdk.repo << 'EOF'
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

sudo dnf install -y google-cloud-cli
```

Swap `el9` for `el8`, and `x86_64` for `aarch64`, to match your host.

### Archive — any Linux, no root

```bash
curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xf google-cloud-cli-linux-x86_64.tar.gz
./google-cloud-sdk/install.sh
exec -l $SHELL
```

### macOS / Windows

macOS: `brew install --cask google-cloud-sdk`
Windows: download `GoogleCloudSDKInstaller.exe` from the Google Cloud docs.

### Verify

```bash
gcloud --version
```

### Package repo vs. archive — pick knowingly

| | Package repo | Archive |
|---|---|---|
| Upgrade | `apt upgrade` / `dnf update` | `gcloud components update` |
| Add components | `apt install google-cloud-cli-<name>` | `gcloud components install <name>` |
| `gcloud components install` | **Disabled** — warns and does nothing | Works |
| Needs root | Yes | No |

The base package gives you `gcloud`, `gcloud alpha`, `gcloud beta`, `gsutil`, and `bq`. **Not** `kubectl` and **not** the GKE auth plugin:

```bash
sudo apt-get install -y google-cloud-cli-gke-gcloud-auth-plugin   # repo install
gcloud components install gke-gcloud-auth-plugin                  # archive install
```

---

## 2. Pick a credential

In order of preference. Pick **one**.

| | Where | Expires | Secret on disk |
|---|---|---|---|
| [**User login**](#2a-user-login--preferred-on-a-laptop) | Laptop, SSH session | Hours | No |
| [**Attached service account**](#2b-attached-service-account--preferred-on-a-vm) | GCE, GKE | Minutes, auto-rotated | No |
| [**SA key file**](#2c-service-account-key--last-resort) | Last resort | Never | **Yes** |

---

## 2a. User login — preferred on a laptop

**Nothing to create in the Console.** Your Google account is the credential.

```bash
gcloud init
```

This walks you through login *and* picking a default project and region in one pass. To just log in:

```bash
gcloud auth login
```

A browser opens. On a **headless host or over SSH**:

```bash
gcloud auth login --no-browser
```

It prints a command to run on a machine that *does* have a browser; that produces a token you paste back. Works through a bastion where nothing can open a browser.

> This authenticates the **`gcloud` CLI only**. It does *not* authenticate Terraform or the client libraries — see [§3](#3-application-default-credentials-the-one-that-confuses-everyone).

---

## 2b. Attached service account — preferred on a VM

On GCE, **don't download a key file onto the box.** Attach a service account at the VM level and the metadata server hands out short-lived tokens automatically.

### Create the service account

1. Console → **IAM & Admin** → **Service Accounts** → **Create service account**
2. Name it, e.g. `benchmark-runner` → **Create and continue**
3. Grant the roles it needs ([§6](#6-permissions-you-actually-need)) → **Continue** → **Done**

**Do not** create a key for it. That's the whole point.

### Attach it to a VM

**New VM:** in the create form, *Identity and API access* → **Service account** → pick it. Set *Access scopes* to **Allow full access to all Cloud APIs** and control real access through IAM roles — scopes are a legacy second layer that mostly causes confusing denials.

**Existing VM:** it must be **stopped** first.
```bash
gcloud compute instances stop my-vm --zone us-central1-a
gcloud compute instances set-service-account my-vm \
  --zone us-central1-a \
  --service-account benchmark-runner@PROJECT_ID.iam.gserviceaccount.com \
  --scopes cloud-platform
gcloud compute instances start my-vm --zone us-central1-a
```

### Then on the VM

Nothing. No `gcloud auth login`:

```bash
gcloud auth list
```

You'll see the service account as `ACTIVE`. ADC works automatically too — the metadata server serves both.

---

## 2c. Service account key — last resort

A downloaded JSON key never expires and is a file someone can commit to a repo. Many organizations disable key creation by org policy, and that's a reasonable default.

> For **GitHub Actions**, use **Workload Identity Federation** instead — GCP trusts GitHub's OIDC token directly, no key file. For **other clouds' VMs**, the same federation approach works.

### Create the key

1. Console → **IAM & Admin** → **Service Accounts** → click the account
2. **Keys** tab → **Add key** → **Create new key** → **JSON** → **Create**
3. The file downloads **once**. Store it outside any git repo and `chmod 600` it.

Or:
```bash
gcloud iam service-accounts keys create ~/sa-key.json \
  --iam-account benchmark-runner@PROJECT_ID.iam.gserviceaccount.com
```

### Use it

```bash
gcloud auth activate-service-account --key-file ~/sa-key.json
```

For SDKs and Terraform, also:
```bash
export GOOGLE_APPLICATION_CREDENTIALS=~/sa-key.json
```

Delete keys you're done with — they stay valid forever otherwise:
```bash
gcloud iam service-accounts keys list --iam-account SA_EMAIL
gcloud iam service-accounts keys delete KEY_ID --iam-account SA_EMAIL
```

---

## 3. Application Default Credentials (the one that confuses everyone)

GCP has **two separate credentials** on your machine, and knowing this saves hours:

| | Used by | Set with |
|---|---|---|
| **CLI credential** | `gcloud` commands | `gcloud auth login` |
| **ADC** | Terraform, client libraries, anything using the SDKs | `gcloud auth application-default login` |

`gcloud auth login` does **not** write ADC. So `gcloud compute instances list` works perfectly while Terraform reports *"could not find default credentials"* — same machine, same user, same minute. They're different files.

To set both:

```bash
gcloud auth login
gcloud auth application-default login
```

ADC lands in `~/.config/gcloud/application_default_credentials.json`.

The resolution order anything using ADC follows:

1. `GOOGLE_APPLICATION_CREDENTIALS` env var, if set
2. `~/.config/gcloud/application_default_credentials.json`
3. The metadata server (on GCE/GKE — which is why a VM needs none of this)

> ADC from a user login carries a quota-project warning on some APIs. Fix with `gcloud auth application-default set-quota-project PROJECT_ID`.

---

## 4. Configure the CLI

### Project — required for almost everything

```bash
gcloud projects list
gcloud config set project my-project-id
```

Use the **project ID** (`amd-benchmarks-4a7f`), not the display name.

### Default region and zone

```bash
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a
```

Without these, every `gcloud compute` command needs `--zone`.

### Configurations — switching between projects

```bash
gcloud config configurations create amd-demo
gcloud config set project amd-demo-project
gcloud config configurations activate default
gcloud config configurations list
```

Each holds its own account, project, and region — cleaner than resetting values by hand.

### Check what's active

```bash
gcloud config list
```

---

## 5. Verify

```bash
gcloud auth list
gcloud config list
```

Then something real:

```bash
gcloud compute machine-types list \
  --filter="zone:us-central1-a AND name~'^c3d'" --limit 5
```

And if you'll use Terraform or the SDKs:

```bash
gcloud auth application-default print-access-token | head -c 20; echo
```

A token means ADC is set. An error means it isn't — see [§3](#3-application-default-credentials-the-one-that-confuses-everyone).

### When it doesn't work

| Message | Cause |
|---|---|
| `You do not currently have an active account selected` | Not logged in, or the wrong configuration is active. |
| `could not find default credentials` | ADC not set — [§3](#3-application-default-credentials-the-one-that-confuses-everyone). This is the big one. |
| `The project property must be set` | `gcloud config set project PROJECT_ID`. |
| `PERMISSION_DENIED` on an API call | Authenticated fine, but missing an IAM role — [§6](#6-permissions-you-actually-need). |
| `has not been used in project ... before or it is disabled` | The API itself is off. The error text contains the exact enable URL; or `gcloud services enable compute.googleapis.com`. |
| `gcloud: command not found` after an archive install | `PATH` was added to `~/.bashrc`; open a new shell or `exec -l $SHELL`. |
| `components update` warns and does nothing | Expected on a package install — use `apt`/`dnf` instead. |

**Corporate proxy:**
```bash
gcloud config set proxy/type http
gcloud config set proxy/address proxy.corp.example.com
gcloud config set proxy/port 3128
```
For TLS interception: `gcloud config set core/custom_ca_certs_file /path/to/ca-bundle.pem`

---

## 6. Permissions you actually need

GCP roles apply at organization, folder, or project scope. Grant at **project** scope unless you have a reason not to.

| What you're doing | Role |
|---|---|
| Read-only exploration | `roles/viewer` |
| Launch/stop VMs for benchmarks | `roles/compute.instanceAdmin.v1` |
| Also need to act as a service account | `roles/iam.serviceAccountUser` |
| [`cca-export/gcp/`](../../cca-export/gcp/) | `roles/bigquery.dataViewer` + `roles/bigquery.jobUser` |
| [`cloud-instance-manager`](#appendix-cloud-instance-manager) | See the appendix |

Grant one:
```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="user:you@example.com" \
  --role="roles/compute.instanceAdmin.v1"
```

`roles/iam.serviceAccountUser` catches people out: creating a VM that *has* a service account attached requires permission to **act as** that service account, separately from permission to create the VM. Without it, `instances create` fails even with full compute admin.

### Enable the APIs

A fresh project has most APIs off:

```bash
gcloud services enable compute.googleapis.com
gcloud services enable bigquery.googleapis.com      # for cca-export
```

---

## Appendix: cloud-instance-manager

The [`cloud-instance-manager`](https://github.com/nfairoza/cloud-samples) skill drives this CLI. Beyond the setup above it needs:

**ADC, not just a CLI login.** The skill's `doctor` explicitly checks for it and will tell you to run:

```bash
gcloud auth application-default login
```

**A project ID** in the skill's `config.yaml`:

```yaml
gcp:
  project: amd-benchmarks-4a7f
  default_region: us-central1
  default_zone: us-central1-a
  ssh_user: ""                              # blank = your gcloud login user
  ssh_private_key: ~/.ssh/google_compute_engine
```

**An SSH key.** `gcloud compute ssh` generates `~/.ssh/google_compute_engine` on first use and registers the public half as project metadata — simplest is to run it once by hand against any instance and let it do that.

**These permissions** — the operations the skill performs (`instances create/describe/start/stop/delete`, `machine-types list/describe`):

- `roles/compute.instanceAdmin.v1`
- `roles/iam.serviceAccountUser` — needed because created VMs get a service account attached

**The Compute Engine API enabled:**
```bash
gcloud services enable compute.googleapis.com
```

Note the skill applies tags as **GCP labels**, which lowercase and sanitize keys and values per GCP's label rules — `Customer: Acme` becomes `customer: acme` on the resource. The skill's inventory keeps the original casing.

Check it end to end with:

```bash
python scripts/manager.py doctor
```

---

## Related

- [`README.md`](README.md) — the scripted path
- [`../aws/manual-setup.md`](../aws/manual-setup.md) · [`../azure/manual-setup.md`](../azure/manual-setup.md) · [`../oci/manual-setup.md`](../oci/manual-setup.md)
