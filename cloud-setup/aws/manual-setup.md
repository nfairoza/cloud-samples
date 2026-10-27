# AWS — manual setup (without the script)

Everything [`startup.sh`](startup.sh) does, done by hand: install the CLI, create a credential in the Console, and configure the CLI to use it.

Use this when you can't or don't want to run the script — a locked-down workstation, a different OS, or you just want to see what's actually happening.

**Jump to:** [Install](#1-install-the-cli) · [Pick a credential](#2-pick-a-credential) · [IAM Identity Center](#2a-iam-identity-center-sso--preferred-on-a-laptop) · [EC2 role](#2b-ec2-instance-role--preferred-on-an-instance) · [Access key](#2c-iam-user-access-key--last-resort) · [Configure](#3-configure-the-cli) · [Verify](#4-verify) · [Permissions](#5-permissions-you-actually-need)

---

## 1. Install the CLI

### Linux — x86_64

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

For `aarch64`, swap `x86_64` for `aarch64` in the URL. To upgrade an existing install, add `--update` to the last line.

### macOS

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

### Windows

Download and run the MSI: `https://awscli.amazonaws.com/AWSCLIV2.msi`

Or from PowerShell:
```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

Open a **new** terminal afterwards so `PATH` is picked up.

### Verify the install

```bash
aws --version
```

You want `aws-cli/2.x`. If you see `aws-cli/1.x`, you have an old pip or distro install shadowing v2 — `which aws` to find it.

> **Don't use `apt install awscli` / `yum install awscli`.** Distro packages ship v1 or a stale v2. The commands above are what the AWS docs themselves use.

---

## 2. Pick a credential

In order of preference. Pick **one**.

| | Where | Expires | Secret on disk |
|---|---|---|---|
| [**Identity Center (SSO)**](#2a-iam-identity-center-sso--preferred-on-a-laptop) | Laptop, shared workstation | Hours | No |
| [**EC2 instance role**](#2b-ec2-instance-role--preferred-on-an-instance) | EC2, EKS | Minutes, auto-rotated | No |
| [**IAM user access key**](#2c-iam-user-access-key--last-resort) | Last resort | Never | **Yes** |

---

## 2a. IAM Identity Center (SSO) — preferred on a laptop

If your organization has Identity Center (the thing that gives you an `https://d-xxxx.awsapps.com/start` portal), use it. Credentials last hours instead of forever, and there's nothing to leak.

**You usually need nothing in the Console** — an admin has already assigned you to an account. Just run:

```bash
aws configure sso
```

It asks for:

| Prompt | What to enter |
|---|---|
| `SSO session name` | Anything, e.g. `amd` |
| `SSO start URL` | Your portal URL — `https://d-xxxx.awsapps.com/start` |
| `SSO region` | The region Identity Center lives in, e.g. `us-east-1` |
| `SSO registration scopes` | Press Enter for the default |

A browser opens; approve the request. Then pick your account and role from the list, and set a default region and output format. Give the profile a name you'll remember.

Day to day:

```bash
aws sso login --profile my-profile
aws s3 ls --profile my-profile
```

When the session expires, `aws sso login` again. Nothing else to rotate, ever.

> Don't know your start URL? It's in the email your admin sent, or ask them. There's no way to discover it from the CLI.

---

## 2b. EC2 instance role — preferred on an instance

On EC2, **do not put an access key on the box.** Attach a role instead. Credentials get delivered through the instance metadata service, rotate automatically, and never touch disk.

### Create the role

1. Console → **IAM** → **Roles** → **Create role**
2. **Trusted entity type:** AWS service
3. **Use case:** EC2 → **Next**
4. Attach the permissions the instance actually needs — see [§5](#5-permissions-you-actually-need). Don't attach `AdministratorAccess` to make something work.
5. Name it, e.g. `ec2-benchmark-role` → **Create role**

### Attach it to an instance

**New instance:** in the launch wizard, *Advanced details* → **IAM instance profile** → pick your role.

**Running instance:** Console → **EC2** → select the instance → **Actions** → **Security** → **Modify IAM role** → pick it → **Update IAM role**. No restart needed.

### Then on the instance

Nothing. Don't run `aws configure`. The CLI finds the role automatically:

```bash
aws sts get-caller-identity
```

You should see an ARN like `arn:aws:sts::123456789012:assumed-role/ec2-benchmark-role/i-0abc123`.

> If you previously ran `aws configure` on the box, those static keys **take priority over the role** and the role will appear not to work. Delete `~/.aws/credentials` to fall through to the role.

---

## 2c. IAM user access key — last resort

Only when neither of the above is available. An access key never expires and sits in a plaintext file.

### Create the user

1. Console → **IAM** → **Users** → **Create user**
2. Name it, e.g. `cli-benchmark-user`
3. **Do not** tick "Provide user access to the AWS Management Console" — this identity is for the CLI only
4. **Next** → **Attach policies directly** → attach what you need ([§5](#5-permissions-you-actually-need)) → **Create user**

### Create the key

1. Click the user → **Security credentials** tab
2. **Access keys** → **Create access key**
3. **Use case:** *Command Line Interface (CLI)* → tick the confirmation → **Next**
4. Optional description tag → **Create access key**
5. **Copy both values now.** The secret access key is shown **exactly once**. Close this page without copying it and you must delete the key and make a new one.

| Value | Looks like |
|---|---|
| Access key ID | `AKIAIOSFODNN7EXAMPLE` |
| Secret access key | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |

### Rotate it

Set yourself a reminder. To rotate: create a *second* key, switch your config over, confirm it works, then **deactivate** the old key (don't delete it yet), confirm nothing broke, then delete it. IAM allows two keys per user precisely so you can do this without downtime.

---

## 3. Configure the CLI

Skip this entirely if you used an **EC2 role**. For `aws configure sso`, it's already done.

### Interactive

```bash
aws configure
```

```
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: us-east-1
Default output format [None]: json
```

### Named profile — keeps accounts separate

```bash
aws configure --profile amd-demo
```

Then either pass `--profile amd-demo` on each command, or `export AWS_PROFILE=amd-demo`.

### By hand

`~/.aws/credentials` (Windows: `%USERPROFILE%\.aws\credentials`):

```ini
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[amd-demo]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY
```

`~/.aws/config`:

```ini
[default]
region = us-east-1
output = json

[profile amd-demo]
region = us-west-2
output = table
```

Two things that catch people:

- In `config`, named profiles need the literal word `profile` in the header (`[profile amd-demo]`). In `credentials`, they don't (`[amd-demo]`). This asymmetry is real and is a common source of "profile not found".
- On Linux/macOS: `chmod 600 ~/.aws/credentials`.

### Environment variables

Override everything, useful in CI:

```bash
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
```

---

## 4. Verify

```bash
aws sts get-caller-identity
```

```json
{
    "UserId": "AIDAIOSFODNN7EXAMPLE",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/cli-benchmark-user"
}
```

That ARN tells you *which* identity you're using — worth checking when you have several profiles.

Then something real:

```bash
aws ec2 describe-regions --output table
```

### When it doesn't work

| Message | Cause |
|---|---|
| `Unable to locate credentials` | Nothing configured, or wrong profile name. `aws configure list` shows what it's reading and from where. |
| `The security token included in the request is invalid` | Key was deleted or deactivated in IAM. |
| `SignatureDoesNotMatch` | Secret key is wrong — usually a copy/paste that clipped a character or picked up whitespace. |
| `ExpiredToken` | SSO session ended. `aws sso login --profile <name>`. |
| `AccessDenied` on a specific call | Credentials are **fine**; the identity lacks that permission. See [§5](#5-permissions-you-actually-need). |
| `SSL: CERTIFICATE_VERIFY_FAILED` | A trust-store problem, not a credential problem. See below. |
| `You must specify a region` | No default region. Add one to the profile or pass `--region`. |

**`CERTIFICATE_VERIFY_FAILED`.** Two different causes produce this identical message, so check which one you have before changing anything:

```bash
echo | openssl s_client -connect sts.us-east-2.amazonaws.com:443 \
    -servername sts.us-east-2.amazonaws.com 2>/dev/null \
  | openssl x509 -noout -issuer
```

If the issuer is **Amazon**, nothing is intercepting you — your CA bundle is simply missing the public roots, usually because `AWS_CA_BUNDLE` or `SSL_CERT_FILE` points at an exported site chain instead of a root store. That **replaces** the public roots rather than adding to them. Count what's in the file you're pointing at:

```bash
grep -c "BEGIN CERTIFICATE" "$AWS_CA_BUNDLE"
```

A real bundle has 100+ certificates; a site chain has about three. If the issuer is **your employer**, a proxy is re-signing traffic and you need the corporate root in your bundle.

Either way the fix is one bundle holding both — see [`../corporate-tls.md`](../corporate-tls.md) and [`../make-ca-bundle.sh`](../make-ca-bundle.sh):

```bash
../make-ca-bundle.sh --corp-cert corp-root.pem
export AWS_CA_BUNDLE="$HOME/ca-certs/combined-ca-bundle.pem"
```

`AWS_CA_BUNDLE` in the environment **overrides** `ca_bundle` in `~/.aws/config`, so a stale variable makes a correct config file look broken. Check both.

Do **not** work around this with `--no-verify-ssl` or `verify_ssl = false` — that disables certificate checking for every call, on the connection your credentials travel over.

---

## 5. Permissions you actually need

Start minimal and add what's missing. `AdministratorAccess` on a CLI credential is how a leaked key becomes a bad week.

| What you're doing | Policy |
|---|---|
| Read-only exploration | `ReadOnlyAccess` (AWS managed) |
| Launch/stop EC2 for benchmarks | `AmazonEC2FullAccess`, scoped down by region/tag if you can |
| [`cca-export/aws/`](../../cca-export/aws/) | Athena + Glue + S3 read on the CUR bucket |
| [`cloud-instance-manager`](#appendix-cloud-instance-manager) | See the appendix below |

Tightening by region is a quick win. This allows EC2 only in `us-east-1`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "ec2:*",
    "Resource": "*",
    "Condition": {
      "StringEquals": { "aws:RequestedRegion": "us-east-1" }
    }
  }]
}
```

---

## Appendix: cloud-instance-manager

The [`cloud-instance-manager`](https://github.com/nfairoza/cloud-samples) skill drives this CLI. Beyond the setup above it needs:

**An EC2 key pair**, so you can SSH to what it launches:

1. Console → **EC2** → **Key pairs** → **Create key pair**
2. Name it, e.g. `amd-poc`; type **ED25519** (or RSA); format **.pem**
3. It downloads once — save it, then `chmod 400 ~/.ssh/amd-poc.pem`
4. Put the **name** and the **path** in the skill's `config.yaml`:
   ```yaml
   aws:
     key_name: amd-poc
     ssh_private_key: ~/.ssh/amd-poc.pem
     ssh_user: ec2-user      # ubuntu images use: ubuntu
   ```

**A security group** allowing SSH inbound from your IP (port 22). The default VPC security group denies it.

**These IAM actions** — the operations the skill actually performs:

```
ec2:DescribeInstances, ec2:DescribeInstanceTypeOfferings, ec2:DescribeRegions,
ec2:DescribeImages, ec2:DescribeSecurityGroups, ec2:DescribeKeyPairs,
ec2:RunInstances, ec2:CreateTags,
ec2:StartInstances, ec2:StopInstances, ec2:TerminateInstances
```

`AmazonEC2FullAccess` covers all of it if you'd rather not hand-roll a policy.

Check it end to end with:

```bash
python scripts/manager.py doctor
```

---

## Related

- [`README.md`](README.md) — the scripted path
- [`../azure/manual-setup.md`](../azure/manual-setup.md) · [`../gcp/manual-setup.md`](../gcp/manual-setup.md) · [`../oci/manual-setup.md`](../oci/manual-setup.md)
