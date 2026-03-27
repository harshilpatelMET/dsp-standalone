# DSP-Only Local Deployment

Runs the Virtru Data Security Platform (DSP) as a self-contained Docker Compose stack — no Kubernetes or bulk data ingestion. Intended to support local SDK development and testing.

NOTE: This setup instance uses default usernames and credentials and should not be used for any purpose beyond local integration development and testing.

## What's Included

| Service | Image | Port(s) | Role |
|---|---|---|---|
| `keycloak-db` | postgres:16 | 25434 | Keycloak's Postgres database |
| `keycloak` | keycloak/keycloak:25.0 | 18443 (HTTPS), 8888 (HTTP health) | Identity Provider (OIDC) |
| `dsp-keycloak-provisioning` | built from `dev.dsp.Dockerfile` | — | One-shot: provisions realm, clients, and users |
| `dsp-db` | postgres:16 | 35433 | DSP's Postgres database |
| `dsp` | built from `dev.dsp.Dockerfile` | 8080 | DSP services (KAS, policy, authz, entity resolution) |
| `dsp-provision-federal-policy` | built from `dev.dsp.Dockerfile` | — | One-shot: loads the federal attribute policy |

## Supported Platforms

| Platform | Status |
|---|---|
| macOS (Intel + Apple Silicon) | Supported |
| Ubuntu 24.04 LTS (amd64 + arm64) | **Experimental** |
| Red Hat Enterprise Linux 8 (amd64 + arm64) | **Experimental** |
| Other Linux distributions | Not currently supported |
| Windows | Not currently supported |

> **Experimental Linux support:** Ubuntu 24.04 LTS and RHEL 8 installs are functional but have not been fully validated across all hardware and environment configurations. Please report any issues encountered.

> **Linux restart required after first-time prereqs:** The `ubuntu_prereqs.sh` and `rhel_prereqs.sh` scripts install Docker and add your user to the `docker` group. This group membership does not take effect in the current shell session — **you must log out and log back in (or reboot) before running `setup_and_validate.sh`**. After logging back in, re-run the setup script with `--skip-prereqs` to skip the tool installation step:
> ```bash
> ./setup_and_validate.sh --skip-prereqs
> ```

### macOS Docker runtime

**OrbStack is the recommended Docker runtime on macOS.** It provides native `host` networking (required by this stack), built-in Rosetta emulation for `linux/amd64` images on Apple Silicon, and faster startup times compared to Docker Desktop.

| Runtime | Recommended | Notes |
|---|---|---|
| [OrbStack](https://orbstack.dev) | **Yes (recommended)** | Native host networking, built-in Rosetta, fastest performance |
| Docker Desktop | With caveats | Requires Rosetta enabled manually; host networking less reliable — see note below |
| Rancher Desktop | Not tested | — |
| Colima | Not tested | — |

> **Docker Desktop on Apple Silicon:** If you use Docker Desktop instead of OrbStack, you must enable Rosetta emulation: **Docker Desktop → Settings → General → "Use Rosetta for x86/amd64 emulation on Apple Silicon"**. Without it, the `linux/amd64` DSP images will run under QEMU and be significantly slower, likely causing startup timeouts. Additionally, `network_mode: host` behaves differently under Docker Desktop — if services are unreachable, add explicit `ports:` mappings to `keycloak` and `dsp` in `docker-compose.yaml`.

> **macOS AirPlay Receiver conflict (port 5000):** macOS Monterey and later run an AirPlay Receiver that listens on port 5000 by default. This conflicts with the local Docker registry used by this stack. If you see `403 Forbidden` errors when loading the DSP image, disable AirPlay Receiver: **System Settings → General → AirDrop & Handoff → turn off "AirPlay Receiver"**, then re-run the setup script.

---

## Prerequisites

### Option A — Automated setup (recommended)

`setup_and_validate.sh` handles all prerequisites, generates keys, loads the DSP image, starts the stack, and runs the full validation suite in a single command.

```bash
# From the DSP-standalone/ directory:
./setup_and_validate.sh
```

The script will:
1. Detect your OS and run the appropriate prereqs script (`mac_prereqs.sh` or `ubuntu_prereqs.sh`)
2. Verify all required tools installed successfully
3. Generate all TLS certificates and keys in `dsp-keys/` (skips files that already exist)
4. Start or verify the local Docker registry — prompts for your Virtru DSP bundle path if the image is not yet loaded
5. Start the Docker Compose stack and wait for DSP to become healthy
6. Run all validation checks and print a pass/fail summary

**Flags:**

| Flag | Effect |
|---|---|
| *(none)* | Full run: prereqs → keys → build → stack → infra checks → **SDK tests** |
| `--skip-prereqs` | Skip tool installation; still validates tools are present |
| `--no-build` | Start stack using cached images — skips `docker compose build` (faster on repeat runs) |
| `--validate-only` | Run infra checks + SDK validation against an already-running stack (no setup or start) |
| `--sdk-only` | Run the Go SDK tests only — skips setup and all infra validation checks |

> **SDK tests and infra checks run by default.** Every run includes both infra validation and the Go SDK tests. Use `--sdk-only` to skip infra checks and setup entirely.

Flags can be combined:

```bash
# Full run — prereqs + infra checks + SDK tests (default)
./setup_and_validate.sh

# Validate a running stack with infra checks + SDK tests
./setup_and_validate.sh --validate-only

# Run only the Go SDK tests (fastest — skips setup and infra checks)
./setup_and_validate.sh --sdk-only

# Skip prereqs and skip rebuild (fastest repeat run, includes infra checks + SDK tests)
./setup_and_validate.sh --skip-prereqs --no-build
```

> **Linux note (Ubuntu + RHEL):** Both Linux installs are experimental. After running the prereqs script for the first time, Docker group membership requires a logout/login (or `newgrp docker`) before Docker commands work without `sudo`. If `setup_and_validate.sh` reports the Docker daemon is unreachable, log out and back in, then re-run with `--skip-prereqs`. The script auto-detects Ubuntu vs RHEL and runs the appropriate prereqs script.

---

### Option B — Manual setup

#### 1. Install prerequisites

**macOS** — run the provided script (requires [Homebrew](https://brew.sh)):

```bash
./mac_prereqs.sh
```

Installs: Homebrew (if missing), curl, wget, git, make, python3, jq, Node.js, nvm, Go, mkcert (+ trust store), cosign. Also adds the `/etc/hosts` entry.

> Docker cannot be installed automatically on macOS. If Docker is not already present, the script will print install options and exit. **OrbStack is recommended** — install it from [orbstack.dev](https://orbstack.dev), start it, then re-run. If using Docker Desktop, enable Rosetta first: **Settings → General → "Use Rosetta for x86/amd64 emulation on Apple Silicon"**.

**Ubuntu 24.04 LTS** *(Experimental)* — run the provided script:

```bash
./ubuntu_prereqs.sh

# Log out and back in (or run the following) for Docker group changes to take effect:
newgrp docker
```

Installs: Docker CE (+ Compose plugin), Node.js, nvm, Go, mkcert, cosign. Also adds the `/etc/hosts` entry.

**Red Hat Enterprise Linux 8** *(Experimental)* — run the provided script:

```bash
./rhel_prereqs.sh

# Log out and back in (or run the following) for Docker group changes to take effect:
newgrp docker
```

Installs: EPEL repo, Docker CE (+ Compose plugin), Node.js, nvm, Go, mkcert, cosign. Also adds the `/etc/hosts` entry.

> **RHEL note:** Docker CE is installed from the official Docker repository. The `podman-docker` shim (if present) is removed to avoid conflicts. SELinux and firewalld are checked automatically by `setup_and_validate.sh` and warnings are printed if action is needed. After running, log out and back in for Docker group membership to take effect.

#### 2. /etc/hosts entry


DSP and Keycloak use TLS certificates issued for `local-dsp.virtru.com`. Add this line to `/etc/hosts` (requires `sudo`):

```
127.0.0.1  local-dsp.virtru.com
```

#### 3. Unpack the bundle

Unzip the Virtru DSP bundle and extract the DSP binary. Replace `X.X.X`, `<os>`, and `<arch>` with your version and platform details.

```bash
# Untar the main bundle
mkdir virtru-dsp-bundle && tar -xvf virtru-dsp-bundle-* -C virtru-dsp-bundle/ && cd virtru-dsp-bundle/

# Unpack DSP tools
# Linux amd64:
tar -xvf tools/dsp/data-security-platform_X.X.X_linux_amd64.tar.gz
# macOS arm64 (Apple Silicon):
tar -xvf tools/dsp/data-security-platform_X.X.X_darwin_arm64.tar.gz
# macOS amd64 (Intel):
tar -xvf tools/dsp/data-security-platform_X.X.X_darwin_amd64.tar.gz

# Unpack and setup grpcurl
tar -xvf tools/grpcurl/grpcurl_X.X.X_linux_amd64.tar.gz
# macOS arm64 (Apple Silicon):
tar -xvf tools/grpcurl/grpcurl_X.X.X_osx_arm64.tar.gz
# macOS amd64 (Intel):
tar -xvf tools/grpcurl/grpcurl_X.X.X_osx_amd64.tar.gz

# Make Executable
chmod +x ./grpcurl

```

#### 4. TLS certificates in `dsp-keys/`

The `dsp-keys/` directory must exist under `DSP-standalone/` and contain:

```
dsp-keys/
├── local-dsp.virtru.com.pem         # TLS certificate for Keycloak and DSP
├── local-dsp.virtru.com.key.pem     # TLS private key
├── kas-cert.pem                     # KAS RSA certificate
├── kas-private.pem                  # KAS RSA private key
├── kas-ec-cert.pem                  # KAS EC certificate
├── kas-ec-private.pem               # KAS EC private key
├── encrypted-search.key             # Encrypted search key (hex string)
└── policyimportexport/
    ├── cosign.key                   # Policy signing private key
    ├── cosign.pub                   # Policy signing public key
    └── cosign.pass                  # Passphrase for cosign.key
```

Run the following from the `DSP-standalone/` directory to generate all keys:

```bash
# 1. Install mkcert
# macOS:
brew install mkcert && mkcert -install
# Ubuntu:
sudo apt install libnss3-tools && \
  MKCERT_VER=$(curl -fsSL https://api.github.com/repos/FiloSottile/mkcert/releases/latest | grep tag_name | cut -d'"' -f4) && \
  curl -fsSLo /usr/local/bin/mkcert "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VER}/mkcert-${MKCERT_VER}-linux-amd64" && \
  chmod +x /usr/local/bin/mkcert && mkcert -install

# 2. TLS certificate for Keycloak and DSP (port 18443 / 8080)
mkcert \
  -cert-file dsp-keys/local-dsp.virtru.com.pem \
  -key-file  dsp-keys/local-dsp.virtru.com.key.pem \
  local-dsp.virtru.com "*.local-dsp.virtru.com" localhost

# 3. KAS RSA key pair
openssl req -x509 -nodes -newkey RSA:2048 -subj "/CN=kas" \
  -keyout dsp-keys/kas-private.pem -out dsp-keys/kas-cert.pem -days 365

# 4. KAS EC key pair
openssl ecparam -name prime256v1 > dsp-keys/ecparams.tmp
openssl req -x509 -nodes -newkey ec:dsp-keys/ecparams.tmp -subj "/CN=kas" \
  -keyout dsp-keys/kas-ec-private.pem -out dsp-keys/kas-ec-cert.pem -days 365
rm dsp-keys/ecparams.tmp

# 5. Policy import/export signing keys
# macOS:
brew install cosign
# Ubuntu:
COSIGN_VER=$(curl -fsSL https://api.github.com/repos/sigstore/cosign/releases/latest | grep tag_name | cut -d'"' -f4) && \
  curl -fsSLo /usr/local/bin/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VER}/cosign-linux-amd64" && \
  chmod +x /usr/local/bin/cosign

mkdir -p dsp-keys/policyimportexport
COSIGN_PASSWORD=changeme cosign generate-key-pair \
  --output-key-prefix dsp-keys/policyimportexport/cosign
printf '%s' 'changeme' > dsp-keys/policyimportexport/cosign.pass

# 6. Encrypted search key (placeholder value used by the SharePoint PEP)
printf '%s' '49e9a28af998c2678e6651ad4e60a2dbba2f3d284f58b224b3382919c1de7d55' \
  > dsp-keys/encrypted-search.key
```

#### 5. DSP image in the local registry

The `dev.dsp.Dockerfile` builds on top of the proprietary DSP image which must be loaded into a local Docker registry on port 5000.

```bash
# Start the local registry (once)
docker run -d --restart=always -p 5000:5000 --name registry registry:2

# Load DSP images from the bundle directory
cd virtru-dsp-bundle/
./dsp copy-images --insecure localhost:5000/virtru

# Verify and note the tag (you will need it for the build step)
curl -s http://localhost:5000/v2/virtru/data-security-platform/tags/list | jq .
```

The `DSP_IMAGE` build argument must be passed when building the image — `setup_and_validate.sh` detects the tag automatically. For manual builds, query the registry and pass the tag explicitly:

```bash
# Detect the tag
DSP_TAG=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list | jq -r '.tags | sort | last')

# Build
docker compose build --build-arg "DSP_IMAGE=localhost:5000/virtru/data-security-platform:${DSP_TAG}"

# Start
docker compose up -d
```

---

## Running the Stack

All commands run from the `DSP-standalone/` directory.

> **macOS + OrbStack tip:** Once `setup_and_validate.sh` has completed successfully at least once, you do not need to re-run it to start or stop the stack. In the OrbStack UI, find the **`virtru-dsp-only`** container group and click the play button to start it or the stop button to stop it. OrbStack remembers the compose project and all its configuration, so this is the easiest way to manage the stack day-to-day.

### Start

The `dev.dsp.Dockerfile` requires the `DSP_IMAGE` build argument. Build and start in two steps:

```bash
# Detect the DSP image tag from the local registry
DSP_TAG=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list | jq -r '.tags | sort | last')

# Build images
docker compose build --build-arg "DSP_IMAGE=localhost:5000/virtru/data-security-platform:${DSP_TAG}"

# Start detached
docker compose up -d
```

On repeat runs where the images are already built, skip the build step:

```bash
docker compose up -d
```

### Stop

```bash
docker compose down
```

To also delete the Postgres volumes:

```bash
docker compose down -v
```

### View logs

```bash
# All services
docker compose logs -f

# Single service
docker compose logs -f dsp
docker compose logs -f keycloak
```

---

## Startup Sequence

Docker Compose enforces this dependency order automatically:

```
keycloak-db (healthy)
    └─► keycloak (healthy)
            └─► dsp-keycloak-provisioning (completed)
                    └─► dsp (healthy)  ◄── dsp-db (healthy)
                                └─► dsp-provision-federal-policy (completed)
```

Allow ~2–3 minutes on first run for Keycloak to initialize. The provisioning containers (`dsp-keycloak-provisioning`, `dsp-provision-federal-policy`) are one-shot — they run once, exit with code 0 on success, and do not restart. A non-zero exit code means provisioning failed; check logs with `docker compose logs dsp-keycloak-provisioning`.

---

## Validation

### Option A — Automated validation (recommended)

If you used `setup_and_validate.sh` for setup, validation runs automatically at the end. To re-run validation against an already-running stack at any time:

```bash
./setup_and_validate.sh --validate-only
```

The script runs all checks below and prints a pass/fail summary.

#### SDK validation

SDK tests run by default in every mode. Use `--sdk-only` to skip infra checks and run only the SDK tests:

| Mode | Infra checks | SDK tests |
|---|---|---|
| *(default)* | Yes | Yes |
| `--validate-only` | Yes | Yes |
| `--sdk-only` | No | Yes |

```bash
# Validate stack + run Go SDK tests (default — no flag needed)
./setup_and_validate.sh --validate-only

# Run only the Go SDK tests (skip infra checks)
./setup_and_validate.sh --sdk-only
```

The SDK validation step does the following in order:

| Step | Program | What it tests |
|---|---|---|
| 1 | `go mod tidy` | Dependencies can be fetched |
| 2 | `toySDK.go` | Alex (TS/USA) can encrypt plaintext into a TDF and decrypt it back |
| 3 | `bobTestAlexFile.go` | Bob (TS/GBR) can decrypt Alex's TDF via FVEY membership |
| 4 | `aliceTestAlexFile.go` | Alice (S/USA) is correctly denied access to a Top Secret TDF |

Each program's full output is printed inside a labeled box so it is visually distinct from the setup script's own status lines:

```
    ┌─ toySDK.go output ──────────────────────────────────────────
    │  ...
    └───────────────────────────────────────────────────────────

    ✓ toySDK.go: Alex successfully encrypted and decrypted the TDF
```

Results feed into the same pass/fail counters as all other checks and appear in the final summary. The `aliceTestAlexFile.go` step counts as a **pass** when access is correctly denied — a failure there means a policy misconfiguration, not a code error.

**Prerequisites for SDK validation:**

| Requirement | Notes |
|---|---|
| Go installed | `brew install go` (macOS) or see `ubuntu_prereqs.sh` |
| DSP stack running and healthy | Stack validation checks must pass first |
| `opentdf-public` client has Direct Access Grants enabled | Set in `sample.keycloak.yaml` — stack must have been provisioned with this enabled |

---

### Option B — Manual validation checks

#### 1. Check container status

```bash
docker compose ps
```

Expected output when fully running:

```
NAME                                         STATUS
virtru-dsp-only-keycloak-db-1               Up (healthy)
virtru-dsp-only-keycloak-1                  Up (healthy)
virtru-dsp-only-dsp-keycloak-provisioning-1 Exited (0)
virtru-dsp-only-dsp-db-1                    Up (healthy)
virtru-dsp-only-dsp-1                       Up (healthy)
virtru-dsp-only-dsp-provision-federal-policy-1 Exited (0)
```

> The two provisioning containers should show `Exited (0)` — a non-zero exit code means provisioning failed.

#### 2. DSP health endpoint

```bash
curl -fks https://local-dsp.virtru.com:8080/healthz
```

Expected: HTTP 200 with a JSON body similar to:

```json
{"status":"SERVING"}
```

#### 3. Keycloak realm reachable

```bash
curl -fks https://local-dsp.virtru.com:18443/auth/realms/opentdf | jq .realm
```

Expected: `"opentdf"`

#### 4. DSP attributes were provisioned (federal policy)

The DSP exposes a ConnectRPC API. Obtain a token and query the attributes service:

```bash
TOKEN=$(curl -fks \
  -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
  | jq -r .access_token)

curl -ks -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "connect-protocol-version: 1" \
  -d '{"pagination":{}}' \
  "https://local-dsp.virtru.com:8080/policy.attributes.AttributesService/ListAttributes" \
  | jq '[.attributes[] | {name, rule, namespace: .namespace.name}]'
```

Expected output:

```json
[
  { "name": "needtoknow",     "rule": "ATTRIBUTE_RULE_TYPE_ENUM_ALL_OF",   "namespace": "demo.com" },
  { "name": "relto",          "rule": "ATTRIBUTE_RULE_TYPE_ENUM_ANY_OF",   "namespace": "demo.com" },
  { "name": "classification", "rule": "ATTRIBUTE_RULE_TYPE_ENUM_HIERARCHY","namespace": "demo.com" }
]
```

#### 5. Database connectivity

```bash
# DSP database — policy tables live in the dsp_policy schema
docker exec virtru-dsp-only-dsp-db-1 psql -U postgres -d opentdf -c "\dt dsp_policy.*"

# Keycloak database
docker exec virtru-dsp-only-keycloak-db-1 psql -U postgres -d keycloak -c "\dt *"
```

---

## Credentials Reference

| Service | Username / Client ID | Password / Secret |
|---|---|---|
| Keycloak admin console | `admin` | `changeme` |
| DSP Postgres | `postgres` | `changeme` |
| Keycloak Postgres | `postgres` | `changeme` |
| Keycloak `opentdf` client | `opentdf` | `secret` |
| Keycloak `opentdf-sdk` client | `opentdf-sdk` | `secret` |
| Test user: Alice (Secret/USA) | `aaa@secret.usa` | `testuser123` |
| Test user: Alex (TS/USA) | `aaa@topsecret.usa` | `testuser123` |
| Test user: Bob (TS/GBR) | `bbb@topsecret.gbr` | `testuser123` |
| Test user: Jane (Confidential/FRA) | `int@classified.fra` | `testuser123` |
| Test user: James (Unclassified/MEX) | `user@unclassified.mex` | `testuser123` |

Keycloak Admin Console: `https://local-dsp.virtru.com:18443/auth`

---

## Troubleshooting

### Keycloak fails to start

- Verify `dsp-keys/local-dsp.virtru.com.pem` and `.key.pem` exist and are readable.
- Check Keycloak-DB is healthy: `docker compose ps keycloak-db`
- Check Keycloak logs for the root cause: `docker logs virtru-dsp-only-keycloak-1`

**Linux / CentOS / RHEL — TLS key permissions**

`mkcert` generates the private key with `0600` permissions. Keycloak runs as UID 1000 inside the container and cannot read a root-owned `0600` file through a Linux bind mount. `setup_and_validate.sh` fixes this automatically, but if keys were generated manually run:

```bash
chmod 0644 dsp-keys/local-dsp.virtru.com.key.pem
docker compose restart keycloak
```

**Linux / CentOS / RHEL — firewalld blocking DB port**

Keycloak (`network_mode: host`) connects to `keycloak-db` (bridge network) at `localhost:25434`. Firewalld can block this traffic. `setup_and_validate.sh` adds `docker0` to the trusted zone automatically, but to fix manually:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=docker0
sudo firewall-cmd --reload
docker compose restart keycloak
```

**CentOS / RHEL — nftables/iptables conflict**

CentOS 8 defaults to nftables; Docker requires iptables. If Docker's NAT rules are silently ignored, containers cannot communicate. `setup_and_validate.sh` detects and switches automatically, but to fix manually:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
sudo systemctl restart docker
docker compose up -d
```

### DSP fails to start or stays unhealthy

- Confirm `local-dsp.virtru.com` resolves to `127.0.0.1`: `ping local-dsp.virtru.com`
- Confirm all KAS key files exist in `dsp-keys/`.
- Check DSP logs: `docker logs virtru-dsp-only-dsp-1`

**Linux / CentOS / RHEL — KAS key permissions**

`openssl` generates private keys with `0600` permissions. The DSP container runs as a non-root user and cannot read these files through a Linux bind mount. `setup_and_validate.sh` fixes this automatically, but to fix manually:

```bash
chmod 0644 dsp-keys/kas-private.pem dsp-keys/kas-ec-private.pem dsp-keys/policyimportexport/cosign.key
docker compose restart dsp
```

> **Note:** Setting private keys to `0644` is safe for local development only. Do not use in production.

### Provisioning container exits non-zero

- Check logs: `docker compose logs dsp-keycloak-provisioning`
- Re-run provisioning manually after DSP is healthy:
  ```bash
  docker compose run --rm dsp-keycloak-provisioning
  ```
- Re-run federal policy provisioning manually:
  ```bash
  docker compose run --rm dsp-provision-federal-policy
  ```

### Port conflicts

If any port is already in use, either stop the conflicting process or override the published port:

```bash
# Example: change keycloak-db external port from 25434 to 25435
DSP_KEYCLOAK_DB_PORT=25435 docker compose up
```

(Requires adding environment variable substitution to the compose file for your specific port.)

### Linux — Docker build fails with "apk add: exit code 255"

Docker containers cannot resolve external DNS. `setup_and_validate.sh` detects and configures this automatically, but to fix manually:

```bash
echo '{"dns": ["8.8.8.8", "1.1.1.1"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

---

## Users and Attributes

### How Access Control Works

DSP uses **Attribute-Based Access Control (ABAC)**. The flow from a user identity to data access is:

```
Keycloak user
  └─ has IdP attributes (clearance, needToKnow, nationality)
        └─ matched by Subject Condition Sets  (in sample.federal_policy.yaml)
              └─ linked via Subject Mappings to DSP Attribute Values
                    └─ applied to TDF-protected data at encrypt time
```

When a user attempts to decrypt data, DSP checks whether their Keycloak attributes satisfy every attribute value that was applied to that data at encryption time.

---

### Existing Users

Users are defined in `sample.keycloak.yaml` under `realms[].users`. Each user has:

- **Keycloak identity** — username, email, password, realm role
- **IdP attributes** — `clearance`, `needToKnow`, `nationality` — these are the values DSP's subject condition sets evaluate

| User Attributes | Email/Username | Clearance | Need-to-Know | Nationality | Realm Role |
|---|---|---|---|---|---|
| `secret-usa-aaa` | aaa@secret.usa | `S` (Secret) | AAA, BBB, INT, OPS | USA | opentdf-org-admin |
| `top-secret-usa-aaa` | aaa@topsecret.usa | `TS` (Top Secret) | AAA, BBB | USA | opentdf-standard |
| `top-secret-gbr-bbb` | bbb@topsecret.gbr | `TS` (Top Secret) | BBB | GBR | opentdf-standard |
| `classified-fra-int` | int@classified.fra | `C` (Confidential) | INT | FRA | opentdf-standard |
| `unclassified-mex-user` | user@unclassified.mex | `U` (Unclassified) | *(none)* | MEX | opentdf-standard |

All test users have password: `testuser123`

**DSP attributes each user is entitled to access** (derived from subject mappings):

| User | classification | needtoknow | relto |
|---|---|---|---|
| Alice (S/USA) | secret, confidential, unclassified | aaa, bbb, int, ops | usa, fvey, nato, pink |
| Alex (TS/USA) | topsecret, secret, confidential, unclassified | aaa, bbb | usa, fvey, nato, pink |
| Bob (TS/GBR) | topsecret, secret, confidential, unclassified | bbb | gbr, fvey, nato, pink |
| Jane (C/FRA) | confidential, unclassified | int | fra, nato, pink |
| James (U/MEX) | unclassified | *(none)* | mex |

---

### Existing Attributes

Attributes are defined in `sample.federal_policy.yaml` under `attributes`. All attributes belong to the `demo.com` namespace.

#### `classification` — HIERARCHY rule

Values are ordered from highest to lowest. A user entitled to a higher level is automatically entitled to all lower levels.
:
| Value | Meaning |
|---|---|
| `topsecret` | Top Secret |
| `secret` | Secret |
| `confidential` | Confidential |
| `unclassified` | Unclassified |

**Mapped from Keycloak `clearance` attribute:**

| Keycloak `clearance` value(s) | Entitled to |
|---|---|
| `TS`, `Top Secret`, `topsecret`, `DV`, `PV`, `NV2` | topsecret (and all below) |
| `S`, `SC`, `Secret`, `NV1` | secret (and all below) |
| `C`, `Confidential` | confidential (and below) |
| `U`, `Unclassified` | unclassified |

#### `needtoknow` — ALL_OF rule

A user must hold **all** needtoknow values applied to a piece of data to decrypt it.

| Value | Mapped from Keycloak `needToKnow` |
|---|---|
| `aaa` | `AAA` |
| `bbb` | `BBB` |
| `int` | `INT` |
| `ops` | `OPS` |

#### `relto` — ANY_OF rule

A user needs **at least one** matching relto value. Includes coalition groups and individual ISO 3166-1 alpha-3 country codes.

| Value | Members |
|---|---|
| `fvey` | USA, GBR, AUS, CAN, NZL |
| `nato` | 32 NATO member nations |
| `pink` | 21 nations (USA, GBR, FRA, DEU, + 17 others) |
| `USA`, `GBR`, `FRA`, … | Individual nations — mapped from Keycloak `nationality` |

---

### Adding a New User

New users are added to `sample.keycloak.yaml`. They take effect the next time the stack is started fresh (the `dsp-keycloak-provisioning` one-shot container re-runs).

**Step 1 — Add the user to `sample.keycloak.yaml`**
***Note this must be done before the system is up and running** 

**Option A — Interactive script (recommended)**

Run `add_user.py` from the `DSP-standalone/` directory. It prompts for each field, validates input, applies defaults, and appends the correctly formatted YAML block automatically:

```bash
python3 add_user.py
```

The script prompts for: username, first/last name, email, password, clearance level, need-to-know compartments, nationality (ISO 3166-1 alpha-3), realm role, and optional group membership. It validates each input and shows defaults where applicable. On confirmation it writes the entry directly to `sample.keycloak.yaml`.

**Option B — Edit manually**

Find the `users:` list under `realms[0]` and append a new entry. The minimum required fields are `username`, `email`, `credentials`, `realmRoles`, and `attributes`.

```yaml
# sample.keycloak.yaml
realms:
  - ...
    users:
      # ... existing users ...

      - username: secret-aus-ops         # unique login name
        enabled: true
        firstName: Carol
        lastName: SecretAUS
        email: ops@secret.aus
        credentials:
          - value: testuser123
            type: password
        realmRoles:
          - opentdf-standard             # use opentdf-org-admin for admin users
        attributes:
          clearance:
            - S                          # S | TS | C | U  (or full words)
          needToKnow:
            - OPS                        # any combination of AAA, BBB, INT, OPS
          nationality:
            - AUS                        # ISO 3166-1 alpha-3 country code
```

**Step 2 — Apply the change**

If the stack is already running, restart just the provisioning container:

```bash
docker compose run --rm dsp-keycloak-provisioning
```

Or do a full restart:

```bash
docker compose down
docker compose up --build
```

**Step 3 — Verify the user was created**

Obtain an admin token and query Keycloak's user API:

```bash
ADMIN_TOKEN=$(curl -fks \
  -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
  | jq -r .access_token)

curl -fks \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://local-dsp.virtru.com:18443/auth/admin/realms/opentdf/users?username=secret-aus-ops" \
  | jq '.[0] | {username, email, attributes}'
```

**Step 4 — Verify entitlements (optional)**

Confirm the user's Keycloak IdP attributes are set correctly — these are what DSP subject condition sets evaluate to determine entitlements:

```bash
ADMIN_TOKEN=$(curl -fks \
  -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
  | jq -r .access_token)

curl -fks \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://local-dsp.virtru.com:18443/auth/admin/realms/opentdf/users?username=secret-aus-ops" \
  | jq '.[0] | {username, email, attributes}'
```

Expected output confirms the user carries the correct IdP attributes:

```json
{
  "username": "secret-aus-ops",
  "email": "ops@secret.aus",
  "attributes": {
    "clearance": ["S"],
    "needToKnow": ["OPS"],
    "nationality": ["AUS"]
  }
}
```

> DSP maps these Keycloak attributes to DSP attribute values via the subject condition sets in `sample.federal_policy.yaml`. A user with `clearance: S` and `nationality: AUS` will be entitled to `classification/secret` (and below) and `relto/fvey` (since AUS is a Five Eyes member).

---

**Option C — Use Keycloak UI**

The Keycloak UI allows admins to create new users and authorizations/accesses/entitlements.

Browse to `https://local-dsp.virtru.com:18443/auth/admin` 

Login with the default credentials for Keycloak admin and create the user. Please refer to Keycloak administration guide: `https://www.keycloak.org/docs/latest/server_admin/index.html`


### Adding a New Attribute Value to an Existing Attribute

This covers adding a new value (e.g. a new clearance level, needtoknow compartment, or country group) to an already-defined attribute definition.

**Example: add a new needtoknow compartment `sci`**

**Step 1 — Add the value to `sample.federal_policy.yaml`**

```yaml
# sample.federal_policy.yaml
attributes:
  - namespace: demo.com
    attributes:
      - name: needtoknow
        rule: ALL_OF
        values:
          - value: aaa
          - value: bbb
          - value: int
          - value: ops
          - value: sci          # <-- add new value here
```

**Step 2 — Add a Subject Condition Set** that maps a Keycloak attribute value to this DSP value:

```yaml
subject_condition_sets:
  # ... existing sets ...

  scs_needtoknow_sci:
    subject_sets:
      - condition_groups:
          - boolean_operator: CONDITION_BOOLEAN_TYPE_ENUM_OR
            conditions:
              - subject_external_selector_value: '.attributes.needToKnow[]'
                operator: SUBJECT_MAPPING_OPERATOR_ENUM_IN
                subject_external_values:
                  - SCI                  # the value stored in Keycloak
              - subject_external_selector_value: '.clientId'
                operator: SUBJECT_MAPPING_OPERATOR_ENUM_IN
                subject_external_values: *approved_clients
```

**Step 3 — Add a Subject Mapping** linking the attribute value to the condition set:

```yaml
subject_mappings:
  # ... existing mappings ...

  sm_needtoknow_sci:
    attribute_value: demo.com/attr/needtoknow/value/sci
    subject_condition_set_name: scs_needtoknow_sci
    actions:
      - DECRYPT
      - READ
```

**Step 4 — Reprovision the DSP policy:**

```bash
docker compose run --rm dsp-provision-federal-policy
```

**Step 5 — Verify the new value exists:**

```bash
TOKEN=$(curl -fks \
  -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
  | jq -r .access_token)

curl -ks -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "connect-protocol-version: 1" \
  -d '{"pagination":{}}' \
  "https://local-dsp.virtru.com:8080/policy.attributes.AttributesService/ListAttributes" \
  | jq '[.attributes[] | select(.name == "sci")]'
```

---

### Adding a New Attribute Definition

This covers adding an entirely new attribute (new name, new rule type) under the `demo.com` namespace.

**Example: add a `program` attribute with values `alpha` and `bravo`**

**Step 1 — Add the attribute definition to `sample.federal_policy.yaml`:**

```yaml
attributes:
  - namespace: demo.com
    attributes:
      - name: classification
        # ... existing ...
      - name: needtoknow
        # ... existing ...
      - name: relto
        # ... existing ...

      - name: program              # <-- new attribute
        rule: ANY_OF               # ANY_OF | ALL_OF | HIERARCHY
        values:
          - value: alpha
          - value: bravo
```

**Available rule types:**

| Rule | Behavior |
|---|---|
| `HIERARCHY` | Values are ordered; higher entitlement implies lower ones. Use for clearance levels. |
| `ALL_OF` | User must hold every value applied to the data. Use for compartments. |
| `ANY_OF` | User needs at least one matching value. Use for group membership. |

**Step 2 — Add Subject Condition Sets** for each new value.

For `ANY_OF` / `ALL_OF` — one condition set per value:

```yaml
subject_condition_sets:
  scs_program_alpha:
    subject_sets:
      - condition_groups:
          - boolean_operator: CONDITION_BOOLEAN_TYPE_ENUM_OR
            conditions:
              - subject_external_selector_value: '.attributes.program[]'
                operator: SUBJECT_MAPPING_OPERATOR_ENUM_IN
                subject_external_values:
                  - alpha              # Keycloak user attribute value
              - subject_external_selector_value: '.clientId'
                operator: SUBJECT_MAPPING_OPERATOR_ENUM_IN
                subject_external_values: *approved_clients

  scs_program_bravo:
    subject_sets:
      - condition_groups:
          - boolean_operator: CONDITION_BOOLEAN_TYPE_ENUM_OR
            conditions:
              - subject_external_selector_value: '.attributes.program[]'
                operator: SUBJECT_MAPPING_OPERATOR_ENUM_IN
                subject_external_values:
                  - bravo
              - subject_external_selector_value: '.clientId'
                operator: SUBJECT_MAPPING_OPERATOR_ENUM_IN
                subject_external_values: *approved_clients
```

**Step 3 — Add Subject Mappings** for each value:

```yaml
subject_mappings:
  sm_program_alpha:
    attribute_value: demo.com/attr/program/value/alpha
    subject_condition_set_name: scs_program_alpha
    actions:
      - DECRYPT
      - READ

  sm_program_bravo:
    attribute_value: demo.com/attr/program/value/bravo
    subject_condition_set_name: scs_program_bravo
    actions:
      - DECRYPT
      - READ
```

**Step 4 — Update users in `sample.keycloak.yaml`** to carry the new IdP attribute:

```yaml
users:
  - username: secret-usa-aaa
    # ... existing fields ...
    attributes:
      clearance:
        - S
      needToKnow:
        - AAA
      nationality:
        - USA
      program:              # <-- add the new attribute
        - alpha
```

**Step 5 — Reprovision everything:**

```bash
# Reprovision Keycloak users
docker compose run --rm dsp-keycloak-provisioning

# Reprovision DSP policy
docker compose run --rm dsp-provision-federal-policy
```

**Step 6 — Verify the new attribute exists in DSP:**

```bash
TOKEN=$(curl -fks \
  -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
  | jq -r .access_token)

# List all attributes — new one should appear
curl -ks -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "connect-protocol-version: 1" \
  -d '{"pagination":{}}' \
  "https://local-dsp.virtru.com:8080/policy.attributes.AttributesService/ListAttributes" \
  | jq '[.attributes[] | select(.name == "program")]'
```

---

### Configuration File Reference

| File | Purpose |
|---|---|
| `sample.keycloak.yaml` | Defines Keycloak realm, clients, and users. Consumed by `dsp-keycloak-provisioning`. |
| `sample.federal_policy.yaml` | Defines DSP attribute namespaces, definitions, values, subject mappings, and subject condition sets. Consumed by `dsp-provision-federal-policy`. |

Changes to either file require re-running the corresponding provisioning container (or a full stack restart) to take effect.

---

## SDK Examples

The three Go programs below can be run individually (see each section) or all together via the setup script. Running them through the setup script handles dependency fetching, compiles each program before running it, executes them in the correct order, and includes their results in the overall pass/fail summary.

| Command | What runs |
|---|---|
| `./setup_and_validate.sh` | Full setup + infra checks + Go SDK tests (default) |
| `./setup_and_validate.sh --validate-only` | Infra checks + Go SDK tests (no setup) |
| `./setup_and_validate.sh --sdk-only` | Go SDK tests only — skips setup and infra checks (fastest) |

### toySDK.go

A Go smoke test that exercises the full TDF encrypt/decrypt round-trip against the local DSP stack using the [OpenTDF platform SDK](https://github.com/opentdf/platform).

#### What it does

1. Authenticates as **Alex** (`aaa@topsecret.usa`, TS/USA) using the Resource Owner Password Credentials (ROPC) flow via the `opentdf-public` Keycloak client
2. Prints the plaintext content and its Shannon entropy
3. Encrypts the plaintext into a TDF with the following attributes:
   - `classification/topsecret`
   - `relto/usa`
   - `relto/fvey`
4. Saves the encrypted TDF to `alex_test.tdf`
5. Prints a hex dump (first 256 bytes) and Shannon entropy of the encrypted content to confirm it is opaque binary data (~8.0 bits/byte)
6. Decrypts the TDF and prints the recovered plaintext to verify the round-trip

#### Prerequisites

| Requirement | Notes |
|---|---|
| DSP stack running | `docker compose up --build` |
| Go installed | `brew install go` (macOS) or see `ubuntu_prereqs.sh` |
| `GOPRIVATE` set | `go env -w GOPRIVATE=github.com/virtru-corp/*` |
| Dependencies fetched | `go mod tidy` |

#### Run

```bash
# Without building
go run toySDK.go

# Or build first, then run
go build -o toySDK toySDK.go
./toySDK
```

#### Expected output

```
========================================
PLAINTEXT CONTENT:
========================================
TOP SECRET
<random 140-char string>
TOP SECRET

Plaintext entropy: 4.XXXX bits/byte

TDF written to: alex_test.tdf (XXXX bytes)

========================================
ENCRYPTED CONTENT (hex dump, first 256 bytes):
========================================
00000000  50 4b 03 04 ...
...

Encrypted entropy: 7.XXXX bits/byte (close to 8.0 = well encrypted)

========================================
DECRYPTED CONTENT:
========================================
TOP SECRET
<random 140-char string>
TOP SECRET

SUCCESS: TDF created, saved, and decrypted successfully
```

#### Output file

| File | Description |
|---|---|
| `alex_test.tdf` | The encrypted TDF written to the current directory |

---

### bobTestAlexFile.go

A Go test that verifies cross-user TDF decryption. Bob (TS/GBR) attempts to decrypt `alex_test.tdf` — the TDF created by `toySDK.go` as Alex (TS/USA).

#### Why Bob can decrypt Alex's file

Alex's TDF is protected with:
- `classification/topsecret` — Bob holds TS clearance ✓
- `relto/usa` — Bob is not USA
- `relto/fvey` — GBR is a Five Eyes member ✓

The `relto` attribute uses an **ANY_OF** rule, so Bob only needs to satisfy one value. Since he holds `relto/fvey`, access is granted.

#### Prerequisites

| Requirement | Notes |
|---|---|
| DSP stack running | `docker compose up --build` |
| `alex_test.tdf` exists | Run `toySDK.go` first |
| Go installed | `brew install go` (macOS) or see `ubuntu_prereqs.sh` |
| Dependencies fetched | `go mod tidy` |

#### Run

```bash
# Run toySDK.go first to generate alex_test.tdf
go run toySDK.go

# Then run Bob's decryption test
go run bobTestAlexFile.go
```

#### Expected output

```
========================================
DECRYPTED CONTENT:
========================================
TOP SECRET
<random 140-char string>
TOP SECRET

SUCCESS: Bob successfully decrypted Alex's file
```

#### Failure cases

| Failure message | Cause |
|---|---|
| `Could not open alex_test.tdf` | `toySDK.go` has not been run yet |
| `Bob could not authenticate` | Keycloak not running or `opentdf-public` client not provisioned with `directAccessGrantsEnabled: true` |
| `Bob was denied access (KAS rejected key unwrap)` | Bob's entitlements do not satisfy the TDF attributes — check subject mappings |
| `Bob could not decrypt TDF content` | TDF file is corrupt or the DSP stack is unhealthy |

---

### aliceTestAlexFile.go

A Go test that verifies access is correctly **denied** when a user's clearance is insufficient. Alice (S/USA) attempts to decrypt `alex_test.tdf` — the TDF created by `toySDK.go` as Alex (TS/USA).

#### Why Alice cannot decrypt Alex's file

Alex's TDF is protected with:
- `classification/topsecret` — Alice only holds **Secret (S)** clearance ✗

The `classification` attribute uses a **HIERARCHY** rule. Alice is entitled to `secret`, `confidential`, and `unclassified` — but not `topsecret`. KAS will reject her key unwrap request.

> **Note:** This test reports `SUCCESS` when access is correctly denied. If Alice is somehow able to decrypt the file, the test reports `FAILURE` and prints the content — indicating a policy misconfiguration.

#### Prerequisites

| Requirement | Notes |
|---|---|
| DSP stack running | `docker compose up --build` |
| `alex_test.tdf` exists | Run `toySDK.go` first |
| Go installed | `brew install go` (macOS) or see `ubuntu_prereqs.sh` |
| Dependencies fetched | `go mod tidy` |

#### Run

```bash
# Run toySDK.go first to generate alex_test.tdf
go run toySDK.go

# Then run Alice's access denial test
go run aliceTestAlexFile.go
```

#### Expected output

```
========================================
ACCESS DENIED (expected):
========================================
KAS rejected Alice's key unwrap request: <error detail>

SUCCESS: Access correctly denied — Alice cannot decrypt a Top Secret file
```

#### Unexpected failure

If Alice successfully decrypts the file the output will be:

```
========================================
DECRYPTED CONTENT (should NOT have happened):
========================================
TOP SECRET
<content>
TOP SECRET

FAILURE: Alice was able to decrypt a Top Secret file — check subject mappings and policy
```

This indicates a misconfiguration in the subject mappings or attribute hierarchy in `sample.federal_policy.yaml`. Re-run `docker compose run --rm dsp-provision-federal-policy` to reprovision the policy.
