#!/bin/bash
# Installs all prerequisite software for the Virtru DSP COP on Ubuntu 24.04 LTS

set -e

echo "=== Updating system packages ==="
sudo apt update -y && sudo apt upgrade -y

#echo "=== Installing packages for Virtualbox ==="
#sudo apt install -y \
#  open-vm-tools-desktop \
#  virtualbox-guest-additions-iso \
#  virtualbox-ext-pack

echo "=== Installing core dependencies ==="
sudo apt install -y \
  build-essential \
  curl \
  wget \
  git \
  make \
  ca-certificates \
  apt-transport-https \
  gnupg \
  lsb-release \
  software-properties-common \
  python3 \
  python3-pip

# ------------------------------------------------------------
# Docker (runtime + compose)
# ------------------------------------------------------------
echo "=== Installing Docker and Docker Compose ==="
if ! command -v docker &> /dev/null; then
  sudo apt remove -y docker docker-engine docker.io containerd runc || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------
echo "=== Checking Docker Compose ==="
if ! docker compose version &> /dev/null; then
  echo "Docker Compose plugin not found — installing..."
  sudo apt update -y
  sudo apt install -y docker-compose-plugin
else
  echo "Docker Compose already installed — $(docker compose version)"
fi


sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

# ------------------------------------------------------------
# Node.js (LTS) + npm + nvm
# ------------------------------------------------------------
echo "=== Installing Node.js (LTS) ==="
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt install -y nodejs
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
GO_VERSION="1.23.2"
if ! command -v go &> /dev/null; then
  wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  rm go${GO_VERSION}.linux-amd64.tar.gz
fi


# ------------------------------------------------------------
# mkcert (Local TLS Certificates)
# ------------------------------------------------------------
echo "=== Installing mkcert ==="
sudo apt install -y libnss3-tools
if ! command -v mkcert &> /dev/null; then
  wget https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
  sudo mv mkcert-v1.4.4-linux-amd64 /usr/local/bin/mkcert
  sudo chmod +x /usr/local/bin/mkcert
fi

# ------------------------------------------------------------
# cosign (policy import/export signing)
# ------------------------------------------------------------
echo "=== Installing cosign ==="
if ! command -v cosign &> /dev/null; then
  COSIGN_VERSION=$(curl -fsSL https://api.github.com/repos/sigstore/cosign/releases/latest | grep tag_name | cut -d'"' -f4)
  curl -fsSLo cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
  sudo mv cosign /usr/local/bin/cosign
  sudo chmod +x /usr/local/bin/cosign
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
# Detect architecture
# ------------------------------------------------------------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH_RAW"; exit 1 ;;
esac
echo "=== Detected architecture: linux/${ARCH} ==="

# ------------------------------------------------------------
# DSP Bundle — unpack binary and grpcurl
# ------------------------------------------------------------
echo "=== DSP Bundle Setup ==="
echo ""
echo "  The Virtru DSP bundle is a .tar.gz file (e.g. virtru-dsp-bundle-X.X.X.tar.gz)."
echo ""

BUNDLE_TAR=""
while true; do
  read -rp "  Enter path to the Virtru DSP bundle .tar.gz file: " BUNDLE_TAR
  BUNDLE_TAR="${BUNDLE_TAR/#\~/$HOME}"
  if [[ -z "$BUNDLE_TAR" ]]; then
    echo "  Path cannot be empty."
    continue
  fi
  if [[ ! -f "$BUNDLE_TAR" ]]; then
    echo "  File not found: $BUNDLE_TAR"
    continue
  fi
  break
done

echo "Unpacking bundle: $BUNDLE_TAR"
mkdir -p virtru-dsp-bundle
tar -xvf "$BUNDLE_TAR" -C virtru-dsp-bundle/
cd virtru-dsp-bundle/

# Unpack DSP binary for linux/${ARCH}
DSP_TAR=$(ls tools/dsp/data-security-platform_*_linux_${ARCH}.tar.gz 2>/dev/null | head -1)
if [[ -z "$DSP_TAR" ]]; then
  echo "ERROR: Could not find DSP binary for linux/${ARCH} in tools/dsp/"
  exit 1
fi
echo "Unpacking DSP binary: $DSP_TAR"
tar -xvf "$DSP_TAR"

# Unpack grpcurl for linux/${ARCH}
GRPCURL_TAR=$(ls tools/grpcurl/grpcurl_*_linux_${ARCH}.tar.gz 2>/dev/null | head -1)
if [[ -z "$GRPCURL_TAR" ]]; then
  echo "ERROR: Could not find grpcurl for linux/${ARCH} in tools/grpcurl/"
  exit 1
fi
echo "Unpacking grpcurl: $GRPCURL_TAR"
tar -xvf "$GRPCURL_TAR"

chmod +x ./grpcurl
echo "DSP bundle unpacked successfully."

cd ..

# ------------------------------------------------------------
# Post-install instructions
# ------------------------------------------------------------
echo "===================================="
echo "===================================="
echo "=== Prerequisite Setup Complete! ==="
echo ""
echo ""
echo "1. Reboot or log out/in for Docker group and ~/.bashrc changes to take effect."
echo "2. Continue to Step 1 in startupInstructions.md/README.md to start the COP services."
echo ""
echo "===================================="


