#!/usr/bin/env bash
# Tests emering of one or multiple ebuilds, installs dependencies first
# Takes the path to an ebuild or a list of ebuild paths as argument(s)
# Sources ebuild specific config from ./packages/<category>/<PN>.conf and
# ./packages/<category>/<P>.conf if those files exist
# Depends on qatom from app-portage/portage-utils
set -e

if [ "${DEBUG}" = True ]; then
  set -x
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <ebuild category>/<ebuild name>/<ebuild filename>.ebuild [<second ebuild category>/<second ebuild name>/<second ebuild filename>.ebuild]" >&2
  exit 1
fi

# Enable binpkg-multi-instance mainly for keeping binpkgs built with different USE flags
# Disable news messages from portage as well as the IPC, network and PID sandbox to get rid of the
# "Unable to unshare: EPERM" messages without requiring the container to be run in privileged mode
# Disable rsync output
export FEATURES="binpkg-multi-instance -news -ipc-sandbox -network-sandbox -pid-sandbox"
export PORTAGE_RSYNC_EXTRA_OPTS="-q"

# Ensure we use dev-lang/rust-bin
echo "dev-lang/rust" > /etc/portage/package.mask

# Show emerge info for troubleshooting purposes
emerge --info

# Update @world, to fix issues with out of date gentoo/stage3-amd64 images
# Workaround for bug https://bugs.gentoo.org/723352
emerge --quiet-build --buildpkg --usepkg sys-libs/libcap
emerge --quiet-build --buildpkg --usepkg --update --changed-use --deep --with-bdeps=y @world

# Emerge utilities/tools used by this script
emerge -q --buildpkg --usepkg app-portage/portage-utils

# Set portage's distdir to /tmp/distfiles
# This is a workaround for a bug in portage/git-r3 where git-r3 can't
# create the distfiles/git-r3 directory when no other distfiles have been
# downloaded by portage first, which happens when using binary packages
# https://bugs.gentoo.org/481434
export DISTDIR="/tmp/distfiles"

# Setup overlay
mkdir -p /etc/portage/repos.conf
cat > /etc/portage/repos.conf/localrepo.conf <<EOF
[audio-overlay]
location = /usr/local/portage
EOF

# Emerge the ebuilds in a clean stage3
EBUILD_PATHS=("${@}")
for EBUILD_PATH in "${EBUILD_PATHS[@]}"
do
  echo "Emerging ${EBUILD_PATH}"
  EBUILD_FILENAME=$(basename "${EBUILD_PATH}" ".ebuild")
  EBUILD_CATEGORY="${EBUILD_PATH%%/*}"
  EBUILD="${EBUILD_CATEGORY}/${EBUILD_FILENAME}"

  # Source ebuild specific env vars
  unset ACCEPT_KEYWORDS
  unset USE
  PKG_CATEGORY=$(qatom -F "%{CATEGORY}" ${EBUILD})
  PKG_NAME=$(qatom -F "%{PN}" ${EBUILD})
  PKG_FULL_NAME=$(qatom -F "%{PF}" ${EBUILD})
  # Source versionless config
  if [ -f "./tests/resources/packages/${PKG_CATEGORY}/${PKG_NAME}.conf" ]; then
    source "./tests/resources/packages/${PKG_CATEGORY}/${PKG_NAME}.conf"
  fi
  # Source version specific config
  if [ -f "./tests/resources/packages/${PKG_CATEGORY}/${PKG_FULL_NAME}.conf" ]; then
    source "./tests/resources/packages/${PKG_CATEGORY}/${PKG_FULL_NAME}.conf"
  fi

  # Emerge dependencies first
  echo "Emerging dependencies"
  emerge --quiet-build --buildpkg --usepkg --onlydeps --autounmask=y --autounmask-continue=y "=${PKG_CATEGORY}/${PKG_FULL_NAME}"

  # Emerge the ebuild itself
  echo "Emerging ${EBUILD}"
  emerge -v "=${PKG_CATEGORY}/${PKG_FULL_NAME}"

  # Unmerge ebuild in case we're emerging multiple ebuilds to prevent blocking other ebuilds
  if (( ${#EBUILD_PATHS[@]} > 1 )); then
    emerge -c "=${PKG_CATEGORY}/${PKG_FULL_NAME}"
  fi
done
