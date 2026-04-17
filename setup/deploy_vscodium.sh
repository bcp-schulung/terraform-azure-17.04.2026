#!/usr/bin/env bash
set -euo pipefail

# Simple multi-VM deployment for Ubuntu hosts.
# Installs code-server (browser IDE), creates a dedicated user,
# and configures password auth per VM.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SSH_USER="root"
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
VMS_FILE="${SCRIPT_DIR}/vms.txt"
PASSWORDS_FILE="${SCRIPT_DIR}/vm_passwords.csv"
IDE_USER="devuser"
IDE_PORT="8080"
REPO_URL="git@github.com:bcp-schulung/terraform-azure-17.04.2026.git"
REPO_AUTH_MODE="public"
TF_VERSION="latest"
DRY_RUN="false"
PARALLEL="false"
PARALLEL_JOBS="3"
VERIFY="false"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --dry-run                 Print what would be done, without making changes
  --parallel                Deploy to multiple VMs in parallel
  --jobs N                  Number of parallel jobs (default: 3, used with --parallel)
  --verify                  Verify service health after deployment
  --repo-url URL            Git repository to clone into the devuser home directory
  --repo-auth MODE          Clone mode: public, ssh, or https (default: public)
  --terraform-version VER   Terraform version to install, or 'latest' (default: latest)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --parallel)
      PARALLEL="true"
      shift
      ;;
    --verify)
      VERIFY="true"
      shift
      ;;
    --jobs)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] --jobs requires a number"
        exit 1
      fi
      PARALLEL_JOBS="$2"
      shift 2
      ;;
    --repo-url)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] --repo-url requires a value"
        exit 1
      fi
      REPO_URL="$2"
      shift 2
      ;;
    --repo-auth)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] --repo-auth requires a value"
        exit 1
      fi
      REPO_AUTH_MODE="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    --terraform-version)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] --terraform-version requires a value"
        exit 1
      fi
      TF_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_JOBS" -lt 1 ]]; then
  echo "[ERROR] --jobs must be a positive integer"
  exit 1
fi

if [[ ! "$REPO_AUTH_MODE" =~ ^(public|ssh|https)$ ]]; then
  echo "[ERROR] --repo-auth must be one of: public, ssh, https"
  exit 1
fi

if [[ ! -f "$VMS_FILE" ]]; then
  echo "[ERROR] Missing $VMS_FILE"
  exit 1
fi

if [[ ! -f "$PASSWORDS_FILE" ]]; then
  echo "[ERROR] Missing $PASSWORDS_FILE"
  echo "Create it as: ip,password"
  exit 1
fi

# Auto-correct if a public key path was provided by mistake.
if [[ "$SSH_KEY_PATH" == *.pub ]]; then
  maybe_private="${SSH_KEY_PATH%.pub}"
  if [[ -f "$maybe_private" ]]; then
    SSH_KEY_PATH="$maybe_private"
  fi
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "[ERROR] SSH private key not found: $SSH_KEY_PATH"
  exit 1
fi

get_password_for_ip() {
  local ip="$1"
  awk -F',' -v vm_ip="$ip" '
    BEGIN { found=0 }
    /^[[:space:]]*#/ { next }
    NF >= 2 {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if ($1 == vm_ip) {
        print $2
        found=1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$PASSWORDS_FILE"
}

deploy_one_vm() {
  local ip="$1"
  local vm_password="$2"
  local repo_name=""

  if [[ -n "$REPO_URL" ]]; then
    repo_name="$(basename "${REPO_URL%.git}")"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $ip"
    echo "  - SSH as $SSH_USER using key $SSH_KEY_PATH"
    echo "  - Create/update user: $IDE_USER"
    echo "  - Install code-server if missing"
    echo "  - Install Terraform ($TF_VERSION)"
    echo "  - Install Azure CLI"
    if [[ -n "$repo_name" ]]; then
      echo "  - Clone/update repo into /home/$IDE_USER/$repo_name"
    fi
    echo "  - Configure password auth on port $IDE_PORT"
    echo "  - Enable service: code-server@$IDE_USER"
    echo "  - Open firewall ports: $IDE_PORT/tcp (if ufw exists)"
    return 0
  fi

  echo "[INFO] Deploying on $ip ..."

  if ! ssh -i "$SSH_KEY_PATH" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$ip" \
    "IDE_USER='$IDE_USER' IDE_PORT='$IDE_PORT' IDE_PASS='$vm_password' TF_VERSION='$TF_VERSION' REPO_URL='$REPO_URL' REPO_AUTH_MODE='$REPO_AUTH_MODE' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "[ERROR] This script currently supports Ubuntu/Debian (apt-get)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl sudo git ca-certificates gnupg lsb-release unzip
install -d -m 0755 /etc/apt/keyrings

install_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    return 0
  fi

  local arch
  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *)
      echo "[ERROR] Unsupported architecture for Terraform."
      exit 1
      ;;
  esac

  if [[ "${TF_VERSION:-latest}" == "latest" ]]; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -y
    apt-get install -y terraform
  else
    local tmp_dir zip_path
    tmp_dir="$(mktemp -d)"
    zip_path="$tmp_dir/terraform.zip"
    curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${arch}.zip" -o "$zip_path"
    unzip -oq "$zip_path" -d /usr/local/bin
    chmod 755 /usr/local/bin/terraform
    rm -rf "$tmp_dir"
  fi
}

install_azure_cli() {
  if command -v az >/dev/null 2>&1; then
    return 0
  fi

  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  chmod go+r /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/azure-cli.list
  apt-get update -y
  apt-get install -y azure-cli
}

normalize_repo_url() {
  local url="$1"
  local mode="${2:-public}"

  case "$mode" in
    public|https)
      if [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
        printf 'https://github.com/%s\n' "${BASH_REMATCH[1]}"
      else
        printf '%s\n' "$url"
      fi
      ;;
    ssh)
      printf '%s\n' "$url"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

clone_repo_for_user() {
  if [[ -z "${REPO_URL:-}" ]]; then
    return 0
  fi

  local clone_url repo_name repo_dir
  clone_url="$(normalize_repo_url "$REPO_URL" "${REPO_AUTH_MODE:-public}")"
  repo_name="$(basename "$clone_url")"
  repo_name="${repo_name%.git}"
  repo_dir="/home/$IDE_USER/$repo_name"

  if [[ -d "$repo_dir/.git" ]]; then
    sudo -u "$IDE_USER" -H git -C "$repo_dir" pull --ff-only
  else
    rm -rf "$repo_dir"
    sudo -u "$IDE_USER" -H git clone "$clone_url" "$repo_dir"
  fi

  chown -R "$IDE_USER:$IDE_USER" "$repo_dir"
}

install_terraform
install_azure_cli

# ── code-server ──────────────────────────────────────────────────────────────
if ! command -v code-server >/dev/null 2>&1; then
  curl -fsSL https://code-server.dev/install.sh | sh
fi

# ── IDE user ─────────────────────────────────────────────────────────────────
if ! id -u "$IDE_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$IDE_USER"
fi

usermod -aG sudo "$IDE_USER"
echo "$IDE_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$IDE_USER"
chmod 440 "/etc/sudoers.d/$IDE_USER"

echo "$IDE_USER:$IDE_PASS" | chpasswd

clone_repo_for_user

# ── code-server config ───────────────────────────────────────────────────────
install -d -m 700 -o "$IDE_USER" -g "$IDE_USER" "/home/$IDE_USER/.config/code-server"
cat > "/home/$IDE_USER/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:$IDE_PORT
auth: password
password: $IDE_PASS
cert: false
EOF
chown "$IDE_USER:$IDE_USER" "/home/$IDE_USER/.config/code-server/config.yaml"

systemctl daemon-reload
systemctl enable --now "code-server@$IDE_USER"

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$IDE_PORT/tcp" || true
fi

echo "[OK] code-server, Terraform, Azure CLI, and project setup complete"
echo "[OK] Ready on http://$(hostname -I | awk '{print $1}'):$IDE_PORT"
REMOTE_SCRIPT
  then
    echo "[ERROR] Remote setup failed on $ip"
    return 1
  fi

  if [[ -n "$repo_name" ]]; then
    echo "[DONE] $ip -> http://$ip:$IDE_PORT (user: $IDE_USER, repo: $repo_name)"
  else
    echo "[DONE] $ip -> http://$ip:$IDE_PORT (user: $IDE_USER)"
  fi
}

process_ip() {
  local ip="$1"
  local vm_password=""

  if ! vm_password="$(get_password_for_ip "$ip")"; then
    echo "[WARN] No password found for $ip in $PASSWORDS_FILE. Skipping."
    return 0
  fi

  if [[ -z "$vm_password" ]]; then
    echo "[WARN] Empty password for $ip. Skipping."
    return 0
  fi

  if ! deploy_one_vm "$ip" "$vm_password"; then
    echo "[ERROR] Deployment failed on $ip"
    return 1
  fi
}

verify_one_vm() {
  local ip="$1"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] verify $ip"
    echo "  - Check service: code-server@$IDE_USER is active"
    echo "  - Check local HTTP on 127.0.0.1:$IDE_PORT"
    return 0
  fi

  if ssh -i "$SSH_KEY_PATH" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$ip" \
    "systemctl is-active --quiet 'code-server@$IDE_USER' && curl -fsS --max-time 5 'http://127.0.0.1:$IDE_PORT' >/dev/null"; then
    echo "[VERIFY-OK] $ip"
    return 0
  fi

  echo "[VERIFY-ERROR] $ip"
  return 1
}

FAILURES_FILE="$(mktemp)"
VERIFY_FAILURES_FILE="$(mktemp)"
cleanup() {
  rm -f "$FAILURES_FILE"
  rm -f "$VERIFY_FAILURES_FILE"
}
trap cleanup EXIT

while IFS= read -r raw_ip || [[ -n "$raw_ip" ]]; do
  ip="$(echo "$raw_ip" | tr -d '[:space:]')"
  [[ -z "$ip" ]] && continue

  if [[ "$PARALLEL" == "true" ]]; then
    (
      if ! process_ip "$ip"; then
        echo "$ip" >> "$FAILURES_FILE"
      fi
    ) &

    while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL_JOBS" ]]; do
      sleep 0.2
    done
  else
    if ! process_ip "$ip"; then
      echo "$ip" >> "$FAILURES_FILE"
    fi
  fi
done < "$VMS_FILE"

if [[ "$PARALLEL" == "true" ]]; then
  wait
fi

overall_exit=0

if [[ -s "$FAILURES_FILE" ]]; then
  echo "[WARN] Some VMs failed:"
  sort -u "$FAILURES_FILE" | sed 's/^/  - /'
  overall_exit=1
fi

if [[ "$VERIFY" == "true" ]]; then
  echo "[INFO] Starting verification phase ..."

  while IFS= read -r raw_ip || [[ -n "$raw_ip" ]]; do
    ip="$(echo "$raw_ip" | tr -d '[:space:]')"
    [[ -z "$ip" ]] && continue

    if [[ "$PARALLEL" == "true" ]]; then
      (
        if ! verify_one_vm "$ip"; then
          echo "$ip" >> "$VERIFY_FAILURES_FILE"
        fi
      ) &

      while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL_JOBS" ]]; do
        sleep 0.2
      done
    else
      if ! verify_one_vm "$ip"; then
        echo "$ip" >> "$VERIFY_FAILURES_FILE"
      fi
    fi
  done < "$VMS_FILE"

  if [[ "$PARALLEL" == "true" ]]; then
    wait
  fi

  if [[ -s "$VERIFY_FAILURES_FILE" ]]; then
    echo "[WARN] Verification failed on:"
    sort -u "$VERIFY_FAILURES_FILE" | sed 's/^/  - /'
    overall_exit=1
  else
    echo "[INFO] Verification passed on all VMs."
  fi
fi

if [[ "$overall_exit" -ne 0 ]]; then
  echo "[INFO] Deployment run finished with errors."
  exit 1
fi

echo "[INFO] Deployment run finished."