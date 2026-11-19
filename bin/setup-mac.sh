#!/usr/bin/env bash
set -euo pipefail

# Multiplier macOS Dev-Machine Bootstrap & Readiness Script
# Safe to run on a fresh Mac (no git, brew, ws, or AI tools pre-installed).
# Compatible with macOS stock Bash 3.2+. Never overwrites user dotfiles/configs.

REPO_SLUG="madhupmamodia/devtools-app"
RELEASE_BASE_URL="https://github.com/${REPO_SLUG}/releases/latest/download"
GATEWAY_DEFAULT_URL="https://llm-gateway.usemultiplier.cloud"

DO_CORE=false
DO_FRONTEND=false
DO_BACKEND=false
DO_AI=false
DO_APPS=false
EXPLICIT_STACK=false
DRY_RUN=false
VERIFY_ONLY=false

usage() {
  cat <<'EOF'
Multiplier macOS Dev-Machine Bootstrap & Readiness

Usage:
  setup-mac.sh [options]

Stack flags (default when none given: --core --frontend --backend --ai):
  --core       Xcode CLT, Homebrew, git, gh, jq, ripgrep, openssl, DevTools.app, ws CLI
  --frontend   nvm, Node 22, Corepack (Yarn 3.x), Volta
  --backend    jenv, OpenJDK 11/17/21, Gradle, Docker Desktop, Postgres 14/libpq, AWS CLI + SSO, grpcurl, yq, kubectl, ngrok
  --ai         Python 3.12, pipx, codebase-memory-mcp, code-review-graph, opencode, claude, codex, pi
  --apps       Optional GUI apps: iTerm2, Pritunl, IntelliJ IDEA CE, DBeaver, Postman, Cursor, VS Code, OpenCode Desktop
  --all        All stacks above including --apps

Modes:
  --dry-run    Print planned actions without modifying the machine
  --verify     Run readiness scorecard only (no installs)
  -h, --help   Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core)     DO_CORE=true; EXPLICIT_STACK=true ;;
    --frontend) DO_FRONTEND=true; EXPLICIT_STACK=true ;;
    --backend)  DO_BACKEND=true; EXPLICIT_STACK=true ;;
    --ai)       DO_AI=true; EXPLICIT_STACK=true ;;
    --apps)     DO_APPS=true; EXPLICIT_STACK=true ;;
    --all)
      DO_CORE=true; DO_FRONTEND=true; DO_BACKEND=true; DO_AI=true; DO_APPS=true
      EXPLICIT_STACK=true
      ;;
    --dry-run)  DRY_RUN=true ;;
    --verify)   VERIFY_ONLY=true ;;
    -h|--help)  usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! $EXPLICIT_STACK; then
  DO_CORE=true
  DO_FRONTEND=true
  DO_BACKEND=true
  DO_AI=true
fi

# Colors only when stdout is a terminal
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'
else
  C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '  %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }

run_cmd() {
  if $DRY_RUN; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Assert OS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only supports macOS (Darwin)." >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  HOMEBREW_PREFIX="/opt/homebrew"
else
  HOMEBREW_PREFIX="/usr/local"
fi

# Refresh PATH with common locations so verification/idempotency works in fresh shells
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$HOMEBREW_PREFIX/opt/libpq/bin:$HOMEBREW_PREFIX/opt/postgresql@14/bin:$HOME/.jenv/shims:$HOME/.jenv/bin:$PATH"

# Load nvm if already installed (`nvm.sh` is not set -eu clean)
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
load_nvm() {
  local rc=1
  set +eu
  if [[ -s "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    . "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" >/dev/null 2>&1 && rc=0
  elif [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && rc=0
  fi
  set -eu
  return "$rc"
}
load_nvm || true

# ---------------------------------------------------------------------------
# Readiness Scorecard (--verify or post-install)
# ---------------------------------------------------------------------------
VERIFY_FAILURES=0

check_bin() {
  local label="$1"
  local bin="$2"
  local required="$3"
  local hint="$4"
  if command -v "$bin" >/dev/null 2>&1; then
    local resolved
    resolved="$(command -v "$bin")"
    ok "$label ($resolved)"
  elif [[ "$required" == "required" ]]; then
    fail "$label missing — $hint"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  else
    warn "$label missing (optional) — $hint"
  fi
}

check_app() {
  local label="$1"
  local app_path="$2"
  local required="$3"
  local hint="$4"
  if [[ -d "$app_path" ]]; then
    ok "$label ($app_path)"
  elif [[ "$required" == "required" ]]; then
    fail "$label missing — $hint"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  else
    warn "$label missing (optional) — $hint"
  fi
}

run_verify() {
  echo ""
  printf '%sMultiplier Mac Readiness Scorecard%s\n' "$C_BOLD" "$C_RESET"
  echo "Architecture: $ARCH | Home: $HOME"
  echo ""

  log "Core & DevTools"
  if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools ($(xcode-select -p))"
  else
    fail "Xcode Command Line Tools missing — xcode-select --install"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
  check_bin "Homebrew" "brew" "required" "Install Homebrew"
  check_bin "git" "git" "required" "brew install git"
  check_bin "gh (GitHub CLI)" "gh" "required" "brew install gh"
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    ok "GitHub CLI authenticated"
  else
    warn "GitHub CLI not authenticated — run: gh auth login && gh auth setup-git"
  fi
  check_bin "ws CLI" "ws" "required" "Re-run with --core"
  if [[ -d "/Applications/DevTools.app" ]]; then
    ok "DevTools.app (/Applications/DevTools.app)"
  elif [[ -d "$HOME/Applications/DevTools.app" ]]; then
    ok "DevTools.app ($HOME/Applications/DevTools.app)"
  else
    fail "DevTools.app missing — Re-run with --core"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
  check_bin "jq" "jq" "required" "brew install jq"
  check_bin "ripgrep (rg)" "rg" "required" "brew install ripgrep"

  echo ""
  log "Frontend"
  if load_nvm && nvm ls 22 >/dev/null 2>&1; then
    ok "nvm + Node 22 ($(nvm version 22))"
  elif command -v node >/dev/null 2>&1; then
    warn "node $(node -v) found, but nvm Node 22 not detected — nvm install 22"
  else
    fail "Node 22 missing — Re-run with --frontend"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
  check_bin "yarn" "yarn" "required" "corepack enable"
  check_bin "volta" "volta" "optional" "brew install volta"

  echo ""
  log "Backend & Cloud"
  check_bin "jenv" "jenv" "required" "brew install jenv"
  if command -v jenv >/dev/null 2>&1; then
    local jenv_versions_out jver
    jenv_versions_out="$(jenv versions --bare 2>/dev/null || true)"
    for jver in 11 17 21; do
      if grep -Eq "^(openjdk64-|zulu64-)?${jver}(\.|$)" <<< "$jenv_versions_out"; then
        ok "JDK $jver registered in jenv"
      else
        warn "JDK $jver not registered in jenv — brew install openjdk@${jver} && jenv add ..."
      fi
    done
  fi
  check_bin "gradle" "gradle" "required" "brew install gradle"
  check_bin "docker" "docker" "required" "brew install --cask docker-desktop"
  check_app "Docker Desktop" "/Applications/Docker.app" "required" "brew install --cask docker-desktop"
  check_bin "psql" "psql" "required" "brew install postgresql@14 libpq"
  check_bin "aws CLI" "aws" "required" "brew install awscli"
  if [[ -f "$HOME/.aws/config" ]] && grep -q "stag-codeartifact-token-profile" "$HOME/.aws/config"; then
    ok "AWS SSO profiles present in ~/.aws/config"
  else
    warn "AWS SSO profiles missing in ~/.aws/config — Re-run with --backend"
  fi
  check_bin "grpcurl" "grpcurl" "optional" "brew install grpcurl"
  check_bin "yq" "yq" "optional" "brew install yq"
  check_bin "kubectl" "kubectl" "optional" "brew install kubernetes-cli"
  check_bin "ngrok" "ngrok" "optional" "brew install --cask ngrok"

  echo ""
  log "AI & Codebase Graph"
  check_bin "python3" "python3" "required" "brew install python@3.12"
  check_bin "pipx" "pipx" "required" "brew install pipx"
  check_bin "codebase-memory-mcp" "codebase-memory-mcp" "required" "npm install -g codebase-memory-mcp"
  check_bin "code-review-graph" "code-review-graph" "optional" "pipx install code-review-graph"
  check_bin "opencode" "opencode" "optional" "brew install opencode"
  check_bin "claude" "claude" "optional" "brew install --cask claude-code"
  check_bin "codex" "codex" "optional" "brew install --cask codex"
  check_bin "pi" "pi" "optional" "npm install -g @earendil-works/pi-coding-agent"

  echo ""
  log "GUI Apps"
  check_app "iTerm2" "/Applications/iTerm.app" "optional" "brew install --cask iterm2"
  check_app "Pritunl" "/Applications/Pritunl.app" "optional" "brew install --cask pritunl"
  if [[ -d "/Applications/IntelliJ IDEA.app" ]]; then
    ok "IntelliJ IDEA (/Applications/IntelliJ IDEA.app)"
  else
    check_app "IntelliJ IDEA CE" "/Applications/IntelliJ IDEA CE.app" "optional" "brew install --cask intellij-idea-ce"
  fi
  check_app "DBeaver" "/Applications/DBeaver.app" "optional" "brew install --cask dbeaver-community"
  check_app "Postman" "/Applications/Postman.app" "optional" "brew install --cask postman"
  check_app "Cursor" "/Applications/Cursor.app" "optional" "brew install --cask cursor"
  check_app "VS Code" "/Applications/Visual Studio Code.app" "optional" "brew install --cask visual-studio-code"
  check_app "OpenCode Desktop" "/Applications/OpenCode.app" "optional" "brew install --cask opencode-desktop"

  echo ""
  if [[ $VERIFY_FAILURES -eq 0 ]]; then
    ok "All required checks passed."
  else
    fail "$VERIFY_FAILURES required check(s) failed."
  fi
}

if $VERIFY_ONLY; then
  run_verify
  if [[ $VERIFY_FAILURES -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers for safe, idempotent installation
# ---------------------------------------------------------------------------
ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools already installed"
    return 0
  fi
  log "Installing Xcode Command Line Tools..."
  if $DRY_RUN; then
    echo "  [dry-run] xcode-select --install (interactive GUI prompt)"
    return 0
  fi
  xcode-select --install || true
  echo "Waiting for Xcode Command Line Tools installation to complete..."
  until xcode-select -p >/dev/null 2>&1; do
    sleep 5
  done
  ok "Xcode Command Line Tools installed"
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew already installed ($(command -v brew))"
    return 0
  fi
  if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
    ok "Homebrew loaded from $HOMEBREW_PREFIX/bin/brew"
    return 0
  fi
  log "Installing Homebrew..."
  if $DRY_RUN; then
    echo "  [dry-run] NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    return 0
  fi
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
  ok "Homebrew installed"
}

brew_install_formula() {
  local pkg="$1"
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    ok "brew formula already installed: $pkg"
  else
    log "Installing formula: $pkg"
    run_cmd brew install "$pkg"
  fi
}

brew_install_cask() {
  local cask="$1"
  local expected_app="${2:-}"
  if [[ -n "$expected_app" && -d "$expected_app" ]]; then
    ok "App already present: $expected_app (skipping cask $cask)"
    return 0
  fi
  if brew list --cask "$cask" >/dev/null 2>&1; then
    ok "brew cask already installed: $cask"
  else
    log "Installing cask: $cask"
    run_cmd brew install --cask "$cask"
  fi
}

ensure_zshrc_block() {
  local zshrc="$HOME/.zshrc"
  local marker="# >>> multiplier-dev setup >>>"
  if [[ -f "$zshrc" ]] && grep -Fq "$marker" "$zshrc"; then
    ok "~/.zshrc already contains multiplier-dev shell block"
    return 0
  fi
  log "Appending guarded multiplier-dev shell init block to ~/.zshrc (preserving existing content)..."
  if $DRY_RUN; then
    echo "  [dry-run] append $marker block to $zshrc"
    return 0
  fi
  touch "$zshrc"
  cat >> "$zshrc" <<'EOF'

# >>> multiplier-dev setup >>>
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:${HOMEBREW_PREFIX:-/opt/homebrew}/opt/libpq/bin:${HOMEBREW_PREFIX:-/opt/homebrew}/opt/postgresql@14/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
if [[ -s "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/nvm/nvm.sh" ]]; then
  . "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/nvm/nvm.sh"
fi
if command -v jenv >/dev/null 2>&1; then
  export PATH="$HOME/.jenv/bin:$PATH"
  eval "$(jenv init -)"
fi
# <<< multiplier-dev setup <<<
EOF
  ok "Updated ~/.zshrc"
}

install_devtools_and_ws() {
  log "Installing DevTools.app and ws CLI from GitHub Releases ($REPO_SLUG)..."
  local user_bin="$HOME/.local/bin"
  local app_target="/Applications/DevTools.app"
  if [[ ! -w "/Applications" ]]; then
    app_target="$HOME/Applications/DevTools.app"
  fi

  if $DRY_RUN; then
    echo "  [dry-run] curl -fsSL $RELEASE_BASE_URL/DevTools.zip -> extract to $app_target"
    echo "  [dry-run] curl -fsSL $RELEASE_BASE_URL/ws-darwin-arm64.gz -> gunzip to $user_bin/ws"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"

  # Download and install DevTools.app (never touches ~/workspaces, ~/.cache/ws, ~/.config/ws, ~/.llm-usage-*)
  if curl -fsSL "$RELEASE_BASE_URL/DevTools.zip" -o "$tmpdir/DevTools.zip"; then
    ditto -xk "$tmpdir/DevTools.zip" "$tmpdir/extracted"
    if [[ -d "$tmpdir/extracted/DevTools.app" ]]; then
      pkill -f "DevTools.app/Contents/MacOS/DevTools" 2>/dev/null || true
      sleep 1
      mkdir -p "$(dirname "$app_target")"
      rm -rf "$app_target"
      mv "$tmpdir/extracted/DevTools.app" "$app_target"
      xattr -cr "$app_target" 2>/dev/null || true
      ok "Installed $app_target"
    else
      warn "DevTools.app not found inside DevTools.zip"
    fi
  else
    warn "Failed to download DevTools.zip from $RELEASE_BASE_URL"
  fi

  # Download and install ws CLI
  mkdir -p "$user_bin"
  if [[ "$ARCH" != "arm64" ]]; then
    warn "Release binary ws-darwin-arm64.gz targets Apple Silicon (arm64); build locally on x86_64 via ./bin/bundle.sh --install"
  elif curl -fsSL "$RELEASE_BASE_URL/ws-darwin-arm64.gz" -o "$tmpdir/ws.gz"; then
    gunzip -c "$tmpdir/ws.gz" > "$user_bin/ws"
    chmod +x "$user_bin/ws"
    xattr -cr "$user_bin/ws" 2>/dev/null || true
    ok "Installed $user_bin/ws"
  else
    warn "Failed to download ws-darwin-arm64.gz from $RELEASE_BASE_URL"
  fi

  rm -rf "$tmpdir"
  mkdir -p "$HOME/workspaces"
}

ensure_aws_sso_profiles() {
  local aws_dir="$HOME/.aws"
  local aws_cfg="$aws_dir/config"
  if $DRY_RUN; then
    echo "  [dry-run] Ensure staging & prod CodeArtifact SSO sections exist in $aws_cfg"
    return 0
  fi
  mkdir -p "$aws_dir"
  chmod 700 "$aws_dir"
  touch "$aws_cfg"
  chmod 600 "$aws_cfg"

  if ! grep -Fq "[profile stag-codeartifact-token-profile]" "$aws_cfg"; then
    cat >> "$aws_cfg" <<'EOF'

[profile stag-codeartifact-token-profile]
sso_session = stag-codeartifact-token-profile
sso_account_id = 027283923462
sso_role_name = stg-global-tech-dev-access
EOF
    ok "Added [profile stag-codeartifact-token-profile] to ~/.aws/config"
  else
    ok "AWS profile stag-codeartifact-token-profile already configured"
  fi

  if ! grep -Fq "[sso-session stag-codeartifact-token-profile]" "$aws_cfg"; then
    cat >> "$aws_cfg" <<'EOF'

[sso-session stag-codeartifact-token-profile]
sso_start_url = https://usemultiplier-sso.awsapps.com/start
sso_region = ap-southeast-1
sso_registration_scopes = sso:account:access
EOF
    ok "Added [sso-session stag-codeartifact-token-profile] to ~/.aws/config"
  fi

  if ! grep -Fq "[profile prod-codeartifact-token-profile]" "$aws_cfg"; then
    cat >> "$aws_cfg" <<'EOF'

[profile prod-codeartifact-token-profile]
sso_session = prod-codeartifact-token-profile
sso_account_id = 778085304246
sso_role_name = prd-global-tech-dev-access
EOF
    ok "Added [profile prod-codeartifact-token-profile] to ~/.aws/config"
  else
    ok "AWS profile prod-codeartifact-token-profile already configured"
  fi

  if ! grep -Fq "[sso-session prod-codeartifact-token-profile]" "$aws_cfg"; then
    cat >> "$aws_cfg" <<'EOF'

[sso-session prod-codeartifact-token-profile]
sso_start_url = https://usemultiplier-sso.awsapps.com/start
sso_region = ap-southeast-1
sso_registration_scopes = sso:account:access
EOF
    ok "Added [sso-session prod-codeartifact-token-profile] to ~/.aws/config"
  fi
}

# ---------------------------------------------------------------------------
# Phase Execution
# ---------------------------------------------------------------------------
log "Starting Multiplier Mac bootstrap (arch=$ARCH, dry_run=$DRY_RUN)"

ensure_xcode_clt
ensure_homebrew

if $DO_CORE; then
  log "Phase: Core & DevTools"
  for formula in git gh ripgrep openssl@3; do
    brew_install_formula "$formula"
  done
  command -v jq >/dev/null 2>&1 && ok "jq already available ($(command -v jq))" || brew_install_formula "jq"
  command -v curl >/dev/null 2>&1 && ok "curl already available ($(command -v curl))" || brew_install_formula "curl"
  install_devtools_and_ws
  ensure_zshrc_block
fi

if $DO_FRONTEND; then
  log "Phase: Frontend (Node 22 + Yarn + Volta)"
  brew_install_formula "nvm"
  brew_install_formula "volta"
  if $DRY_RUN; then
    echo "  [dry-run] mkdir -p \"$NVM_DIR\" && nvm install 22 && nvm alias default 22 && corepack enable"
  else
    mkdir -p "$NVM_DIR"
    load_nvm || true
    if command -v nvm >/dev/null 2>&1; then
      if ! nvm ls 22 >/dev/null 2>&1; then
        nvm install 22
      else
        ok "Node 22 already installed in nvm"
      fi
      nvm use 22 >/dev/null
      nvm alias default 22 >/dev/null || true
      corepack enable >/dev/null 2>&1 || true
      ok "Node $(node -v) + Corepack ready"
    else
      warn "nvm not loaded in current shell; open a new shell and run: nvm install 22 && corepack enable"
    fi
  fi
fi

if $DO_BACKEND; then
  log "Phase: Backend & Cloud (Java 11/17/21 + jenv + Docker + Postgres + AWS)"
  for formula in jenv openjdk@11 openjdk@17 openjdk@21 gradle postgresql@14 libpq grpcurl yq; do
    brew_install_formula "$formula"
  done
  command -v kubectl >/dev/null 2>&1 && ok "kubectl already available ($(command -v kubectl))" || brew_install_formula "kubernetes-cli"
  command -v aws >/dev/null 2>&1 && ok "aws CLI already available ($(command -v aws))" || brew_install_formula "awscli"
  brew_install_cask "docker-desktop" "/Applications/Docker.app"
  brew_install_cask "ngrok" ""

  if $DRY_RUN; then
    echo "  [dry-run] Register openjdk@11, openjdk@17, openjdk@21 in jenv"
  elif command -v jenv >/dev/null 2>&1; then
    mkdir -p "$HOME/.jenv/versions"
    for jdk_ver in 11 17 21; do
      jdk_home="$HOMEBREW_PREFIX/opt/openjdk@${jdk_ver}/libexec/openjdk.jdk/Contents/Home"
      if [[ -d "$jdk_home" ]]; then
        jenv add "$jdk_home" >/dev/null 2>&1 || true
      fi
    done
    if [[ "$(jenv global 2>/dev/null || echo system)" == "system" ]]; then
      jenv global 21 >/dev/null 2>&1 || true
    fi
    ok "jenv configured ($(jenv versions --bare 2>/dev/null | tr '\n' ' '))"
  fi

  ensure_aws_sso_profiles
fi

if $DO_AI; then
  log "Phase: AI Agents & Codebase Graph"
  command -v python3 >/dev/null 2>&1 && ok "python3 already available ($(command -v python3))" || brew_install_formula "python@3.12"
  brew_install_formula "pipx"
  command -v opencode >/dev/null 2>&1 && ok "opencode already available ($(command -v opencode))" || brew_install_formula "opencode"
  command -v claude >/dev/null 2>&1 && ok "claude already available ($(command -v claude))" || brew_install_cask "claude-code" ""
  command -v codex >/dev/null 2>&1 && ok "codex already available ($(command -v codex))" || brew_install_cask "codex" ""

  if $DRY_RUN; then
    echo "  [dry-run] pipx ensurepath && pipx install code-review-graph"
    echo "  [dry-run] npm install -g codebase-memory-mcp @earendil-works/pi-coding-agent"
  else
    pipx ensurepath >/dev/null 2>&1 || true
    if command -v code-review-graph >/dev/null 2>&1; then
      ok "code-review-graph already installed"
    else
      pipx install code-review-graph || warn "code-review-graph install failed"
    fi

    # Ensure Node 22 npm is active for global MCP/agent installs
    load_nvm >/dev/null 2>&1 || true
    if ! command -v npm >/dev/null 2>&1; then
      brew_install_formula "nvm"
      mkdir -p "$NVM_DIR"
      load_nvm >/dev/null 2>&1 || true
      if command -v nvm >/dev/null 2>&1; then
        nvm install 22 >/dev/null 2>&1 || true
        nvm use 22 >/dev/null 2>&1 || true
      fi
    elif command -v nvm >/dev/null 2>&1; then
      nvm use 22 >/dev/null 2>&1 || true
    fi
    if command -v npm >/dev/null 2>&1; then
      if command -v codebase-memory-mcp >/dev/null 2>&1; then
        ok "codebase-memory-mcp already installed"
      else
        npm install -g codebase-memory-mcp || warn "codebase-memory-mcp install failed"
      fi
      if command -v pi >/dev/null 2>&1; then
        ok "pi already installed"
      else
        npm install -g @earendil-works/pi-coding-agent || warn "pi install failed"
      fi
    else
      warn "npm not found; run with --frontend first to install Node 22 for MCP/AI tools"
    fi

    if [[ ! -f "$HOME/.llm-usage-config" ]]; then
      printf '%s\n' "$GATEWAY_DEFAULT_URL" > "$HOME/.llm-usage-config"
      ok "Initialized ~/.llm-usage-config -> $GATEWAY_DEFAULT_URL"
    fi
  fi
fi

if $DO_APPS; then
  log "Phase: Optional Desktop GUI Apps"
  brew_install_cask "iterm2" "/Applications/iTerm.app"
  brew_install_cask "pritunl" "/Applications/Pritunl.app"
  brew_install_cask "intellij-idea-ce" "/Applications/IntelliJ IDEA CE.app"
  brew_install_cask "dbeaver-community" "/Applications/DBeaver.app"
  brew_install_cask "postman" "/Applications/Postman.app"
  brew_install_cask "cursor" "/Applications/Cursor.app"
  brew_install_cask "visual-studio-code" "/Applications/Visual Studio Code.app"
  brew_install_cask "opencode-desktop" "/Applications/OpenCode.app"
fi

if ! $DRY_RUN; then
  run_verify || true
fi

echo ""
printf '%sManual Steps Remaining (one-time per machine)%s\n' "$C_BOLD" "$C_RESET"
echo "  1. Open a new terminal (or run: source ~/.zshrc)"
echo "  2. Authenticate GitHub:      gh auth login && gh auth setup-git"
echo "  3. Authenticate AWS SSO:     aws sso login --profile stag-codeartifact-token-profile"
echo "                               aws sso login --profile prod-codeartifact-token-profile"
echo "  4. Start Docker Desktop:     open -a Docker"
echo "  5. Import Pritunl VPN profile (if accessing internal DBs/services)"
echo "  6. Open DevTools.app and paste your LiteLLM gateway key in LLM Usage"
echo "  7. Run final check:          ws doctor"
