# Corporate TLS and CA bundles

Every cloud CLI eventually fails the same way on a managed corporate laptop:

```
SSL validation failed for https://sts.us-east-2.amazonaws.com/
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
unable to get local issuer certificate
```

This is almost never a credential problem. It's a trust problem — the CLI is checking the server's certificate against a list of trusted CAs, and the right CA isn't on that list.

**Jump to:** [Diagnose it first](#diagnose-it-first) · [The two causes](#the-two-causes) · [Build a combined bundle](#build-a-combined-bundle) · [Point each CLI at it](#point-each-cli-at-it) · [Which variable wins](#which-variable-wins) · [Don't disable verification](#dont-disable-verification)

---

## Diagnose it first

Before changing anything, find out *what the server is actually presenting.* The whole fix depends on this answer, and guessing wrong wastes an afternoon.

```bash
echo | openssl s_client -connect sts.us-east-2.amazonaws.com:443 \
    -servername sts.us-east-2.amazonaws.com 2>/dev/null \
  | openssl x509 -noout -issuer
```

Read the issuer:

| Issuer looks like | What's happening |
|-------------------|------------------|
| `O=Amazon`, `CN=Amazon RSA 2048 M01` | **Genuine Amazon chain.** Not intercepted. Your bundle is just missing public roots, or an env var is pointing at the wrong file. |
| Your employer's name | **TLS interception.** A proxy is terminating the connection and re-signing with a corporate CA. You need that CA in your bundle. |

Both end up at the same fix — a bundle containing the right roots — but they're different problems, and the first one is far more common than people assume.

Now check whether a bundle actually verifies the chain:

```bash
echo | openssl s_client -connect sts.us-east-2.amazonaws.com:443 \
    -servername sts.us-east-2.amazonaws.com \
    -CAfile /path/to/bundle.pem 2>&1 | grep "Verify return code"
```

`Verify return code: 0 (ok)` is what you want. Anything else and that bundle is not the one.

| Code | Means |
|------|-------|
| `0 (ok)` | Chain verified. This bundle works for this host. |
| `20 (unable to get local issuer certificate)` | The root isn't in your bundle. |
| `21 (unable to verify the first certificate)` | An intermediate is missing from the chain *or* the root isn't trusted. |

Run that against both a public endpoint and an internal one. A bundle that fixes one often breaks the other — which is the single most common way this gets misconfigured.

---

## The two causes

### Cause 1 — the bundle is an internal chain, not a CA list

This is the trap. Someone exports a certificate chain from an internal site to debug a corporate TLS problem, points `SSL_CERT_FILE` at it, and it works — for that site. But that file holds three certificates (a leaf, an issuing CA, a root), and it **replaces** the public root list rather than adding to it. Every public endpoint now fails.

Count the certificates in whatever your variables point at:

```bash
grep -c "BEGIN CERTIFICATE" "$SSL_CERT_FILE"
```

A real CA bundle has **100+** certificates. If you see a single digit, you've found your problem — that's a site chain, not a trust store.

### Cause 2 — genuine interception, corporate root missing

Here the public bundle is fine but lacks your employer's root CA, so internal sites fail while public ones work. The fix is the same combined bundle; you just need the corporate root added.

Get the corporate root from your IT self-service portal, or export it from the chain of any internal HTTPS site:

```bash
openssl s_client -showcerts -connect internal.example.com:443 \
    -servername internal.example.com </dev/null 2>/dev/null \
  | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > corp-chain.pem
```

> Many servers send only their own leaf certificate and no intermediates, so this can come back with nothing usable — a leaf must never go into a trust store. If that happens, get the root from IT or export it from your browser's certificate viewer instead.

Inspect what you got before trusting it:

```bash
openssl crl2pkcs7 -nocrl -certfile corp-chain.pem \
  | openssl pkcs7 -print_certs -noout
```

You want the **CA** certificates — the ones where subject and issuer describe a CA, not the leaf for the website. The self-signed one (subject == issuer) is the root.

---

## Build a combined bundle

The durable fix is one file holding the public roots **and** your corporate CAs. [`make-ca-bundle.sh`](make-ca-bundle.sh) does this:

```bash
chmod +x make-ca-bundle.sh
./make-ca-bundle.sh --corp-cert corp-chain.pem -o ~/ca-certs/combined-ca-bundle.pem
```

It takes the public roots as its base, appends only the CA certificates from the files you pass, skips duplicates and leaf certificates, then verifies the result against a public and an internal host before writing it.

Check its work yourself — the script prints this, but it's worth knowing the command:

```bash
for h in sts.us-east-2.amazonaws.com login.microsoftonline.com \
         oauth2.googleapis.com internal.example.com; do
  printf '%-36s ' "$h"
  echo | openssl s_client -connect "$h:443" -servername "$h" \
      -CAfile ~/ca-certs/combined-ca-bundle.pem 2>&1 \
    | grep -m1 "Verify return code"
done
```

Every line should say `0 (ok)`. Rebuild the bundle when your corporate CA rotates — it will.

---

## Point each CLI at it

Each cloud reads a different variable, and some read more than one.

| Cloud | Setting | Scope |
|-------|---------|-------|
| **AWS** | `AWS_CA_BUNDLE` env var, or `ca_bundle` in `~/.aws/config` | CLI + Python SDK |
| **Azure** | `REQUESTS_CA_BUNDLE` env var | `az` is Python/requests-based |
| **GCP** | `gcloud config set core/custom_ca_certs_file <path>` | `gcloud` only |
| **OCI** | `REQUESTS_CA_BUNDLE` env var | `oci` is Python/requests-based |
| Python (`requests`) | `REQUESTS_CA_BUNDLE`, else `CURL_CA_BUNDLE` | |
| OpenSSL / `curl` | `SSL_CERT_FILE` | |
| Node.js | `NODE_EXTRA_CA_CERTS` | **Appends** to the built-in list rather than replacing it |
| Git | `git config --global http.sslCAInfo <path>` | |

Linux/macOS — add to `~/.bashrc` or `~/.zshrc`:

```bash
export CA_BUNDLE="$HOME/ca-certs/combined-ca-bundle.pem"
export AWS_CA_BUNDLE="$CA_BUNDLE"
export REQUESTS_CA_BUNDLE="$CA_BUNDLE"
export SSL_CERT_FILE="$CA_BUNDLE"
export NODE_EXTRA_CA_CERTS="$CA_BUNDLE"
```

Windows — persist for your user account:

```powershell
$bundle = "$env:USERPROFILE\ca-certs\combined-ca-bundle.pem"
foreach ($n in 'AWS_CA_BUNDLE','REQUESTS_CA_BUNDLE','SSL_CERT_FILE','NODE_EXTRA_CA_CERTS') {
    [Environment]::SetEnvironmentVariable($n, $bundle, 'User')
}
```

Open a new terminal afterwards. GCP needs its own command regardless of the variables:

```bash
gcloud config set core/custom_ca_certs_file "$CA_BUNDLE"
```

---

## Which variable wins

When a setting is in two places, the AWS CLI resolves in this order — **highest wins**:

1. `--ca-bundle` on the command line
2. `AWS_CA_BUNDLE` environment variable
3. `ca_bundle` in `~/.aws/config`

So a stale **machine-level** `AWS_CA_BUNDLE` silently overrides a perfectly good `ca_bundle` in your config file, and the config file looks correct while the CLI ignores it. On Windows, check both scopes — a machine-level variable set by IT won't show up when you only look at your user environment:

```powershell
foreach ($t in 'User','Machine') {
    foreach ($n in 'AWS_CA_BUNDLE','REQUESTS_CA_BUNDLE','SSL_CERT_FILE') {
        $v = [Environment]::GetEnvironmentVariable($n, $t)
        if ($v) { "$t  $n = $v" }
    }
}
```

On Linux/macOS, `env | grep -i ca_bundle` plus a grep through your shell rc files covers it.

---

## Don't disable verification

Every one of these turns off certificate checking:

```ini
# ~/.aws/config  — do not do this
verify_ssl = false
```

```bash
aws --no-verify-ssl ...                 # AWS
export GODEBUG=x509ignoreCN=0           # cargo-culted, does nothing useful here
gcloud config set auth/disable_ssl_validation true
export PYTHONHTTPSVERIFY=0
```

They all make the error message disappear while leaving you with an unauthenticated, trivially interceptable connection to your cloud control plane — the exact channel your credentials travel over. A `verify_ssl = false` left in a config file after a debugging session is a credential-theft vector that nothing will ever warn you about again.

If you're stuck, leave verification on and keep working the bundle. The diagnosis commands at the top will tell you what's missing.

One legitimate narrow exception: a one-off `--no-verify-ssl` to *confirm* that TLS is the problem and not your credentials. Run it once, learn what you needed, and don't write it to a config file.

---

## Related

- [`aws/manual-setup.md`](aws/manual-setup.md) · [`azure/manual-setup.md`](azure/manual-setup.md) · [`gcp/manual-setup.md`](gcp/manual-setup.md) · [`oci/manual-setup.md`](oci/manual-setup.md)
- [`make-ca-bundle.sh`](make-ca-bundle.sh) — build the combined bundle
- [`README.md`](README.md) — cloud-setup overview
