#!/usr/bin/env bash
set -euo pipefail

# Create a local user, home directory and SSH credentials.
# Prompts for username, generates a random password and (if available) an SSH keypair.

# Sudo wrapper if not root
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

read -r -p "Enter new username: " USERNAME
USERNAME="${USERNAME## }"
if [ -z "$USERNAME" ]; then
  echo "No username provided. Aborting." >&2
  exit 1
fi

# Check if user exists
if id "$USERNAME" >/dev/null 2>&1; then
  read -r -p "User '$USERNAME' already exists. Update credentials / ensure keys? [y/N] " yn
  case "${yn:-n}" in
    [Yy]|[Yy][Ee][Ss]) RECREATE_KEYS=1 ;;
    *) echo "Aborting."; exit 0 ;;
  esac
else
  RECREATE_KEYS=1
  # Create user depending on available tools
  if [ -f /etc/alpine-release ] || command -v adduser >/dev/null 2>&1 && ! command -v useradd >/dev/null 2>&1; then
    # Alpine-style adduser
    $SUDO adduser -D -h "/home/$USERNAME" -s /bin/sh "$USERNAME"
  else
    # useradd (Debian/Ubuntu)
    $SUDO useradd -m -s /bin/bash "$USERNAME"
  fi
fi

if [ "$RECREATE_KEYS" -ne 1 ] 2>/dev/null; then :; fi

# Ensure home exists and ownership is correct
HOME_DIR="/home/$USERNAME"
$SUDO mkdir -p "$HOME_DIR"
$SUDO chown "$USERNAME":"$USERNAME" "$HOME_DIR"

# Ensure ssh-keygen is available; install on Alpine or Debian/Ubuntu if missing
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "ssh-keygen not found; attempting to install..."
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID=""
  fi

  case "$OS_ID" in
    alpine)
      echo "Installing openssh on Alpine..."
      $SUDO apk update
      $SUDO apk add --no-cache openssh
      ;;
    ubuntu|debian)
      echo "Installing openssh-client on Debian/Ubuntu..."
      $SUDO apt-get update
      DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y openssh-client
      ;;
    centos|rhel|fedora|amzn)
      echo "Installing openssh-clients on RHEL/CentOS/Fedora..."
      $SUDO yum install -y openssh-clients || $SUDO dnf install -y openssh-clients
      ;;
    *)
      echo "Automatic installation of ssh-keygen not supported on OS: ${OS_ID:-unknown}. Please install ssh-keygen (openssh) manually." >&2
      ;;
  esac

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ssh-keygen still not available after attempt to install." >&2
  else
    echo "ssh-keygen installed."
  fi
fi

# Generate random password
if command -v openssl >/dev/null 2>&1; then
  PASSWORD="$(openssl rand -base64 18)"
else
  PASSWORD="$(tr -dc 'A-Za-z0-9@%+=:,.-_' < /dev/urandom | head -c 18 || true)"
fi
PASSWORD="${PASSWORD:-$(date +%s | sha256sum | head -c 18)}"

# Set the user's password
echo "${USERNAME}:${PASSWORD}" | $SUDO chpasswd

# Prepare .ssh
SSH_DIR="$HOME_DIR/.ssh"
$SUDO mkdir -p "$SSH_DIR"
$SUDO chown "$USERNAME":"$USERNAME" "$SSH_DIR"
$SUDO chmod 700 "$SSH_DIR"

PRIVATE_KEY_PATH="$SSH_DIR/id_ed25519"

# Generate SSH keypair as the new user if ssh-keygen available
if command -v ssh-keygen >/dev/null 2>&1; then
  if [ -f "$PRIVATE_KEY_PATH" ]; then
    echo "SSH key pair already exists. Skipping generation."
  else
    # generate keypair (ed25519 preferred)
    if $SUDO -u "$USERNAME" ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -q 2>/dev/null; then
      :
    else
      # fallback to rsa
      $SUDO -u "$USERNAME" ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY_PATH" -N "" -q || true
    fi
  fi

  # Install public key to authorized_keys if not present
  if [ -f "${PRIVATE_KEY_PATH}.pub" ]; then
    if [ ! -f "$SSH_DIR/authorized_keys" ]; then
      $SUDO cp "${PRIVATE_KEY_PATH}.pub" "$SSH_DIR/authorized_keys"
      $SUDO chown "$USERNAME":"$USERNAME" "$SSH_DIR/authorized_keys"
      $SUDO chmod 600 "$SSH_DIR/authorized_keys"
    fi
    HAS_KEY=1
  else
    HAS_KEY=0
  fi
else
  HAS_KEY=0
fi

# Final ownership and perms
$SUDO chown -R "$USERNAME":"$USERNAME" "$HOME_DIR"
$SUDO chmod 700 "$SSH_DIR" || true

# Output credentials
echo ""
echo "User created/updated: $USERNAME"
echo "Generated password: $PASSWORD"
if [ "$HAS_KEY" -eq 1 ]; then
  echo "Private key path: $PRIVATE_KEY_PATH"
  echo ""
  echo "----- BEGIN PRIVATE KEY (copy/save this securely) -----"
  $SUDO cat "$PRIVATE_KEY_PATH"
  echo "----- END PRIVATE KEY -----"
  echo ""
  echo "Public key installed in $SSH_DIR/authorized_keys"
else
  if command -v ssh-keygen >/dev/null 2>&1; then
    echo "SSH keypair was not generated (generation failed or public key missing)."
  else
    echo "SSH keypair was not generated (ssh-keygen not available)."
  fi
  echo "You can add an authorized key manually to $SSH_DIR/authorized_keys"
fi

echo ""
echo "Notes:"
echo " - Home directory: $HOME_DIR"
echo " - The user can authenticate via password (SSH) unless SSH password auth is disabled on the server."
echo " - Protect the printed private key; remove it from the terminal history or save it to a secure location."
exit 0
