#!/system/bin/sh
# AndroPI Linux container launcher, shipped as libbox.so and linked as `box`.
#
#   box                 interactive shell in the container
#   box -c 'apt ...'    run a command (this is how pi calls its shell)
#   box python3 x.py    run a program
#
# The app's home (and so the workspace, ~/.ssh and ~/.gitconfig) is mounted at
# the same path inside, so files and git credentials are shared both ways.
# Paths come from the environment AgentRuntime sets up.

R="$ANDROPI_ROOTFS"
if [ -z "$R" ] || { [ ! -e "$R/bin/sh" ] && [ ! -L "$R/bin/sh" ]; }; then
  echo "box: the Linux container is not installed. Install it in AndroPI under Settings > Linux container." >&2
  exit 127
fi

H="${ANDROPI_HOME:-$HOME}"
export PROOT_LOADER="$ANDROPI_PROOT_LOADER"
export PROOT_TMP_DIR="${TMPDIR:-$H}"
cwd="$PWD"
case "$cwd" in "$H"*|/storage/*|/sdcard/*) ;; *) cwd="$H" ;; esac

# Shared storage (Download, Documents...) when the user granted file access,
# at its usual paths, so sessions opened on a phone folder work inside too.
SHARED=""
[ -r /storage/emulated/0 ] && SHARED="-b /storage -b /storage/emulated/0:/sdcard"

# Android-side settings that would break glibc programs inside. proot itself
# still needs LD_LIBRARY_PATH (for libtalloc); the guest drops it via env -u.
unset LD_PRELOAD GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_CONFIG_NOSYSTEM PAGER GIT_PAGER
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Debian has bash; Alpine only busybox sh until `apk add bash`.
SH=/bin/sh
{ [ -e "$R/bin/bash" ] || [ -L "$R/bin/bash" ] || [ -e "$R/usr/bin/bash" ]; } && SH=/bin/bash
export HOME="$H" USER=root LOGNAME=root SHELL="$SH" TMPDIR=/tmp LANG=C.UTF-8
export TERM="${TERM:-xterm-256color}" DEBIAN_FRONTEND=noninteractive
# The phone's trusted CAs (incl. user-installed ones), mounted below.
CA=/etc/ssl/andropi-ca.pem
export SSL_CERT_FILE="$CA" NODE_EXTRA_CA_CERTS="$CA" GIT_SSL_CAINFO="$CA" CURL_CA_BUNDLE="$CA" REQUESTS_CA_BUNDLE="$CA"

[ "$#" -eq 0 ] && set -- -l
set -- /usr/bin/env -u LD_LIBRARY_PATH "$SH" "$@"

exec "$ANDROPI_PROOT" --kill-on-exit --link2symlink -0 -r "$R" \
  -b /dev -b /proc -b /sys -b "$R/tmp:/dev/shm" \
  -b "$H" -b "$ANDROPI_FILES/cacerts.pem:$CA" $SHARED \
  -w "$cwd" "$@"
