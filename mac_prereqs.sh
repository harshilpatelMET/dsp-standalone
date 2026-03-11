#!/bin/bash
# Installs all prerequisite software for the Virtru DSP on macOS
# Requires Homebrew (https://brew.sh)

set -e

# ------------------------------------------------------------
# Homebrew
# ------------------------------------------------------------
echo "=== Checking Homebrew ==="
if ! command -v brew &> /dev/null; then
  echo "Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon
  if [[ "$(uname -m)" == "arm64" ]]; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
else
  echo "Homebrew already installed — updating..."
  brew update
fi

# ------------------------------------------------------------
# Core dependencies
# ------------------------------------------------------------
echo "=== Installing core dependencies ==="
brew install \
  curl \
  wget \
  git \
  make \
  python3 \
  jq

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------
echo "=== Checking Docker ==="
if ! command -v docker &> /dev/null; then
  echo "Docker not found."
  echo "Install one of the following and re-run this script:"
  echo "  - OrbStack (recommended):     https://orbstack.dev"
  echo "  - Docker Desktop:             https://www.docker.com/products/docker-desktop"
  echo "  - Rancher Desktop:            https://rancherdesktop.io"
  echo "  - Colima (CLI):               brew install colima && colima start"
  exit 1
else
  echo "Docker already installed — $(docker --version)"
fi

# ------------------------------------------------------------
# Node.js (LTS) + nvm
# ------------------------------------------------------------
echo "=== Installing Node.js (LTS) ==="
if ! command -v node &> /dev/null; then
  brew install node
fi

echo "=== Installing nvm (Node Version Manager) ==="
if [ ! -d "$HOME/.nvm" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install --lts
fi

# ------------------------------------------------------------
# Go (Golang)
# ------------------------------------------------------------
echo "=== Installing Go (Golang) ==="
if ! command -v go &> /dev/null; then
  brew install go
fi

# ------------------------------------------------------------
# mkcert (Local TLS Certificates)
# ------------------------------------------------------------
echo "=== Installing mkcert ==="
if ! command -v mkcert &> /dev/null; then
  brew install mkcert
fi
mkcert -install

# ------------------------------------------------------------
# cosign (policy import/export signing)
# ------------------------------------------------------------
echo "=== Installing cosign ==="
if ! command -v cosign &> /dev/null; then
  brew install cosign
fi

# ------------------------------------------------------------
# Add local-dsp.virtru.com to /etc/hosts if not already present
# ------------------------------------------------------------
echo "=== Ensuring local-dsp.virtru.com is mapped in /etc/hosts ==="
if ! grep -q "local-dsp\.virtru\.com" /etc/hosts; then
  echo "127.0.0.1    local-dsp.virtru.com" | sudo tee -a /etc/hosts > /dev/null
  echo "Added entry: 127.0.0.1 local-dsp.virtru.com"
else
  echo "Entry already exists — skipping."
fi

# ------------------------------------------------------------
# Post-install instructions
# ------------------------------------------------------------
echo "===================================="
echo "===================================="
echo "=== Prerequisite Setup Complete! ==="
echo ""
echo "1. If nvm was just installed, open a new terminal tab or run:"
echo "   source ~/.zshrc  (or ~/.bash_profile)"
echo "2. Continue to the TLS certificate generation step in README.md."
echo "   Run setup_and_validate.sh to generate keys and start the stack."
echo ""
echo "===================================="
