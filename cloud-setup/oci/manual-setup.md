# OCI — manual setup (without the script)

Everything [`startup.sh`](startup.sh) does, done by hand: install the CLI, create a credential in the Console, and configure the CLI to use it.

Use this when you can't or don't want to run the script — a locked-down workstation, a different OS, or you just want to see what's actually happening.

**Jump to:** [Install](#1-install-the-cli) · [Pick a credential](#2-pick-a-credential) · [Session token](#2a-session-token--preferred-on-a-laptop) · [Instance principal](#2b-instance-principal--preferred-on-an-instance) · [API key](#2c-api-signing-key--scripted-workstation-use) · [Config file](#3-the-config-file) · [Verify](#4-verify) · [Permissions](#5-permissions-you-actually-need)

---

## 1. Install the CLI

### Linux / macOS — Oracle's installer

Interactive:
```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Non-interactive:
```bash
curl -o install.sh https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh
bash ./install.sh --accept-all-defaults \
  --update-path-and-enable-tab-completion \
  --rc-file-path $HOME/.bashrc
```

The installer asks for an install directory (default `~/lib/oracle-cli`), a scripts directory (default `~/bin`), and optional extra packages — press Enter through them. **If your system Python is too old it installs a private Python for you**, which is why this is preferred over `pip install oci-cli` into system site-packages.

Run `./install.sh -h` to see every option.

### Oracle Linux — dnf

```bash
sudo dnf install -y oraclelinux-developer-release-el9
sudo dnf install -y oci-cli
```

Use `el8` on Oracle Linux 8. OL8 and OL7 default to older Python builds; Oracle recommends 3.9+.

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1'))"
```

### Verify

```bash
exec -l $SHELL     # reload PATH
oci --version
```

> `oci: command not found` right after installing is normal — the installer appended to `~/.bashrc`, which your current shell already read. Open a new shell or run `exec -l $SHELL`.

---

## 2. Pick a credential

In order of preference. Pick **one**.

| | Where | Expires | Secret on disk |
|---|---|---|---|
| [**Session token**](#2a-session-token--preferred-on-a-laptop) | Laptop, interactive | ~1 hour, refreshable | Short-lived token |
| [**Instance principal**](#2b-instance-principal--preferred-on-an-instance) | OCI compute | Minutes, auto-rotated | No |
| [**API signing key**](#2c-api-signing-key--scripted-workstation-use) | Scripted workstation use | Never | **Yes** |

---

## 2a. Session token — preferred on a laptop

Browser login, short-lived token, no key pair to generate or upload.

```bash
oci session authenticate
```

You'll be asked for a region and a profile name; a browser opens for login. Then use it with:

```bash
oci iam region list --profile <PROFILE_NAME>
```

Refresh before it expires (roughly an hour):

```bash
oci session refresh --profile <PROFILE_NAME>
```

Nothing to upload in the Console, and nothing long-lived left behind. Best default for interactive work.

---

## 2b. Instance principal — preferred on an instance

On OCI compute, **don't generate an API key on the box.** Let the instance itself be the identity.

Unlike the other clouds, this takes two Console steps — the instance must be in a **dynamic group**, and a **policy** must grant that group access.

### Step 1 — dynamic group

1. Console → **Identity & Security** → **Domains** → your domain → **Dynamic groups** → **Create dynamic group**
2. Name it, e.g. `benchmark-instances`
3. Add a matching rule — one of:

   | Rule | Matches |
   |---|---|
   | `instance.compartment.id = 'ocid1.compartment.oc1..aaaa'` | Every instance in that compartment |
   | `instance.id = 'ocid1.instance.oc1..aaaa'` | One specific instance |
   | `tag.benchmark.value = 'true'` | Anything tagged that way |

   Compartment-based is usually right — new instances in that compartment are covered automatically.
4. **Create**

### Step 2 — policy

1. Console → **Identity & Security** → **Policies** → **Create policy**
2. Pick the compartment it applies to
3. Switch to the manual editor and write:

```
Allow dynamic-group benchmark-instances to manage instance-family in compartment MyCompartment
Allow dynamic-group benchmark-instances to read all-resources in compartment MyCompartment
```

Narrow `manage` to `read` / `use` / `inspect` where that's enough — see [§5](#5-permissions-you-actually-need).

### Step 3 — on the instance

```bash
export OCI_CLI_AUTH=instance_principal
oci iam region list
```

Or per command: `oci iam region list --auth instance_principal`

Make it permanent:
```bash
echo 'export OCI_CLI_AUTH=instance_principal' >> ~/.bashrc
```

> **No `~/.oci/config` needed** — but if you want a default region without a full config, a region-only file is valid:
> ```ini
> [DEFAULT]
> region=us-ashburn-1
> ```

---

## 2c. API signing key — scripted workstation use

A long-lived RSA key pair. The private half sits in `~/.oci` forever, so rotate it on a schedule.

### Generate the key and config

```bash
oci setup config
```

Prompts:

| Prompt | Where to find it |
|---|---|
| Config location | Enter for `~/.oci/config` |
| **User OCID** | Console → **Profile** (top right) → **My profile** → OCID |
| **Tenancy OCID** | Console → **Profile** → **Tenancy: <name>** → OCID |
| Region | e.g. `us-ashburn-1` |
| Generate a new API Signing RSA key pair? | **Y** |
| Key directory | Enter for `~/.oci` |
| Passphrase | Optional — adds a prompt to every command |

Output:

```
Public key written to ~/.oci/oci_api_key_public.pem
Private key written to ~/.oci/oci_api_key.pem
Fingerprint: 12:34:56:78:...
Config written to ~/.oci/config
```

To generate only a key pair and write the config yourself: `oci setup keys`.

### Upload the public key

The config is useless until the Console knows your public key.

1. Console → **Profile** → **My profile**
2. **Resources** → **API keys** → **Add API key**
3. **Paste a public key**
4. Paste the entire contents of `~/.oci/oci_api_key_public.pem`, including the `-----BEGIN PUBLIC KEY-----` and `-----END PUBLIC KEY-----` lines
5. **Add**

The Console then shows a **configuration file preview**. If you'd rather use that than what `oci setup config` wrote, copy it into `~/.oci/config` and set `key_file` to your private key path.

```bash
cat ~/.oci/oci_api_key_public.pem
```

### Fix the permissions

**The CLI refuses to run if the config or key is group- or world-readable.** This is the single most common OCI CLI failure:

```bash
chmod 700 ~/.oci
chmod 600 ~/.oci/config
chmod 600 ~/.oci/*.pem
```

---

## 3. The config file

`~/.oci/config`:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaaaaaa<unique_ID>
fingerprint=12:34:56:78:90:ab:cd:ef:12:34:56:78:90:ab:cd:ef
key_file=~/.oci/oci_api_key.pem
tenancy=ocid1.tenancy.oc1..aaaaaaaa<unique_ID>
region=us-ashburn-1

[AMD-DEMO]
user=ocid1.user.oc1..aaaaaaaa<other_ID>
fingerprint=ab:cd:ef:...
key_file=~/.oci/amd-demo.pem
tenancy=ocid1.tenancy.oc1..aaaaaaaa<unique_ID>
region=us-phoenix-1
```

Use a profile with `--profile AMD-DEMO`, or `export OCI_CLI_PROFILE=AMD-DEMO`.

Three things that break this file:

- **No inline comments.** `region=us-ashburn-1  # ashburn` fails to parse. Comments go on their own line.
- **Permissions**, as above.
- `pass_phrase=` is only needed if you set one when generating the key.

---

## 4. Verify

```bash
oci iam region list --output table
```

With an instance principal:
```bash
oci iam region list --auth instance_principal --output table
```

Then something real:

```bash
oci iam compartment list --output table
oci compute shape list --compartment-id <COMPARTMENT_OCID> --output table
```

### When it doesn't work

| Message | Cause |
|---|---|
| `Could not find config file at ~/.oci/config` | Not set up, or `OCI_CLI_CONFIG_FILE` points elsewhere. |
| `Permissions on the config/key file are too open` | `chmod 600` the file, `chmod 700 ~/.oci`. Very common. |
| `NotAuthenticated` | Public key not uploaded, fingerprint mismatch, or wrong `key_file`. Compare the fingerprint in the Console against your config. |
| `NotAuthorizedOrNotFound` | Authenticated fine, but no policy grants that action — **or** the resource is in a different compartment. OCI returns the same error for both, deliberately. |
| `Instance principal auth failed` | Not on an OCI instance, or the instance isn't in a dynamic group that a policy covers. |
| `oci: command not found` | `exec -l $SHELL`, or open a new shell. |
| `ServiceError ... 404` on a compartment | Wrong compartment OCID, or no `inspect` permission on it. |

**Corporate proxy:** `export HTTPS_PROXY=http://proxy.corp.example.com:3128`

**Certificate failures.** The OCI CLI is Python/requests-based, so it reads `REQUESTS_CA_BUNDLE`:

```bash
export REQUESTS_CA_BUNDLE="$HOME/ca-certs/combined-ca-bundle.pem"
```

The bundle must hold the public roots **and** your corporate CA — see [`../corporate-tls.md`](../corporate-tls.md) and [`../make-ca-bundle.sh`](../make-ca-bundle.sh).

---

## 5. Permissions you actually need

OCI policies read almost like English: `Allow <subject> to <verb> <resource-type> in <scope>`.

The four verbs, weakest to strongest — each includes the ones before it:

| Verb | Lets you |
|---|---|
| `inspect` | List resources |
| `read` | List + get details |
| `use` | Read + act on existing resources (start/stop) |
| `manage` | Everything, including create and delete |

| What you're doing | Policy |
|---|---|
| Read-only exploration | `Allow group MyGroup to read all-resources in tenancy` |
| Start/stop existing instances | `Allow group MyGroup to use instance-family in compartment MyCompartment` |
| Launch and terminate instances | `Allow group MyGroup to manage instance-family in compartment MyCompartment` |
| [`cloud-instance-manager`](#appendix-cloud-instance-manager) | See the appendix |

Creating a policy: Console → **Identity & Security** → **Policies** → **Create policy** → pick the compartment → manual editor.

Prefer `use` over `manage` where it's enough — `manage` includes terminate.

---

## Appendix: cloud-instance-manager

> **OCI is not currently supported by the skill.** Its `enabled_clouds` and cloud modules cover **AWS, GCP, and Azure** only. This section is here for when that changes, and because the policy below is what you'd want anyway for scripted instance work.

Launching and managing instances from the CLI needs:

```
Allow group MyGroup to manage instance-family in compartment MyCompartment
Allow group MyGroup to use volume-family in compartment MyCompartment
Allow group MyGroup to use virtual-network-family in compartment MyCompartment
Allow group MyGroup to read all-resources in compartment MyCompartment
```

The volume and network grants are easy to forget: launching an instance also creates a boot volume and attaches a VNIC, so `instance-family` alone fails partway through with `NotAuthorizedOrNotFound`.

You'll also need, for any launch:

- a **compartment OCID** — Console → **Identity & Security** → **Compartments**
- a **subnet OCID** in that compartment, with a security list allowing inbound TCP 22
- an **SSH public key** to pass at launch (`ssh-keygen -t ed25519 -f ~/.ssh/oci-poc`)
- an **image OCID** for your shape — `oci compute image list --compartment-id <OCID> --output table`

AMD shapes to look for: `VM.Standard.E4.Flex` and `VM.Standard.E5.Flex` (EPYC). [`../../amd-iam-policies/oci/`](../../amd-iam-policies/oci/) has an allow-list policy and compartment quotas for steering new instances toward them.

---

## Related

- [`README.md`](README.md) — the scripted path
- [`../aws/manual-setup.md`](../aws/manual-setup.md) · [`../azure/manual-setup.md`](../azure/manual-setup.md) · [`../gcp/manual-setup.md`](../gcp/manual-setup.md)
