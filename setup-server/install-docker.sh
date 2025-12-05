#!/usr/bin/env bash
set -euo pipefail

# Docker + Docker Compose installation script compatible with Ubuntu/Debian and Alpine
# Asks at startup whether to add the current user to the 'docker' group and then installs/starts services.

# Determine the target user to add to the docker group:
# - If the script was invoked via sudo, prefer SUDO_USER (the real non-root user).
# - Otherwise use the result of whoami.
INVOKED_USER="$(whoami)"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  USER_NAME="${SUDO_USER}"
else
  USER_NAME="${INVOKED_USER}"
fi

ADD_USER_NO_PROMPT=""
read -r -p "Add user '$USER_NAME' to the 'docker' group? [y/N] " add_user_answer
case "${add_user_answer:-n}" in
  [Yy]|[Yy][Ee][Ss]) ADD_USER_NO_PROMPT=1 ;;
  *) ADD_USER_NO_PROMPT=0 ;;
esac

# Sudo wrapper if not root
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"
else
  echo "Unable to detect operating system." >&2
  exit 1
fi

case "$OS_ID" in
  ubuntu|debian)
    echo "Detected: $OS_ID — proceeding with installation for Debian/Ubuntu..."
    $SUDO apt-get update
    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
    curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # Enable and start
    $SUDO systemctl enable --now docker || true
    ;;
  alpine)
    echo "Detected: alpine — proceeding with installation for Alpine..."
    $SUDO apk update
    # docker-compose-openrc provides docker-compose on many Alpine builds; alternatively use pip/pip3 if not available
    $SUDO apk add --no-cache docker docker-compose-openrc
    # Enable and start with openrc
    if command -v rc-update >/dev/null 2>&1; then
      $SUDO rc-update add docker boot || true
    fi
    $SUDO service docker start || true
    ;;
  *)
    echo "OS not supported by this script: $OS_ID" >&2
    exit 2
    ;;
esac

# Add user to docker group if requested
if [ "$ADD_USER_NO_PROMPT" -eq 1 ]; then
  echo "Adding user '$USER_NAME' to 'docker' group..."
  # Create the group if necessary (groupadd -f on many distros)
  if ! getent group docker >/dev/null 2>&1; then
    $SUDO groupadd docker || true
  fi
  $SUDO usermod -aG docker "$USER_NAME" || {
    # usermod may not exist in some minimal images; fallback to addgroup (Alpine)
    if command -v addgroup >/dev/null 2>&1; then
      $SUDO addgroup "$USER_NAME" docker || true
    else
      echo "Unable to add user to the docker group automatically." >&2
    fi
  }
  echo "User added to 'docker' group. Log out and log back in for the changes to take effect."
else
  echo "User not added to the 'docker' group. To add later: sudo usermod -aG docker $USER_NAME"
fi

# Quick checks
echo ""
echo "Checks:"
$SUDO docker --version || echo "docker not found or not running"
docker compose version 2>/dev/null || echo "docker compose (plugin) not available or not installed"

echo "Installation completed."
