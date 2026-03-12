#!/usr/bin/env bash
# =============================================================================
# setup_and_validate.sh
#
# Runs all prerequisites, starts the DSP-only Docker Compose stack, and
# executes the full validation suite from the README.
#
# Supports: macOS (Intel + Apple Silicon), Ubuntu/Debian Linux (amd64 + arm64)
#
# Usage:
#   ./setup_and_validate.sh                  # full run
#   ./setup_and_validate.sh --skip-prereqs   # skip tool installs, go straight to keys/stack
#   ./setup_and_validate.sh --validate-only  # validate a running stack (no setup)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
SKIP_PREREQS=false
VALIDATE_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --skip-prereqs)  SKIP_PREREQS=true ;;
    --validate-only) VALIDATE_ONLY=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log_section() { echo; echo -e "${BOLD}${BLUE}==> $*${NC}"; }
log_info()    { echo -e "    ${BLUE}·${NC} $*"; }
log_ok()      { echo -e "    ${GREEN}✓${NC} $*"; }
log_warn()    { echo -e "    ${YELLOW}⚠${NC}  $*"; }
log_fail()    { echo -e "    ${RED}✗${NC} $*"; }
die()         { echo -e "\n${RED}FATAL:${NC} $*\n" >&2; exit 1; }

PASS=0; FAIL=0
check_pass() { log_ok "$1"; ((PASS++)) || true; }
check_fail() { log_fail "$1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# OS / architecture detection
# ---------------------------------------------------------------------------
log_section "Detecting environment"

OS_RAW=$(uname -s)
ARCH_RAW=$(uname -m)

case "$OS_RAW" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux"  ;;
  *)      die "Unsupported OS: $OS_RAW" ;;
esac

case "$ARCH_RAW" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)             die "Unsupported architecture: $ARCH_RAW" ;;
esac

log_ok "OS: $OS_RAW  |  Arch: $ARCH_RAW  →  ${OS}/${ARCH}"

# Script must run from DSP-standalone/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
log_ok "Working directory: $SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Helper: validate required tools are present after prereqs run
# ---------------------------------------------------------------------------
REQUIRED_TOOLS=(docker jq mkcert cosign openssl curl)

validate_tools() {
  local missing=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
      log_ok "$tool → $(command -v "$tool")"
    else
      log_fail "$tool not found"
      missing+=("$tool")
    fi
  done

  # Docker daemon check (separate from binary presence)
  if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
      log_ok "Docker daemon is running"
    else
      log_warn "Docker binary found but daemon is not running."
      if [[ "$OS" == "darwin" ]]; then
        log_warn "Start OrbStack or Docker Desktop, then re-run."
      else
        log_warn "Try: sudo systemctl start docker  or  newgrp docker"
      fi
      missing+=("docker-daemon")
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    log_fail "Missing tools: ${missing[*]}"
    die "Fix the above then re-run with --skip-prereqs to skip tool installation."
  fi
}

# ---------------------------------------------------------------------------
# Prerequisites — delegate to OS-specific script
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" == false ]]; then

  if [[ "$SKIP_PREREQS" == false ]]; then

    log_section "Running prerequisites script"

    case "$OS" in
      darwin) PREREQS_SCRIPT="$SCRIPT_DIR/mac_prereqs.sh" ;;
      linux)  PREREQS_SCRIPT="$SCRIPT_DIR/ubuntu_prereqs.sh" ;;
    esac

    if [[ ! -f "$PREREQS_SCRIPT" ]]; then
      die "Prerequisites script not found: $PREREQS_SCRIPT\nExpected it alongside setup_and_validate.sh."
    fi

    if [[ ! -x "$PREREQS_SCRIPT" ]]; then
      log_info "Making $PREREQS_SCRIPT executable..."
      chmod +x "$PREREQS_SCRIPT"
    fi

    log_info "Executing: $PREREQS_SCRIPT"
    echo

    PREREQS_EXIT=0
    bash "$PREREQS_SCRIPT" || PREREQS_EXIT=$?

    echo
    if [[ $PREREQS_EXIT -ne 0 ]]; then
      die "Prerequisites script exited with code $PREREQS_EXIT.\nReview the output above and fix any errors before continuing."
    fi
    log_ok "Prerequisites script completed successfully (exit 0)"

    log_section "Validating installed tools"
    validate_tools

  else

    log_section "Skipping prerequisites (--skip-prereqs)"
    log_info "Checking that required tools are already available..."
    validate_tools

  fi

  # --- /etc/hosts -----------------------------------------------------------
  log_section "/etc/hosts"

  if grep -q "local-dsp\.virtru\.com" /etc/hosts; then
    log_ok "local-dsp.virtru.com already in /etc/hosts"
  else
    log_info "Adding 127.0.0.1 local-dsp.virtru.com to /etc/hosts (requires sudo)..."
    echo "127.0.0.1    local-dsp.virtru.com" | sudo tee -a /etc/hosts > /dev/null
    log_ok "Entry added"
  fi

  # --- mkcert trust store ---------------------------------------------------
  log_section "TLS trust store (mkcert)"

  mkcert -install 2>/dev/null || log_warn "mkcert -install failed (may need sudo or NSS tools). Continuing."

  # --- dsp-keys/ ------------------------------------------------------------
  log_section "Generating dsp-keys/"

  mkdir -p dsp-keys/policyimportexport

  # TLS cert
  if [[ -f dsp-keys/local-dsp.virtru.com.pem && -f dsp-keys/local-dsp.virtru.com.key.pem ]]; then
    log_ok "TLS cert already exists — skipping"
  else
    log_info "Generating TLS certificate..."
    mkcert \
      -cert-file dsp-keys/local-dsp.virtru.com.pem \
      -key-file  dsp-keys/local-dsp.virtru.com.key.pem \
      local-dsp.virtru.com "*.local-dsp.virtru.com" localhost
    log_ok "TLS certificate generated"
  fi

  # KAS RSA key pair
  if [[ -f dsp-keys/kas-private.pem && -f dsp-keys/kas-cert.pem ]]; then
    log_ok "KAS RSA keys already exist — skipping"
  else
    log_info "Generating KAS RSA key pair..."
    openssl req -x509 -nodes -newkey RSA:2048 -subj "/CN=kas" \
      -keyout dsp-keys/kas-private.pem -out dsp-keys/kas-cert.pem -days 365 2>/dev/null
    log_ok "KAS RSA key pair generated"
  fi

  # KAS EC key pair
  if [[ -f dsp-keys/kas-ec-private.pem && -f dsp-keys/kas-ec-cert.pem ]]; then
    log_ok "KAS EC keys already exist — skipping"
  else
    log_info "Generating KAS EC key pair..."
    openssl ecparam -name prime256v1 > dsp-keys/ecparams.tmp
    openssl req -x509 -nodes -newkey ec:dsp-keys/ecparams.tmp -subj "/CN=kas" \
      -keyout dsp-keys/kas-ec-private.pem -out dsp-keys/kas-ec-cert.pem -days 365 2>/dev/null
    rm dsp-keys/ecparams.tmp
    log_ok "KAS EC key pair generated"
  fi

  # cosign key pair
  if [[ -f dsp-keys/policyimportexport/cosign.key && -f dsp-keys/policyimportexport/cosign.pub ]]; then
    log_ok "cosign keys already exist — skipping"
  else
    log_info "Generating policy import/export signing keys..."
    COSIGN_PASSWORD=changeme cosign generate-key-pair \
      --output-key-prefix dsp-keys/policyimportexport/cosign 2>/dev/null
    printf '%s' 'changeme' > dsp-keys/policyimportexport/cosign.pass
    log_ok "cosign key pair generated"
  fi

  # encrypted-search.key
  if [[ -f dsp-keys/encrypted-search.key ]]; then
    log_ok "encrypted-search.key already exists — skipping"
  else
    log_info "Writing encrypted-search.key..."
    printf '%s' '49e9a28af998c2678e6651ad4e60a2dbba2f3d284f58b224b3382919c1de7d55' \
      > dsp-keys/encrypted-search.key
    log_ok "encrypted-search.key written"
  fi

  # --- Local Docker registry ------------------------------------------------
  log_section "Local Docker registry (port 5000)"

  if docker ps --format '{{.Names}}' | grep -q "^registry$"; then
    log_ok "Registry container already running"
  elif docker ps -a --format '{{.Names}}' | grep -q "^registry$"; then
    log_info "Starting existing registry container..."
    docker start registry
    log_ok "Registry started"
  else
    log_info "Starting new registry container..."
    docker run -d --restart=always -p 5000:5000 --name registry registry:2
    log_ok "Registry started"
  fi

  # Check DSP image is present; prompt for bundle path if not
  DSP_TAGS=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list 2>/dev/null || echo "")
  if echo "$DSP_TAGS" | grep -q '"tags"'; then
    log_ok "DSP image found in local registry"
  else
    echo
    log_warn "DSP image not found in local registry."
    echo
    echo "  The proprietary DSP image must be loaded from a Virtru bundle."
    echo "  Expected layout inside the bundle:"
    echo "    virtru-dsp-bundle/"
    echo "    └── dsp   (the DSP CLI binary)"
    echo

    # If the prereqs script already unpacked the bundle, use it automatically
    if [[ -x "$SCRIPT_DIR/virtru-dsp-bundle/dsp" ]]; then
      BUNDLE_DIR="$SCRIPT_DIR/virtru-dsp-bundle"
      log_info "Using bundle unpacked by prereqs: $BUNDLE_DIR"
    else
      BUNDLE_DIR=""
      while true; do
        read -rp "  Enter path to the unpacked Virtru DSP bundle directory: " BUNDLE_DIR
        BUNDLE_DIR="${BUNDLE_DIR/#\~/$HOME}"   # expand leading ~
        if [[ -z "$BUNDLE_DIR" ]]; then
          echo "  Path cannot be empty."
          continue
        fi
        if [[ ! -d "$BUNDLE_DIR" ]]; then
          echo "  Directory not found: $BUNDLE_DIR"
          continue
        fi
        if [[ ! -x "$BUNDLE_DIR/dsp" ]]; then
          echo "  'dsp' binary not found or not executable in $BUNDLE_DIR"
          echo "  Make sure you have unpacked the bundle and that 'dsp' exists at its root."
          continue
        fi
        break
      done
    fi

    log_info "Loading DSP images from bundle: $BUNDLE_DIR"
    (cd "$BUNDLE_DIR" && ./dsp copy-images --insecure localhost:5000/virtru)

    # Verify image loaded
    DSP_TAGS=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list 2>/dev/null || echo "")
    if echo "$DSP_TAGS" | grep -q '"tags"'; then
      log_ok "DSP image loaded successfully"
    else
      die "DSP image still not found after loading. Check the output above for errors."
    fi
  fi

fi  # end prerequisites block

# ---------------------------------------------------------------------------
# Start the stack
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" == false ]]; then

  log_section "Starting Docker Compose stack"

  log_info "Running: docker compose up --build -d"
  docker compose up --build -d
  log_ok "Stack started in detached mode"

  # Wait for DSP to become healthy
  log_section "Waiting for DSP to become healthy"
  log_info "Polling https://local-dsp.virtru.com:8080/healthz (timeout: 5 minutes)..."

  TIMEOUT=300
  ELAPSED=0
  INTERVAL=10
  until curl -fksSo /dev/null --max-time 5 https://local-dsp.virtru.com:8080/healthz 2>/dev/null; do
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      echo
      die "DSP did not become healthy within ${TIMEOUT}s.\nCheck logs: docker compose logs dsp"
    fi
    printf "    Waiting... %ds elapsed\r" "$ELAPSED"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo
  log_ok "DSP is healthy (${ELAPSED}s elapsed)"

fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
log_section "Running validation checks"

ERRORS=()

# --- 1. Container status ----------------------------------------------------
log_info "Check 1: Container status"

COMPOSE_PS=$(docker compose ps --format json 2>/dev/null || docker compose ps 2>/dev/null)

for svc in keycloak-db keycloak dsp-db dsp; do
  if docker compose ps "$svc" 2>/dev/null | grep -qiE "Up|running|healthy"; then
    check_pass "$svc is running"
  else
    check_fail "$svc is NOT running"
    ERRORS+=("$svc container not running")
  fi
done

sleep 5

#for svc in dsp-keycloak-provisioning dsp-provision-federal-policy; do
#  EXIT_CODE=$(docker compose ps "$svc" 2>/dev/null | grep -oE 'Exited \(\K[0-9]+' || echo "unknown")
#  if [[ "$EXIT_CODE" == "0" ]]; then
#    check_pass "$svc exited cleanly (0)"
#  else
#    check_fail "$svc exit code: $EXIT_CODE (expected 0)"
#    ERRORS+=("$svc did not complete successfully")
#  fi
#done

# --- 2. DSP health endpoint -------------------------------------------------
log_info "Check 2: DSP health endpoint"

HEALTH=$(curl -fksSo - --max-time 10 https://local-dsp.virtru.com:8080/healthz 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "SERVING"; then
  check_pass "DSP /healthz → SERVING"
else
  check_fail "DSP /healthz did not return SERVING (got: ${HEALTH:-no response})"
  ERRORS+=("DSP health check failed")
fi

# --- 3. Keycloak realm reachable --------------------------------------------
log_info "Check 3: Keycloak realm"

REALM=$(curl -fksSo - --max-time 10 \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf 2>/dev/null \
  | jq -r '.realm' 2>/dev/null || echo "")
if [[ "$REALM" == "opentdf" ]]; then
  check_pass "Keycloak realm 'opentdf' is reachable"
else
  check_fail "Keycloak realm check failed (got: ${REALM:-no response})"
  ERRORS+=("Keycloak realm not reachable")
fi

# --- 4. Obtain token --------------------------------------------------------
log_info "Check 4: Obtain service account token"

TOKEN=$(curl -fksSo - --max-time 10 \
  -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
  2>/dev/null | jq -r '.access_token' 2>/dev/null || echo "")

if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
  check_pass "Token obtained from Keycloak"
else
  check_fail "Failed to obtain token from Keycloak"
  ERRORS+=("Could not obtain token — subsequent checks will fail")
fi

# --- 5. DSP attributes provisioned ------------------------------------------
log_info "Check 5: DSP attributes (federal policy)"

if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
  ATTRS=$(curl -ksSo - --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "connect-protocol-version: 1" \
    -d '{"pagination":{}}' \
    "https://local-dsp.virtru.com:8080/policy.attributes.AttributesService/ListAttributes" \
    2>/dev/null | jq -r '[.attributes[].name] | sort | join(",")' 2>/dev/null || echo "")

  EXPECTED="classification,needtoknow,relto"
  if [[ "$ATTRS" == "$EXPECTED" ]]; then
    check_pass "Federal policy attributes found: $ATTRS"
  else
    check_fail "Attributes mismatch — expected: $EXPECTED  got: ${ATTRS:-none}"
    ERRORS+=("Federal policy attributes not provisioned correctly")
  fi
else
  check_fail "Skipping attribute check (no token)"
  ERRORS+=("Attribute check skipped — no token")
fi

# --- 6. Database connectivity -----------------------------------------------
log_info "Check 6: Database connectivity"

DSP_TABLES=$(docker exec virtru-dsp-only-dsp-db-1 \
  psql -U postgres -d opentdf -c "\dt dsp_policy.*" 2>/dev/null | grep -c "row" || echo "0")
if [[ "$DSP_TABLES" -gt 0 ]]; then
  check_pass "DSP policy schema has tables in opentdf DB"
else
  check_fail "No tables found in dsp_policy schema"
  ERRORS+=("DSP policy schema empty or missing")
fi

KC_TABLES=$(docker exec virtru-dsp-only-keycloak-db-1 psql -U postgres -d keycloak -c "\dt *" 2>/dev/null | grep -c "row" || echo "0")
if [[ "$KC_TABLES" -gt 0 ]]; then
  check_pass "Keycloak DB has tables"
else
  check_fail "No tables found in Keycloak DB"
  ERRORS+=("Keycloak DB empty or missing")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_section "Validation summary"

echo -e "    Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo

if [[ ${#ERRORS[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All checks passed. DSP stack is healthy.${NC}"
  echo
  echo "  Keycloak admin: https://local-dsp.virtru.com:18443/auth"
  echo "  DSP services:   https://local-dsp.virtru.com:8080"
  echo
  exit 0
else
  echo -e "  ${RED}${BOLD}The following checks failed:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "    ${RED}✗${NC} $err"
  done
  echo
  echo "  Troubleshooting:"
  echo "    docker compose logs dsp"
  echo "    docker compose logs keycloak"
  echo "    docker compose ps"
  echo
  exit 1
fi
