#!/usr/bin/env bash
# Build ONLYOFFICE-based DesktopEditors for linux_64 from this clone.
# Linux counterpart of build-onlyoffice-x64.bat.
#
#   bash build_tools/build-onlyoffice-x64.sh
#
# Every bootstrap step is idempotent, so re-running the script resumes instead
# of redoing the toolchain download. Nothing outside this clone and
# build_tools/tools/linux is modified except through explicit sudo steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LINUX_TOOLS="${SCRIPT_DIR}/tools/linux"

# Overridable knobs.
BRANDING="${BRANDING:-typsastra}"
MODULE="${MODULE:-desktop}"
PLATFORM="${PLATFORM:-linux_64}"
UPDATE="${UPDATE:-0}"
SYSROOT="${SYSROOT:-1}"
QMAKE_BUILD_JOBS="${QMAKE_BUILD_JOBS:-$(nproc)}"
CMAKE_VERSION="${CMAKE_VERSION:-3.30.0}"
# qmake.py reads this from the environment to size its "-j".
export QMAKE_BUILD_JOBS

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found in PATH."
}

# Only x86-64 is supported here; arm64/aarch64 cross builds need a different path.
[ "$(uname -m)" = "x86_64" ] || die "This script builds linux_64 on x86_64 only (found $(uname -m))."
[ -d "${SCRIPT_DIR}/scripts" ] || die "build_tools is not a usable checkout (no scripts/ directory)."

log "System packages (apt, node.js, npm)"
if [ -f "${LINUX_TOOLS}/packages_complete" ]; then
  echo "Already installed."
else
  # deps.py drives sudo itself, so authenticate once up front. Run this step by
  # hand if you prefer not to let the script call sudo.
  require_cmd sudo
  sudo -v
  (cd "${LINUX_TOOLS}" && python3 ./deps.py)
fi

log "Bundled Python"
if [ -x "${LINUX_TOOLS}/python3/bin/python3" ]; then
  echo "Already bootstrapped."
else
  (cd "${LINUX_TOOLS}" && ./python.sh)
fi
[ -x "${LINUX_TOOLS}/python3/bin/python3" ] || die "Bundled Python was not installed at ${LINUX_TOOLS}/python3."

# libheif 1.18.2 (core/Common/3dParty/heif) declares an old cmake_minimum_required
# that CMake 4 rejects, so pin a 3.x toolchain. Upstream cmake.sh installs 3.30.0
# into /opt via sudo; we keep it inside the checkout instead.
log "CMake ${CMAKE_VERSION}"
# The release tarball unpacks into cmake-<version>-linux-x86_64/, not the
# directory name upstream cmake.sh renames it to, so probe for bin/cmake.
find_cmake() {
  local cand
  for cand in "${LINUX_TOOLS}"/cmake-"${CMAKE_VERSION}"*; do
    if [ -x "${cand}/bin/cmake" ]; then
      echo "${cand}"
      return 0
    fi
  done
  return 1
}
CMAKE_HOME="$(find_cmake || true)"
if [ -z "${CMAKE_HOME}" ]; then
  archive="cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"
  (cd "${LINUX_TOOLS}" && wget -q "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${archive}" && tar -xzf "${archive}" && rm -f "${archive}")
  CMAKE_HOME="$(find_cmake || true)"
fi
[ -n "${CMAKE_HOME}" ] || die "CMake ${CMAKE_VERSION} was not unpacked under ${LINUX_TOOLS}."
export PATH="${CMAKE_HOME}/bin:${PATH}"
cmake --version | head -1

log "Qt 5.9.9 (prebuilt)"
if [ -x "${LINUX_TOOLS}/qt_build/Qt-5.9.9/gcc_64/bin/qmake" ]; then
  echo "Already fetched."
else
  (cd "${LINUX_TOOLS}" && python3 ./qt_binary_fetch.py amd64)
fi

log "Sysroot (ubuntu 16.04)"
if [ -d "${LINUX_TOOLS}/sysroot/ubuntu16-amd64-sysroot" ]; then
  echo "Already fetched."
else
  (cd "${LINUX_TOOLS}/sysroot" && python3 ./fetch.py amd64)
fi

# deploy_desktop.py reads these two asset trees; they are intentionally not
# submodules of this repository.
log "Asset repositories"
for repo in document-templates core-fonts; do
  if [ -d "${REPO_ROOT}/${repo}/.git" ]; then
    echo "${repo} already present."
  elif [ -d "${REPO_ROOT}/${repo}" ]; then
    echo "${repo} already present (not a git checkout, reusing it)."
  else
    git clone --depth 1 "https://github.com/ONLYOFFICE/${repo}.git" "${REPO_ROOT}/${repo}"
  fi
done

# UPDATE=0 keeps the submodule checkouts you already have instead of letting
# build_tools reset them to a branch.
log "configure.py"
configure_args=(
  --platform "${PLATFORM}"
  --module "${MODULE}"
  --update "${UPDATE}"
  --multiprocess 1
  --qt-dir "${LINUX_TOOLS}/qt_build/Qt-5.9.9"
)
if [ -n "${BRANDING}" ]; then
  configure_args+=(--branding "${BRANDING}" --branding-name "${BRANDING}")
fi
if [ "$(printf '%s' "${PLATFORM}" | cut -c1-5)" = "linux" ]; then
  configure_args+=(--sysroot "${SYSROOT}")
fi
(cd "${SCRIPT_DIR}" && python3 ./configure.py "${configure_args[@]}")

log "make.py (this takes a few hours on a cold tree)"
(cd "${SCRIPT_DIR}" && python3 ./make.py)

# ---------------------------------------------------------------------------
# Verification: the build only counts as done once the shipped binary exists,
# links cleanly, and actually starts.
# ---------------------------------------------------------------------------
APP_DIR="${SCRIPT_DIR}/out/${PLATFORM}/${BRANDING:-onlyoffice}/desktopeditors"
APP_BIN="${APP_DIR}/DesktopEditors"

log "Verifying ${APP_BIN}"
[ -x "${APP_BIN}" ] || die "Build completed without producing ${APP_BIN}."
file "${APP_BIN}" | sed 's/^/  /'

# The Qt xcb platform plugin is the one that resolves at startup, so a missing
# transitive library there shows up as a hard failure on launch.
for so in "${APP_DIR}/platforms/libqxcb.so" "${APP_BIN}"; do
  [ -e "${so}" ] || continue
  if ldd "${so}" 2>/dev/null | grep -q "not found"; then
    echo "Unresolved runtime dependencies in ${so}:" >&2
    ldd "${so}" | grep "not found" >&2
    die "The build produced a binary that cannot start."
  fi
done
echo "  All shared libraries resolve."

# Smoke-test from the application directory, the way it is meant to be started.
# Offscreen keeps this usable on a headless box; the result is informational,
# the checks above are the ones that fail the build.
echo "  Start-up check:"
(cd "${APP_DIR}" && QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=./ timeout 120 ./DesktopEditors --version 2>&1) | sed 's/^/    /' || true

log "Done: ${APP_BIN}"
echo "Run it with:  cd ${APP_DIR} && LD_LIBRARY_PATH=./ ./DesktopEditors"
