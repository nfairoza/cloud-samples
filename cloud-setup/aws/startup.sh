#!/bin/bash
#
# Install and configure the AWS CLI v2 on a Linux workstation or EC2 instance.
#
# Installs from the official AWS zip installer (distro packages ship v1 or a
# stale v2), optionally verifies the PGP signature, and optionally writes a
# named profile.
#
set -uo pipefail

AWS_PGP_FINGERPRINT="FB5DB77FD5C118B80511ADA8A6310ACC4672475C"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: ./startup.sh [options]

Install options:
  -u, --update          Update an existing AWS CLI v2 install in place
      --verify          Verify the installer PGP signature before installing
      --version VER     Install a specific version (e.g. 2.31.0) instead of latest

Configuration options (all optional):
  -k,  --key            AWS Access Key ID (must be paired with -sk)
  -sk, --secret-key     AWS Secret Access Key (must be paired with -k)
  -r,  --region         Default region (e.g. us-east-1)
  -p,  --profile        Write the settings to a named profile instead of default
  -o,  --output         Output format: json (default), yaml, text, table

  -h,  --help           Display this help message and exit

Examples:
  ./startup.sh                                   # install only
  ./startup.sh --verify                          # install, checking the signature
  ./startup.sh --update                          # upgrade an existing install
  ./startup.sh -r us-east-1                      # install + set default region
  ./startup.sh -k AKIA... -sk wJal... -r us-east-1
  ./startup.sh -k AKIA... -sk wJal... -p amd-demo

On EC2, prefer an attached IAM role over static keys - no credentials on disk,
and they rotate automatically. Run with no credential flags and the CLI picks
the role up from IMDS.
EOF
    exit 1
}

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

install_prereqs() {
    [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release; unsupported system."
    . /etc/os-release

    local pkgs=(unzip curl)
    [[ "$VERIFY_SIG" == "yes" ]] && pkgs+=(gnupg)

    log "Installing prerequisites: ${pkgs[*]}"
    case "$ID" in
        ubuntu|debian)
            sudo apt-get update -qq
            sudo apt-get install -y "${pkgs[@]}"
            ;;
        centos|rhel|almalinux|rocky|fedora|amzn|amazon)
            if command -v dnf &>/dev/null; then
                sudo dnf install -y "${pkgs[@]}"
            else
                sudo yum install -y "${pkgs[@]}"
            fi
            ;;
        sles|opensuse-leap|opensuse-tumbleweed)
            sudo zypper --non-interactive install "${pkgs[@]}"
            ;;
        *)
            fail "Unsupported Linux distribution: $ID. Install unzip/curl manually, then re-run."
            ;;
    esac
}

verify_signature() {
    local artifact="$1" sig_url="$2"
    local keyfile="$SCRIPT_DIR/aws-cli-public-key.asc"

    # AWS publishes its signing key only inside a documentation page - there is
    # no stable raw URL to pin - so the key is vendored next to this script and
    # checked by fingerprint.
    [[ -f "$keyfile" ]] || fail "Missing $keyfile

--verify needs the AWS CLI public key. One-time setup:
  1. Open https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  2. Copy the whole 'BEGIN PGP PUBLIC KEY BLOCK' ... 'END PGP PUBLIC KEY BLOCK'
  3. Save it as $keyfile

Expected fingerprint: $AWS_PGP_FINGERPRINT"

    # Throwaway keyring - never touch the user's own GPG state.
    local gnupg_tmp
    gnupg_tmp=$(mktemp -d)
    chmod 700 "$gnupg_tmp"
    export GNUPGHOME="$gnupg_tmp"

    gpg --quiet --import "$keyfile" || fail "Could not import $keyfile"

    local got
    got=$(gpg --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    [[ "$got" == "$AWS_PGP_FINGERPRINT" ]] || fail "Key fingerprint mismatch.
  expected: $AWS_PGP_FINGERPRINT
  got:      ${got:-<none>}
Re-copy the key from the AWS documentation page."

    log "Downloading signature"
    curl -fsSL "$sig_url" -o "${artifact}.sig" || fail "Could not download $sig_url"

    # gpg exits 0 for a signature made by an EXPIRED key (EXPKEYSIG), so check
    # the status output for GOODSIG rather than trusting the exit code.
    log "Verifying signature"
    local status
    status=$(gpg --status-fd 1 --verify "${artifact}.sig" "$artifact" 2>/dev/null)
    grep -q '^\[GNUPG:\] GOODSIG' <<<"$status" || fail "Signature check FAILED - not installing.

$status"

    log "Good signature."
    unset GNUPGHOME
    rm -rf "$gnupg_tmp"
}

install_aws_cli() {
    local arch base url sig_url tmp
    arch=$(uname -m)

    case "$arch" in
        x86_64)  base="https://awscli.amazonaws.com/awscli-exe-linux-x86_64" ;;
        aarch64) base="https://awscli.amazonaws.com/awscli-exe-linux-aarch64" ;;
        *)       fail "Unsupported architecture: $arch" ;;
    esac

    if [[ -n "$PIN_VERSION" ]]; then
        url="${base}-${PIN_VERSION}.zip"
    else
        url="${base}.zip"
    fi
    sig_url="${url}.sig"

    install_prereqs

    tmp=$(mktemp -d)

    log "Downloading AWS CLI v2 (${PIN_VERSION:-latest}, $arch)"
    curl -fsSL "$url" -o "$tmp/awscliv2.zip" || { rm -rf "$tmp"; fail "Download failed: $url"; }

    [[ "$VERIFY_SIG" == "yes" ]] && verify_signature "$tmp/awscliv2.zip" "$sig_url"

    unzip -q "$tmp/awscliv2.zip" -d "$tmp"

    if [[ "$DO_UPDATE" == "yes" ]]; then
        log "Updating existing install"
        sudo "$tmp/aws/install" --update
    else
        log "Installing"
        sudo "$tmp/aws/install"
    fi

    rm -rf "$tmp"
}

configure_aws_cli() {
    local profile_args=()
    [[ -n "$AWS_PROFILE_NAME" ]] && profile_args=(--profile "$AWS_PROFILE_NAME")

    if [[ -n "$AWS_ACCESS_KEY_ID" || -n "$AWS_SECRET_ACCESS_KEY" ]]; then
        if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
            fail "Both Access Key (-k) and Secret Key (-sk) must be provided together."
        fi
        log "Writing credentials${AWS_PROFILE_NAME:+ to profile '$AWS_PROFILE_NAME'}"
        aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     "${profile_args[@]}"
        aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" "${profile_args[@]}"
    fi

    if [[ -n "$AWS_REGION" ]]; then
        log "Setting region to $AWS_REGION"
        aws configure set region "$AWS_REGION" "${profile_args[@]}"
    fi

    if [[ -n "$AWS_OUTPUT" ]]; then
        aws configure set output "$AWS_OUTPUT" "${profile_args[@]}"
    fi
}

AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_REGION=""
AWS_PROFILE_NAME=""
AWS_OUTPUT=""
VERIFY_SIG="no"
DO_UPDATE="no"
PIN_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--key)         AWS_ACCESS_KEY_ID="${2:-}";     shift 2 ;;
        -sk|--secret-key) AWS_SECRET_ACCESS_KEY="${2:-}"; shift 2 ;;
        -r|--region)      AWS_REGION="${2:-}";            shift 2 ;;
        -p|--profile)     AWS_PROFILE_NAME="${2:-}";      shift 2 ;;
        -o|--output)      AWS_OUTPUT="${2:-}";            shift 2 ;;
        -u|--update)      DO_UPDATE="yes";                shift   ;;
        --verify)         VERIFY_SIG="yes";               shift   ;;
        --version)        PIN_VERSION="${2:-}";           shift 2 ;;
        -h|--help)        usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if aws --version &>/dev/null; then
    if [[ "$DO_UPDATE" == "yes" || -n "$PIN_VERSION" ]]; then
        install_aws_cli
    else
        log "AWS CLI already installed: $(aws --version 2>&1). Re-run with --update to upgrade."
    fi
else
    install_aws_cli
fi

hash -r 2>/dev/null || true

if aws --version &>/dev/null; then
    log "AWS CLI ready: $(aws --version 2>&1)"
else
    fail "AWS CLI installation failed."
fi

configure_aws_cli

PROFILE_ARG=()
[[ -n "$AWS_PROFILE_NAME" ]] && PROFILE_ARG=(--profile "$AWS_PROFILE_NAME")

if aws sts get-caller-identity "${PROFILE_ARG[@]}" &>/dev/null; then
    log "Authenticated as: $(aws sts get-caller-identity --query Arn --output text "${PROFILE_ARG[@]}" 2>/dev/null)"
else
    cat <<'EOF'

AWS CLI is installed but not authenticated. Pick one:
  - EC2 / EKS:  attach an IAM role to the instance - nothing else to do
  - SSO:        aws configure sso
  - Static key: ./startup.sh -k <ACCESS_KEY> -sk <SECRET_KEY> -r <region>
EOF
fi
