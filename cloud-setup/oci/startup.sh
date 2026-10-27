#!/bin/bash
#
# Install and configure the OCI CLI on a Linux workstation or OCI compute
# instance.
#
# Uses Oracle's install.sh wrapper, which installs the CLI into its own
# virtualenv (and a private Python if the system one is too old) rather than
# into system site-packages.
#
set -uo pipefail

OCI_INSTALL_URL="https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh"

usage() {
    cat <<'EOF'
Usage: ./startup.sh [options]

Install options:
  -u, --update            Reinstall/upgrade an existing OCI CLI install
      --dnf               Install from Oracle Linux's dnf repo instead of the
                          install script (Oracle Linux 8/9 only)
      --install-dir DIR   Install location (default: ~/lib/oracle-cli)
      --bin-dir DIR       Where to place the 'oci' executable (default: ~/bin)

Configuration options:
      --setup             Run 'oci setup config' interactively: generates an
                          API signing key pair and writes ~/.oci/config
      --instance-principal
                          Configure for instance principal auth (OCI compute).
                          No keys on disk; sets OCI_CLI_AUTH for future shells.
  -r, --region            Default region, e.g. us-ashburn-1
  -t, --tenancy           Tenancy OCID (used with --setup to prefill)
      --profile NAME      Profile name to check (default: DEFAULT)

  -h, --help              Display this help message and exit

Examples:
  ./startup.sh                                   # install only
  ./startup.sh --setup                           # install + generate API key + config
  ./startup.sh --instance-principal              # on an OCI compute instance
  ./startup.sh --update
  ./startup.sh --install-dir /opt/oci-cli --bin-dir /usr/local/bin

On an OCI compute instance, prefer --instance-principal - no key pair to
generate, upload, or rotate. It needs a dynamic group + policy allowing the
instance to call the services you use.
EOF
    exit 1
}

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

install_prereqs() {
    [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release; unsupported system."
    . /etc/os-release

    log "Installing prerequisites"
    case "$ID" in
        ubuntu|debian|linuxmint|pop)
            sudo apt-get update -qq
            sudo apt-get install -y curl ca-certificates python3 python3-venv python3-pip
            ;;
        ol|oracle|rhel|centos|almalinux|rocky|fedora)
            if command -v dnf &>/dev/null; then
                sudo dnf install -y curl python3 python3-pip
            else
                sudo yum install -y curl python3 python3-pip
            fi
            ;;
        sles|opensuse-leap|opensuse-tumbleweed)
            sudo zypper --non-interactive install curl python3 python3-pip
            ;;
        *)
            log "Unrecognised distribution '$ID' - skipping prereqs; the installer will fetch what it needs"
            ;;
    esac
}

install_dnf_repo() {
    . /etc/os-release
    [[ "$ID" == "ol" || "$ID" == "oracle" ]] \
        || fail "--dnf is for Oracle Linux only (detected '$ID'). Drop the flag to use the install script."

    log "Installing OCI CLI from the Oracle Linux repository"
    local major="${VERSION_ID%%.*}"
    sudo dnf install -y "oraclelinux-developer-release-el${major}" 2>/dev/null || true
    sudo dnf install -y python36-oci-cli 2>/dev/null \
        || sudo dnf install -y oci-cli \
        || fail "Could not install oci-cli from dnf. Drop --dnf to use the install script."
}

install_oci_cli() {
    if [[ "$USE_DNF" == "yes" ]]; then
        install_dnf_repo
        return
    fi

    install_prereqs

    local tmp
    tmp=$(mktemp -d)

    log "Downloading Oracle's OCI CLI installer"
    curl -fsSL "$OCI_INSTALL_URL" -o "$tmp/install.sh" \
        || { rm -rf "$tmp"; fail "Could not download the installer from $OCI_INSTALL_URL"; }

    # --accept-all-defaults keeps the install non-interactive; the dir flags
    # override the defaults it would otherwise accept silently.
    local args=(--accept-all-defaults
                --update-path-and-enable-tab-completion
                --rc-file-path "$HOME/.bashrc")
    [[ -n "$INSTALL_DIR" ]] && args+=(--install-dir "$INSTALL_DIR")
    [[ -n "$BIN_DIR" ]]     && args+=(--exec-dir "$BIN_DIR")

    log "Running installer (this pulls a private Python if the system one is too old)"
    bash "$tmp/install.sh" "${args[@]}" || { rm -rf "$tmp"; fail "OCI CLI installation failed."; }
    rm -rf "$tmp"

    # The installer edits .bashrc for future shells; this process needs PATH now.
    export PATH="${BIN_DIR:-$HOME/bin}:$PATH"
}

configure_instance_principal() {
    log "Configuring instance principal authentication"

    # Confirm we're actually on an OCI instance before writing anything.
    if ! curl -fsS -m 5 -H "Authorization: Bearer Oracle" \
            http://169.254.169.254/opc/v2/instance/ >/dev/null 2>&1; then
        fail "The OCI instance metadata service is not reachable.
--instance-principal only works on an OCI compute instance. On a workstation,
use --setup instead."
    fi

    export OCI_CLI_AUTH=instance_principal
    if ! grep -q 'OCI_CLI_AUTH=instance_principal' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export OCI_CLI_AUTH=instance_principal' >> "$HOME/.bashrc"
        log "Added OCI_CLI_AUTH=instance_principal to ~/.bashrc"
    fi

    if [[ -n "$REGION" ]]; then
        mkdir -p "$HOME/.oci"
        chmod 700 "$HOME/.oci"
        if [[ ! -f "$HOME/.oci/config" ]]; then
            printf '[DEFAULT]\nregion=%s\n' "$REGION" > "$HOME/.oci/config"
            chmod 600 "$HOME/.oci/config"
            log "Wrote region-only ~/.oci/config"
        fi
    fi
}

run_setup_config() {
    log "Running 'oci setup config'"
    cat <<EOF

You will be asked for:
  - config location    press Enter for ~/.oci/config
  - user OCID          Console: Profile -> My Profile -> OCID
  - tenancy OCID       Console: Profile -> Tenancy -> OCID
  - region             e.g. ${REGION:-us-ashburn-1}
  - generate key pair  answer Y

EOF
    [[ -n "$TENANCY_OCID" ]] && echo "Tenancy OCID to paste: $TENANCY_OCID"
    echo

    oci setup config || fail "'oci setup config' did not complete."

    # The CLI refuses to use a config or key that is group/world readable.
    chmod 700 "$HOME/.oci" 2>/dev/null
    chmod 600 "$HOME/.oci/config" 2>/dev/null
    chmod 600 "$HOME"/.oci/*.pem 2>/dev/null

    local pub
    pub=$(ls "$HOME"/.oci/*_public.pem 2>/dev/null | head -1)
    cat <<EOF

==> One step left: upload the public key to the Console.

   1. Console -> Profile -> My Profile -> Resources -> API keys -> Add API key
   2. Choose "Paste a public key"
   3. Paste the contents of: ${pub:-~/.oci/oci_api_key_public.pem}

EOF
    [[ -n "$pub" ]] && { echo "--- public key ---"; cat "$pub"; echo "--- end ---"; echo; }
}

configure_region() {
    [[ -n "$REGION" ]] || return 0
    [[ -f "$HOME/.oci/config" ]] || return 0

    if grep -q '^region' "$HOME/.oci/config"; then
        log "Region already set in ~/.oci/config - leaving it alone"
    else
        log "Appending region=$REGION to ~/.oci/config"
        printf 'region=%s\n' "$REGION" >> "$HOME/.oci/config"
    fi
}

REGION=""
TENANCY_OCID=""
PROFILE="DEFAULT"
INSTALL_DIR=""
BIN_DIR=""
DO_UPDATE="no"
USE_DNF="no"
DO_SETUP="no"
USE_INSTANCE_PRINCIPAL="no"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)          REGION="${2:-}";        shift 2 ;;
        -t|--tenancy)         TENANCY_OCID="${2:-}";  shift 2 ;;
        --profile)            PROFILE="${2:-}";       shift 2 ;;
        --install-dir)        INSTALL_DIR="${2:-}";   shift 2 ;;
        --bin-dir)            BIN_DIR="${2:-}";       shift 2 ;;
        -u|--update)          DO_UPDATE="yes";        shift   ;;
        --dnf)                USE_DNF="yes";          shift   ;;
        --setup)              DO_SETUP="yes";         shift   ;;
        --instance-principal) USE_INSTANCE_PRINCIPAL="yes"; shift ;;
        -h|--help)            usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ "$DO_SETUP" == "yes" && "$USE_INSTANCE_PRINCIPAL" == "yes" ]] \
    && fail "--setup and --instance-principal are mutually exclusive. Instance principals do not use an API key."

if command -v oci &>/dev/null; then
    if [[ "$DO_UPDATE" == "yes" ]]; then
        log "Reinstalling to upgrade"
        install_oci_cli
    else
        log "OCI CLI already installed: $(oci --version 2>/dev/null). Re-run with --update to upgrade."
    fi
else
    install_oci_cli
fi

hash -r 2>/dev/null || true

if command -v oci &>/dev/null; then
    log "OCI CLI ready: $(oci --version 2>/dev/null)"
else
    fail "OCI CLI not on PATH. Open a new shell (or 'exec -l \$SHELL') and re-run."
fi

[[ "$USE_INSTANCE_PRINCIPAL" == "yes" ]] && configure_instance_principal
[[ "$DO_SETUP" == "yes" ]] && run_setup_config
configure_region

AUTH_ARGS=()
[[ "$USE_INSTANCE_PRINCIPAL" == "yes" ]] && AUTH_ARGS=(--auth instance_principal)

if oci iam region list "${AUTH_ARGS[@]}" &>/dev/null; then
    log "Authenticated. Reachable regions:"
    oci iam region list "${AUTH_ARGS[@]}" --query 'data[*].name' --raw-output 2>/dev/null | head -5
else
    cat <<'EOF'

OCI CLI is installed but not authenticated yet. Pick one:
  - OCI compute:   ./startup.sh --instance-principal
                   (needs a dynamic group + policy for this instance)
  - Workstation:   ./startup.sh --setup
                   then upload ~/.oci/oci_api_key_public.pem in the Console
  - Already have a config from the Console? Save it as ~/.oci/config,
    point key_file at your private key, then:
       chmod 700 ~/.oci && chmod 600 ~/.oci/config ~/.oci/*.pem
EOF
fi
