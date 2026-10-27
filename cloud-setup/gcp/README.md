# Google Cloud CLI Setup

Installs and configures the **Google Cloud CLI (`gcloud`)** on a Linux workstation or GCE instance.

The script installs from **Google's package repository** by default, so upgrades arrive with your normal `apt upgrade` / `dnf update`. If you need `gcloud components install`, use `--archive` instead — see the note below.

## Quick start

```bash
chmod +x startup.sh
./startup.sh --login -p my-project -z us-central1-a
```

Install without logging in:

```bash
./startup.sh
```

On a **GCE instance**, that's all you need — the attached service account is picked up from the metadata server, no login step required.

## Usage

| Flag | Purpose |
|------|---------|
| `-u`, `--update` | Upgrade an existing install |
| `--archive` | Install from the versioned tarball instead of the package repo |
| `--components LIST` | Extra components, comma-separated |
| `--login` | Interactive login (uses `--no-browser` on headless hosts) |
| `--service-account KEY_FILE` | Activate a service account from a JSON key file |
| `--adc` | Also write Application Default Credentials, for SDKs and Terraform |
| `-p`, `--project` | Default project ID |
| `-r`, `--region` | Default compute region, e.g. `us-central1` |
| `-z`, `--zone` | Default compute zone, e.g. `us-central1-a` |
| `-h`, `--help` | Display help and exit |

### Examples

Install, log in, and set project + zone:
```bash
./startup.sh --login -p amd-benchmarks -z us-central1-a
```

Log in and also write ADC, so Terraform and the client libraries authenticate too:
```bash
./startup.sh --login --adc
```

Service account for CI or a headless runner:
```bash
./startup.sh --service-account ~/sa-key.json -p amd-benchmarks
```

Add the GKE auth plugin, which `kubectl` needs to talk to GKE:
```bash
./startup.sh --components gke-gcloud-auth-plugin
```

Upgrade:
```bash
./startup.sh --update
```

## Package repo vs. archive

This is the one real decision to make up front, because it changes how you add components later.

| | Package repo *(default)* | Archive (`--archive`) |
|---|---|---|
| Upgrades | `apt upgrade` / `dnf update` | `gcloud components update` |
| Extra components | `apt install google-cloud-cli-<name>` | `gcloud components install <name>` |
| `gcloud components install` | **Disabled** — prints a warning and does nothing | Works |
| Install location | System paths | `~/google-cloud-sdk` |
| Needs root | Yes | No |
| Best for | Long-lived VMs, anything you'll patch | Lab machines, pinned versions, no-sudo environments |

The script hides most of this: `--components` installs `google-cloud-cli-<name>` packages on a repo install and calls the component manager on an archive install, so the same flag works either way. It only matters if you later add components by hand.

**What's in the base package:** `gcloud`, `gcloud alpha`, `gcloud beta`, `gsutil`, and `bq`. Not `kubectl`, not the GKE auth plugin, not the App Engine extensions — those install separately.

## Choosing an authentication method

| Where you're running | Use this |
|----------------------|----------|
| **GCE instance / GKE node** | **Nothing.** The attached service account comes from the metadata server. Give the instance the right service account and scopes at creation time. |
| **Laptop or SSH session** | `--login`. On a headless host the script uses `--no-browser` and prints a URL to open on your own machine. |
| **Terraform / client libraries** | Add `--adc`. SDKs read Application Default Credentials, which are **separate from** the `gcloud` CLI credential — logging in to the CLI alone does not authenticate Terraform. |
| **CI / GitHub Actions** | Workload Identity Federation — no key file at all. |
| **Last resort** | `--service-account` with a downloaded JSON key. Long-lived and sits on disk; restrict it tightly. |

That CLI-vs-ADC split trips people up regularly: `gcloud auth login` and `gcloud auth application-default login` write different credentials to different places. If Terraform reports no credentials while `gcloud` works fine, you want `--adc`.

With `--service-account --adc`, the script appends `GOOGLE_APPLICATION_CREDENTIALS` to your `~/.bashrc` — that's a persistent edit, so remove the line when you're done with the key.

## Supported platforms

| Distribution | Method |
|--------------|--------|
| Ubuntu, Debian, Mint, Pop!_OS | `apt` repo, dearmored key in `/usr/share/keyrings` + `signed-by` |
| RHEL, CentOS Stream, AlmaLinux, Rocky, Fedora | `dnf`/`yum` repo (`cloud-sdk-el8`/`el9`, `x86_64`/`aarch64`) |
| Anything else | Automatic fallback to the archive install |

The repo write uses `tee`, not `tee -a`, so re-running the script never produces the duplicate repo entries apt complains about.

> For a Windows or macOS workstation, use the installer from the Google Cloud docs — this script is Linux-only.

## Verifying it works

```bash
gcloud --version
gcloud auth list
gcloud config list
gcloud compute machine-types list --filter="zone:us-central1-a AND name~'^c3d'" --limit 5
```

The script prints the active account and project at the end, so a successful run already confirms auth.

If `gcloud: command not found` right after an `--archive` install, open a new shell — the installer updates `PATH` in `~/.bashrc`, which your current shell has already read.

## Related

- [`../aws/`](../aws/) · [`../azure/`](../azure/) · [`../oci/`](../oci/) — the same setup for the other clouds
- [`../../cca-export/gcp/`](../../cca-export/gcp/) — pull your GCP compute inventory for a Cloud Cost Assessment
- [`../../amd-iam-policies/gcp/`](../../amd-iam-policies/gcp/) — org policy constraints to steer new VMs toward AMD EPYC
