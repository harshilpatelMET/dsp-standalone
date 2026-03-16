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
#   ./setup_and_validate.sh                              # full run (with --build)
#   ./setup_and_validate.sh --skip-prereqs               # skip tool installs, go straight to keys/stack
#   ./setup_and_validate.sh --no-build                   # start stack using cached images (no --build)
#   ./setup_and_validate.sh --validate-only              # validate a running stack (no setup)
#   ./setup_and_validate.sh --sdk-validation             # also build and run Go SDK test programs
#   ./setup_and_validate.sh --validate-only --sdk-validation  # validate + SDK tests only
#   ./setup_and_validate.sh --sdk-only                   # run Go SDK tests only (skip infra checks)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
SKIP_PREREQS=false
VALIDATE_ONLY=false
SDK_VALIDATION=false
SDK_ONLY=false
NO_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --skip-prereqs)    SKIP_PREREQS=true ;;
    --validate-only)   VALIDATE_ONLY=true ;;
    --sdk-validation)  SDK_VALIDATION=true ;;
    --sdk-only)        SDK_ONLY=true; SDK_VALIDATION=true; VALIDATE_ONLY=true ;;
    --no-build)        NO_BUILD=true ;;
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

# Warn Docker Desktop users on Apple Silicon
if [[ "$OS" == "darwin" && "$ARCH" == "arm64" ]]; then
  if docker info 2>/dev/null | grep -q "Docker Desktop"; then
    log_warn "Docker Desktop detected on Apple Silicon."
    log_warn "OrbStack (https://orbstack.dev) is recommended for this stack — it provides"
    log_warn "native host networking and built-in Rosetta for linux/amd64 images."
    log_warn "If staying with Docker Desktop, enable Rosetta:"
    log_warn "  Settings → General → Use Rosetta for x86/amd64 emulation on Apple Silicon"
  else
    log_ok "Docker runtime: $(docker info 2>/dev/null | grep 'Operating System' | awk -F': ' '{print $2}' || echo 'unknown')"
  fi
fi

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

  # --- federal policy sample ------------------------------------------------
  log_section "Sample federal policy"

  FEDERAL_SRC="$SCRIPT_DIR/virtru-dsp-bundle/samples/defaults/federal.yaml"
  FEDERAL_DST="$SCRIPT_DIR/sample.federal_policy.yaml"

  if [[ -f "$FEDERAL_DST" ]]; then
    log_ok "sample.federal_policy.yaml already exists — skipping"
  elif [[ -f "$FEDERAL_SRC" ]]; then
    cp "$FEDERAL_SRC" "$FEDERAL_DST"
    log_ok "Copied $FEDERAL_SRC → $FEDERAL_DST"
  else
    log_warn "Bundle policy file not found: $FEDERAL_SRC"
    log_warn "sample.federal_policy.yaml will need to be provided manually before starting the stack."
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
# Detect DSP image tag from registry + start the stack
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" == false ]]; then

  log_section "Detecting DSP image version"

  DSP_TAG=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list 2>/dev/null \
    | jq -r '.tags | sort | last' 2>/dev/null || echo "")

  if [[ -z "$DSP_TAG" || "$DSP_TAG" == "null" ]]; then
    die "Could not detect DSP image tag from local registry.\nMake sure the registry is running and the image has been loaded."
  fi

  DSP_IMAGE="localhost:5000/virtru/data-security-platform:${DSP_TAG}"
  log_ok "DSP image: $DSP_IMAGE"

  log_section "Starting Docker Compose stack"

  if [[ "$NO_BUILD" == true ]]; then
    log_info "Running: docker compose up -d (--no-build: using cached images)"
    docker compose up -d
  else
    log_info "Running: docker compose build --build-arg DSP_IMAGE=${DSP_IMAGE}"
    docker compose build --build-arg "DSP_IMAGE=${DSP_IMAGE}"
    log_info "Running: docker compose up -d"
    docker compose up -d
  fi
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
ERRORS=()

if [[ "$SDK_ONLY" == true ]]; then
  log_section "Skipping infra checks (--sdk-only)"
else
  log_section "Running validation checks"

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

  # Wait for one-shot provisioning containers to reach Exited (0)
  log_info "Check 1b: Waiting for provisioning containers to complete"

  for svc in dsp-keycloak-provisioning dsp-provision-federal-policy; do
    MAX_ATTEMPTS=4
    ATTEMPT=0
    PROVISIONED=false
    while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
      ATTEMPT=$((ATTEMPT + 1))
      if docker compose ps "$svc" 2>/dev/null | grep -q "Exited (0)"; then
        check_pass "$svc completed successfully"
        PROVISIONED=true
        break
      fi
      log_info "$svc not yet done (attempt $ATTEMPT/$MAX_ATTEMPTS) — waiting 15s..."
      sleep 15
    done
    if [[ "$PROVISIONED" == false ]]; then
      log_warn "$svc did not reach Exited (0) after $MAX_ATTEMPTS attempts — continuing with warning"
      log_warn "Validation checks may fail if provisioning is still in progress."
      log_warn "To inspect: docker compose logs $svc"
    fi
  done

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

fi  # end infra checks (skipped when --sdk-only)

# ---------------------------------------------------------------------------
# SDK Validation (optional — requires --sdk-validation flag)
# ---------------------------------------------------------------------------

# Helper: print captured output indented inside a labeled box
print_program_output() {
  local label="$1"
  local output="$2"
  echo
  echo -e "    ${BOLD}┌─ ${label} output ──────────────────────────────────────────${NC}"
  echo "$output" | while IFS= read -r line; do
    echo -e "    ${BOLD}│${NC}  $line"
  done
  echo -e "    ${BOLD}└───────────────────────────────────────────────────────────${NC}"
  echo
}

if [[ "$SDK_VALIDATION" == "true" ]]; then
  log_section "SDK Validation (Go programs)"

  SDK_DIR="$SCRIPT_DIR"

  # Verify Go is installed
  if ! command -v go &> /dev/null; then
    check_fail "Go is not installed — cannot run SDK validation"
    ERRORS+=("Go not found; install Go and re-run with --sdk-validation")
  else
    log_ok "Go found: $(go version)"

    # --- Check / create go.mod -----------------------------------------------
    log_info "Checking go.mod..."

    GOMOD="$SDK_DIR/go.mod"
    EXPECTED_MODULE="dsp-standalone"
    EXPECTED_SDK="github.com/opentdf/platform/sdk v0.7.0"
    EXPECTED_OAUTH="golang.org/x/oauth2"

    GOMOD_OK=true

    if [[ ! -f "$GOMOD" ]]; then
      log_warn "go.mod not found — creating it"
      GOMOD_OK=false
    else
      # Verify the module name and required direct dependencies are present
      if ! grep -q "^module ${EXPECTED_MODULE}$" "$GOMOD"; then
        log_warn "go.mod module name is not '${EXPECTED_MODULE}'"
        GOMOD_OK=false
      fi
      if ! grep -q "${EXPECTED_SDK}" "$GOMOD"; then
        log_warn "go.mod is missing direct dependency: ${EXPECTED_SDK}"
        GOMOD_OK=false
      fi
      if ! grep -q "${EXPECTED_OAUTH}" "$GOMOD"; then
        log_warn "go.mod is missing direct dependency: ${EXPECTED_OAUTH}"
        GOMOD_OK=false
      fi
    fi

    if [[ "$GOMOD_OK" == false ]]; then
      log_info "Writing a fresh go.mod for the SDK programs..."
      GO_VERSION_SHORT=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | head -1 | sed 's/go//')
      cat > "$GOMOD" <<EOF
module ${EXPECTED_MODULE}

go ${GO_VERSION_SHORT}

require (
	github.com/opentdf/platform/sdk v0.7.0
	golang.org/x/oauth2 v0.30.0
)
EOF
      check_pass "go.mod created (module=${EXPECTED_MODULE}, sdk=v0.7.0)"
    else
      check_pass "go.mod is present and contains the expected dependencies"
    fi

    # Load dependencies
    log_info "Running go mod tidy..."
    if (cd "$SDK_DIR" && go mod tidy 2>&1); then
      check_pass "go mod tidy succeeded"
    else
      check_fail "go mod tidy failed"
      ERRORS+=("go mod tidy failed — check go.mod and network connectivity")
    fi

    # --- Build all three programs first ----------------------------------------
    log_info "Building Go programs..."
    BUILD_DIR=$(mktemp -d)

    BIN_TOY="$BUILD_DIR/toySDK"
    BIN_BOB="$BUILD_DIR/bobTestAlexFile"
    BIN_ALICE="$BUILD_DIR/aliceTestAlexFile"

    BUILD_OK=true
    while IFS=: read -r src bin; do
      BUILD_OUTPUT=$(cd "$SDK_DIR" && go build -o "$bin" "$src" 2>&1) && BUILD_RC=0 || BUILD_RC=$?
      if [[ $BUILD_RC -eq 0 ]]; then
        check_pass "Built $src"
      else
        check_fail "Failed to build $src (exit $BUILD_RC)"
        echo "$BUILD_OUTPUT" | while IFS= read -r line; do log_fail "  $line"; done
        ERRORS+=("Build failed: $src — fix compile errors before running SDK tests")
        BUILD_OK=false
      fi
    done <<EOF
toySDK.go:$BIN_TOY
bobTestAlexFile.go:$BIN_BOB
aliceTestAlexFile.go:$BIN_ALICE
EOF

    if [[ "$BUILD_OK" == false ]]; then
      log_warn "Skipping SDK test runs due to build failures above"
    else

      # --- toySDK: Alex encrypts a file ---------------------------------------
      log_info "Running toySDK (Alex creates alex_test.tdf)..."
      TOY_OUTPUT=$(cd "$SDK_DIR" && "$BIN_TOY" 2>&1) && TOY_RC=0 || TOY_RC=$?
      print_program_output "toySDK.go" "$TOY_OUTPUT"
      if [[ $TOY_RC -eq 0 ]]; then
        check_pass "toySDK.go: Alex successfully encrypted and decrypted the TDF"
      else
        check_fail "toySDK.go failed (exit $TOY_RC)"
        ERRORS+=("toySDK.go failed — Alex could not create TDF")
      fi

      # --- bobTestAlexFile: Bob (TS/GBR) should decrypt Alex's file -----------
      log_info "Running bobTestAlexFile (Bob reads Alex's file)..."
      BOB_OUTPUT=$(cd "$SDK_DIR" && "$BIN_BOB" 2>&1) && BOB_RC=0 || BOB_RC=$?
      print_program_output "bobTestAlexFile.go" "$BOB_OUTPUT"
      if [[ $BOB_RC -eq 0 ]]; then
        check_pass "bobTestAlexFile.go: Bob successfully decrypted Alex's file (FVEY + TS access)"
      else
        check_fail "bobTestAlexFile.go failed (exit $BOB_RC)"
        ERRORS+=("bobTestAlexFile.go failed — Bob should be able to decrypt Alex's file")
      fi

      # --- aliceTestAlexFile: Alice (S/USA) should be denied ------------------
      log_info "Running aliceTestAlexFile (Alice denied Alex's file)..."
      ALICE_OUTPUT=$(cd "$SDK_DIR" && "$BIN_ALICE" 2>&1) && ALICE_RC=0 || ALICE_RC=$?
      print_program_output "aliceTestAlexFile.go" "$ALICE_OUTPUT"
      if [[ $ALICE_RC -eq 0 ]]; then
        check_pass "aliceTestAlexFile.go: KAS correctly denied Alice access to Top Secret file"
      else
        check_fail "aliceTestAlexFile.go failed (exit $ALICE_RC) — expected denial to succeed"
        ERRORS+=("aliceTestAlexFile.go: access denial test did not succeed as expected")
      fi

    fi

    rm -rf "$BUILD_DIR"
  fi
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
