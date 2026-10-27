#!/bin/bash
#
# Install and configure the Google Cloud CLI (gcloud) on a Linux workstation
# or GCE instance.
#
# Installs from Google's package repository by default, so upgrades arrive
# through apt/dnf. Note that on a package install the component manager is
# disabled - extra components are installed as packages, not with
# 'gcloud components install'.
#
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: ./startup.sh [options]

Install options:
  -u, --update            Upgrade an existing gcloud install
      --archive           Install from the versioned tarball instead of the
                          package repo (enables 'gcloud components install')
      --components LIST   Extra components, comma-separated.
                          e.g. --components gke-gcloud-auth-plugin,kubectl

Configuration options (all optional):
  -p, --project           Default project ID
  -r, --region            Default compute region, e.g. us-central1
  -z, --zone              Default compute zone, e.g. us-central1-a

Authentication (choose at most one; omit to skip login):
      --login             Interactive login (uses --no-browser over SSH)
      --service-account KEY_FILE
                          Activate a service account from a JSON key file
      --adc               Also write Application Default Credentials, for SDKs
                          and Terraform (pairs with --login)

  -h, --help              Display this help message and exit

Examples:
  ./startup.sh                                      # install only
  ./startup.sh --login -p my-project -z us-central1-a
  ./startup.sh --login --adc                        # CLI + ADC for Terraform/SDKs
  ./startup.sh --service-account ~/sa-key.json -p my-project
  ./startup.sh --components gke-gcloud-auth-plugin
  ./startup.sh --update

On a GCE instance, skip authentication entirely - the attached service account
is picked up from the metadata server automatically.
EOF
    exit 1
}

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

install_apt() {
    log "Installing Google Cloud CLI from the Google apt repository"
    sudo apt-get update -qq
    sudo apt-get install -y apt-transport-https ca-certificates gnupg curl

    # Dearmored key in /usr/share/keyrings + signed-by, so only Google-signed
    # packages are accepted from this repo.
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | sudo gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg

    # tee (not tee -a) so re-running doesn't create duplicate repo entries,
    # which apt warns about.
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null

    sudo apt-get update -qq
    sudo apt-get install -y google-cloud-cli

    local c
    for c in "${COMPONENT_LIST[@]}"; do
        log "Installing component package: google-cloud-cli-$c"
        sudo apt-get install -y "google-cloud-cli-$c" \
            || log "No package google-cloud-cli-$c - skipping"
    done
}

install_dnf() {
    log "Installing Google Cloud CLI from the Google dnf/yum repository"
    . /etc/os-release

    # Google publishes cloud-sdk-el{8,9}-{x86_64,aarch64}. Map the host onto
    # one of those; derivatives reporting anything else fall back to el9.
    local el arch
    case "${VERSION_ID%%.*}" in
        8) el="el8" ;;
        *) el="el9" ;;
    esac
    case "$(uname -m)" in
        x86_64)  arch="x86_64"  ;;
        aarch64) arch="aarch64" ;;
        *) fail "Unsupported architecture: $(uname -m)" ;;
    esac

    sudo tee /etc/yum.repos.d/google-cloud-sdk.repo >/dev/null <<EOF
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-${el}-${arch}
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

    if command -v dnf &>/dev/null; then
        sudo dnf install -y google-cloud-cli
    else
        sudo yum install -y google-cloud-cli
    fi

    local c
    for c in "${COMPONENT_LIST[@]}"; do
        log "Installing component package: google-cloud-cli-$c"
        if command -v dnf &>/dev/null; then
            sudo dnf install -y "google-cloud-cli-$c" || log "No package google-cloud-cli-$c - skipping"
        else
            sudo yum install -y "google-cloud-cli-$c" || log "No package google-cloud-cli-$c - skipping"
        fi
    done
}

install_archive() {
    log "Installing Google Cloud CLI from the versioned archive"
    local arch tarball tmp
    case "$(uname -m)" in
        x86_64)  arch="x86_64"  ;;
        aarch64) arch="arm"     ;;
        *) fail "Unsupported architecture: $(uname -m)" ;;
    esac

    tarball="google-cloud-cli-linux-${arch}.tar.gz"
    tmp=$(mktemp -d)

    curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}" \
        -o "$tmp/$tarball" || { rm -rf "$tmp"; fail "Download failed."; }

    local target="${GCLOUD_INSTALL_DIR:-$HOME}"
    tar -xzf "$tmp/$tarball" -C "$target"
    rm -rf "$tmp"

    "$target/google-cloud-sdk/install.sh" --quiet --path-update true \
        --command-completion true --rc-path "$HOME/.bashrc"

    # install.sh edits .bashrc for future shells; this process needs it now.
    export PATH="$target/google-cloud-sdk/bin:$PATH"

    if (( ${#COMPONENT_LIST[@]} )); then
        log "Installing components: ${COMPONENT_LIST[*]}"
        gcloud components install --quiet "${COMPONENT_LIST[@]}"
    fi
}

install_gcloud() {
    if [[ "$USE_ARCHIVE" == "yes" ]]; then
        install_archive
        return
    fi

    [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release; unsupported system."
    . /etc/os-release

    case "$ID" in
        ubuntu|debian|linuxmint|pop)                  install_apt ;;
        rhel|centos|almalinux|rocky|fedora)           install_dnf ;;
        *)
            log "No package repo for '$ID' - falling back to the archive install"
            install_archive
            ;;
    esac
}

update_gcloud() {
    # On a package install the component manager is disabled: 'gcloud components
    # update' prints a warning and does nothing. Use the package manager there.
    if [[ -n "$(command -v apt-get)" ]] && dpkg -s google-cloud-cli &>/dev/null; then
        log "Upgrading via apt"
        sudo apt-get update -qq && sudo apt-get install -y --only-upgrade google-cloud-cli
    elif rpm -q google-cloud-cli &>/dev/null 2>&1; then
        log "Upgrading via dnf/yum"
        command -v dnf &>/dev/null && sudo dnf update -y google-cloud-cli \
                                   || sudo yum update -y google-cloud-cli
    else
        log "Upgrading via the component manager"
        gcloud components update --quiet
    fi
}

do_login() {
    case "$LOGIN_MODE" in
        none) return 0 ;;

        user)
            log "Starting login"
            # --no-browser prints a URL to open elsewhere; required on headless
            # hosts, harmless to prefer when we can't detect a display.
            if [[ -n "${DISPLAY:-}" ]]; then
                gcloud auth login --quiet || fail "Login failed."
            else
                gcloud auth login --no-browser || fail "Login failed."
            fi

            if [[ "$WRITE_ADC" == "yes" ]]; then
                log "Writing Application Default Credentials"
                if [[ -n "${DISPLAY:-}" ]]; then
                    gcloud auth application-default login --quiet \
                        || log "ADC login failed - SDKs and Terraform will not pick up credentials"
                else
                    gcloud auth application-default login --no-browser \
                        || log "ADC login failed - SDKs and Terraform will not pick up credentials"
                fi
            fi
            ;;

        sa)
            [[ -f "$SA_KEY_FILE" ]] || fail "Service account key not found: $SA_KEY_FILE"
            log "Activating service account from $SA_KEY_FILE"
            gcloud auth activate-service-account --key-file "$SA_KEY_FILE" \
                || fail "Could not activate the service account."

            if [[ "$WRITE_ADC" == "yes" ]]; then
                log "Pointing GOOGLE_APPLICATION_CREDENTIALS at the key file"
                echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$SA_KEY_FILE\"" >> "$HOME/.bashrc"
                export GOOGLE_APPLICATION_CREDENTIALS="$SA_KEY_FILE"
            fi
            ;;
    esac
}

configure_gcloud() {
    if [[ -n "$PROJECT_ID" ]]; then
        log "Setting default project: $PROJECT_ID"
        gcloud config set project "$PROJECT_ID" \
            || fail "Could not set project '$PROJECT_ID'. Run 'gcloud projects list'."
    fi
    [[ -n "$REGION" ]] && { log "Setting compute/region = $REGION"; gcloud config set compute/region "$REGION"; }
    [[ -n "$ZONE"   ]] && { log "Setting compute/zone = $ZONE";     gcloud config set compute/zone   "$ZONE";   }
    return 0
}

PROJECT_ID=""
REGION=""
ZONE=""
LOGIN_MODE="none"
SA_KEY_FILE=""
WRITE_ADC="no"
DO_UPDATE="no"
USE_ARCHIVE="no"
COMPONENTS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)         PROJECT_ID="${2:-}";  shift 2 ;;
        -r|--region)          REGION="${2:-}";      shift 2 ;;
        -z|--zone)            ZONE="${2:-}";        shift 2 ;;
        -u|--update)          DO_UPDATE="yes";      shift   ;;
        --archive)            USE_ARCHIVE="yes";    shift   ;;
        --components)         COMPONENTS="${2:-}";  shift 2 ;;
        --login)              LOGIN_MODE="user";    shift   ;;
        --service-account)    LOGIN_MODE="sa"; SA_KEY_FILE="${2:-}"; shift 2 ;;
        --adc)                WRITE_ADC="yes";      shift   ;;
        -h|--help)            usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

COMPONENT_LIST=()
if [[ -n "$COMPONENTS" ]]; then
    IFS=',' read -ra COMPONENT_LIST <<< "$COMPONENTS"
fi

if gcloud --version &>/dev/null; then
    if [[ "$DO_UPDATE" == "yes" ]]; then
        update_gcloud
    else
        log "gcloud already installed: $(gcloud --version 2>/dev/null | head -1). Re-run with --update to upgrade."
    fi
else
    install_gcloud
fi

hash -r 2>/dev/null || true

if gcloud --version &>/dev/null; then
    log "gcloud ready: $(gcloud --version 2>/dev/null | head -1)"
else
    fail "gcloud installation failed. If PATH was just updated, open a new shell and re-run."
fi

do_login
configure_gcloud

if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    log "Authenticated as: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)"
    log "Active project:   $(gcloud config get-value project 2>/dev/null)"
else
    cat <<'EOF'

gcloud is installed but no active account. Pick one:
  - GCE instance:  nothing to do - the attached service account is used automatically
  - Laptop/SSH:    ./startup.sh --login
  - Automation:    ./startup.sh --service-account /path/to/key.json
  - Terraform/SDK: add --adc to also write Application Default Credentials
EOF
fi
