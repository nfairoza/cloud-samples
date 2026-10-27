#!/bin/bash
#
# Install and configure the Azure CLI (az) on a Linux workstation or Azure VM.
#
# Installs from Microsoft's package repository rather than the one-liner script,
# so that upgrades arrive through the normal package manager. The repo packages
# bundle their own Python runtime, which also avoids fighting the system python.
#
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: ./startup.sh [options]

Install options:
  -u, --update          Upgrade an existing Azure CLI install
      --script          Install via Microsoft's one-liner script instead of the
                        package repo (for ephemeral containers / CI images)

Configuration options (all optional):
  -s,  --subscription   Subscription ID or name to set as default
  -t,  --tenant         Tenant ID to authenticate against
  -g,  --resource-group Default resource group (az configure defaults)
  -l,  --location       Default location, e.g. eastus
  -o,  --output         Output format: json (default), jsonc, table, tsv, yaml

Authentication (choose at most one; omit to skip login):
      --login           Interactive device-code login (works over SSH)
      --identity        Log in with the VM's managed identity (Azure VMs)
      --identity-client-id ID
                        Use a specific user-assigned managed identity
      --service-principal APP_ID
                        Log in as a service principal (needs --tenant and
                        either --sp-secret or --sp-cert)
      --sp-secret SECRET      Service principal client secret
      --sp-cert PATH          Service principal certificate (.pem)

  -h,  --help           Display this help message and exit

Examples:
  ./startup.sh                                  # install only
  ./startup.sh --login -l eastus                # install, log in, set location
  ./startup.sh --identity                       # on an Azure VM with managed identity
  ./startup.sh --update
  ./startup.sh --service-principal $APP_ID --tenant $TENANT --sp-secret "$SECRET"

On an Azure VM, prefer --identity over a service principal - no secret on disk
and the token rotates automatically.
EOF
    exit 1
}

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

install_apt() {
    log "Installing Azure CLI from the Microsoft apt repository"
    sudo apt-get update -qq
    sudo apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https

    # Microsoft signing key -> /etc/apt/keyrings (deb822 'Signed-By' target).
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg
    sudo chmod go+r /etc/apt/keyrings/microsoft.gpg

    # lsb_release returns codenames Microsoft does not publish for (Mint, some
    # derivatives, brand-new Ubuntu releases). Fall back to a known-good LTS.
    local dist
    dist=$(lsb_release -cs 2>/dev/null)
    case "$dist" in
        jammy|noble|focal|bullseye|bookworm|trixie) ;;
        *)
            . /etc/os-release
            if [[ "$ID" == "debian" ]]; then dist="bookworm"; else dist="jammy"; fi
            log "Codename '$(lsb_release -cs 2>/dev/null)' not published by Microsoft; using '$dist'"
            ;;
    esac

    sudo tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${dist}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF

    sudo apt-get update -qq
    sudo apt-get install -y azure-cli
}

install_dnf() {
    log "Installing Azure CLI from the Microsoft dnf/yum repository"
    . /etc/os-release

    local major="${VERSION_ID%%.*}"
    case "$major" in
        8|9|10) ;;
        *) major="9"; log "Mapping $PRETTY_NAME to the RHEL 9 repository" ;;
    esac

    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc

    if command -v dnf &>/dev/null; then
        sudo dnf install -y "https://packages.microsoft.com/config/rhel/${major}/packages-microsoft-prod.rpm"
        sudo dnf install -y azure-cli
    else
        sudo yum install -y "https://packages.microsoft.com/config/rhel/${major}/packages-microsoft-prod.rpm"
        sudo yum install -y azure-cli
    fi
}

install_zypper() {
    log "Installing Azure CLI from the Microsoft zypper repository"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo zypper --non-interactive addrepo --name 'Azure CLI' --check \
        https://packages.microsoft.com/yumrepos/azure-cli azure-cli 2>/dev/null || true
    sudo zypper --non-interactive --gpg-auto-import-keys refresh
    sudo zypper --non-interactive install --from azure-cli azure-cli
}

install_script() {
    log "Installing Azure CLI via Microsoft's install script"
    curl -fsSL https://aka.ms/InstallAzureCLIDeb | sudo bash
}

install_az() {
    if [[ "$USE_SCRIPT" == "yes" ]]; then
        install_script
        return
    fi

    [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release; unsupported system."
    . /etc/os-release

    case "$ID" in
        ubuntu|debian|linuxmint|pop)                 install_apt    ;;
        rhel|centos|almalinux|rocky|fedora|mariner|azurelinux) install_dnf ;;
        sles|opensuse-leap|opensuse-tumbleweed)      install_zypper ;;
        *)
            fail "Unsupported distribution: $ID.
Try --script, or see https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
            ;;
    esac
}

update_az() {
    # az upgrade (2.11.0+) updates the CLI and its extensions through whichever
    # channel it was installed from.
    log "Upgrading Azure CLI"
    az upgrade --yes 2>/dev/null || {
        log "az upgrade unavailable; falling back to the package manager"
        install_az
    }
}

do_login() {
    case "$LOGIN_MODE" in
        none) return 0 ;;

        device)
            log "Starting device-code login"
            if [[ -n "$TENANT_ID" ]]; then
                az login --use-device-code --tenant "$TENANT_ID" || fail "Login failed."
            else
                az login --use-device-code || fail "Login failed."
            fi
            ;;

        identity)
            log "Logging in with managed identity"
            if [[ -n "$IDENTITY_CLIENT_ID" ]]; then
                az login --identity --client-id "$IDENTITY_CLIENT_ID" \
                    || fail "Managed identity login failed. Is the identity assigned to this VM?"
            else
                az login --identity \
                    || fail "Managed identity login failed. Is a system-assigned identity enabled on this VM?"
            fi
            ;;

        sp)
            [[ -n "$TENANT_ID" ]] || fail "--service-principal requires --tenant."
            log "Logging in as service principal $SP_APP_ID"
            if [[ -n "$SP_CERT" ]]; then
                az login --service-principal -u "$SP_APP_ID" \
                    --certificate "$SP_CERT" --tenant "$TENANT_ID" || fail "Login failed."
            elif [[ -n "$SP_SECRET" ]]; then
                az login --service-principal -u "$SP_APP_ID" \
                    -p "$SP_SECRET" --tenant "$TENANT_ID" || fail "Login failed."
            else
                fail "--service-principal requires either --sp-secret or --sp-cert."
            fi
            ;;
    esac
}

configure_az() {
    if [[ -n "$SUBSCRIPTION" ]]; then
        log "Setting default subscription: $SUBSCRIPTION"
        az account set --subscription "$SUBSCRIPTION" \
            || fail "Could not select subscription '$SUBSCRIPTION'. Run 'az account list -o table'."
    fi

    local defaults=()
    [[ -n "$RESOURCE_GROUP" ]] && defaults+=("group=$RESOURCE_GROUP")
    [[ -n "$LOCATION" ]]       && defaults+=("location=$LOCATION")
    if (( ${#defaults[@]} )); then
        log "Setting CLI defaults: ${defaults[*]}"
        az configure --defaults "${defaults[@]}"
    fi

    if [[ -n "$OUTPUT_FMT" ]]; then
        az config set core.output="$OUTPUT_FMT" 2>/dev/null \
            || az configure --defaults "output=$OUTPUT_FMT"
    fi
}

SUBSCRIPTION=""
TENANT_ID=""
RESOURCE_GROUP=""
LOCATION=""
OUTPUT_FMT=""
LOGIN_MODE="none"
IDENTITY_CLIENT_ID=""
SP_APP_ID=""
SP_SECRET=""
SP_CERT=""
DO_UPDATE="no"
USE_SCRIPT="no"

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--subscription)   SUBSCRIPTION="${2:-}";   shift 2 ;;
        -t|--tenant)         TENANT_ID="${2:-}";      shift 2 ;;
        -g|--resource-group) RESOURCE_GROUP="${2:-}"; shift 2 ;;
        -l|--location)       LOCATION="${2:-}";       shift 2 ;;
        -o|--output)         OUTPUT_FMT="${2:-}";     shift 2 ;;
        -u|--update)         DO_UPDATE="yes";         shift   ;;
        --script)            USE_SCRIPT="yes";        shift   ;;
        --login)             LOGIN_MODE="device";     shift   ;;
        --identity)          LOGIN_MODE="identity";   shift   ;;
        --identity-client-id)
            LOGIN_MODE="identity"; IDENTITY_CLIENT_ID="${2:-}"; shift 2 ;;
        --service-principal)
            LOGIN_MODE="sp";       SP_APP_ID="${2:-}";          shift 2 ;;
        --sp-secret)         SP_SECRET="${2:-}";      shift 2 ;;
        --sp-cert)           SP_CERT="${2:-}";        shift 2 ;;
        -h|--help)           usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if az version &>/dev/null; then
    if [[ "$DO_UPDATE" == "yes" ]]; then
        update_az
    else
        log "Azure CLI already installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null). Re-run with --update to upgrade."
    fi
else
    install_az
fi

hash -r 2>/dev/null || true

if az version &>/dev/null; then
    log "Azure CLI ready: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
else
    fail "Azure CLI installation failed."
fi

do_login
configure_az

if az account show &>/dev/null; then
    log "Authenticated. Active subscription:"
    az account show --query '{name:name, id:id, tenant:tenantId, user:user.name}' -o table
else
    cat <<'EOF'

Azure CLI is installed but not authenticated. Pick one:
  - Laptop / SSH:   ./startup.sh --login        (device code)
  - Azure VM:       ./startup.sh --identity     (managed identity)
  - Automation:     ./startup.sh --service-principal <APP_ID> --tenant <TENANT> --sp-secret <SECRET>
EOF
fi
