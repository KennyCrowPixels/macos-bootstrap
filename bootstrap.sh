#!/bin/bash
#
# bootstrap.sh
#
# Provision an offline local administrator account and skip the macOS Setup
# Assistant from the Recovery OS Terminal on an Apple Silicon Mac.
#
# Tested target: macOS Sonoma (14) / Sequoia (15) on Apple Silicon (M1/M1 Max).
# Run from:      Recovery OS -> Utilities -> Terminal, as root.
#
# USE ONLY on hardware you own or are authorized to administer.
#
# POSIX bash 3.2 compatible (the version shipped in Recovery OS).

set -u

# ---------------------------------------------------------------------------
# Pretty output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_INFO="$(printf '\033[1;34m')"
    C_OK="$(printf '\033[1;32m')"
    C_WARN="$(printf '\033[1;33m')"
    C_ERR="$(printf '\033[1;31m')"
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

info()  { printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
err()   { printf '%s[x]%s %s\n' "$C_ERR"  "$C_RESET" "$*" 1>&2; }
die()   { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
printf '\n'
info "macOS offline admin bootstrapper"
info "================================"

if [ "$(id -u)" -ne 0 ]; then
    die "This script must run as root. In Recovery Terminal you already are; otherwise re-run with sudo."
fi

# ---------------------------------------------------------------------------
# 1. Detect the mounted writable Data volume
# ---------------------------------------------------------------------------
DATA_VOL=""
for candidate in "/Volumes/Macintosh HD - Data" "/Volumes/Data"; do
    if [ -d "$candidate/private/var/db/dslocal/nodes/Default" ]; then
        DATA_VOL="$candidate"
        break
    fi
done

if [ -z "$DATA_VOL" ]; then
    warn "Could not auto-detect the Data volume at the usual locations."
    info "Volumes currently mounted:"
    ls -1 /Volumes 2>/dev/null | sed 's/^/      - /'
    printf '%sEnter the full path to your Data volume (e.g. /Volumes/YourName - Data): %s' "$C_INFO" "$C_RESET"
    read -r DATA_VOL
    DATA_VOL="${DATA_VOL%/}"
fi

[ -n "$DATA_VOL" ] || die "No Data volume path provided."
[ -d "$DATA_VOL" ] || die "Path does not exist: $DATA_VOL"

DSLOCAL_NODE="$DATA_VOL/private/var/db/dslocal/nodes/Default"
[ -d "$DSLOCAL_NODE" ] || die "Not a valid macOS Data volume (missing $DSLOCAL_NODE)"

# Confirm the volume is writable (not a read-only snapshot mount).
if ! touch "$DATA_VOL/.bootstrap_write_test" 2>/dev/null; then
    die "Data volume is not writable: $DATA_VOL. Make sure you mounted it read/write in Disk Utility."
fi
rm -f "$DATA_VOL/.bootstrap_write_test" 2>/dev/null

ok "Using Data volume: $DATA_VOL"

# ---------------------------------------------------------------------------
# 2. Prompt for the new account details
# ---------------------------------------------------------------------------
printf '\n'
info "New administrator account details (press Enter to accept defaults)."

printf '%sUsername  [admin]: %s' "$C_INFO" "$C_RESET"
read -r username
[ -n "$username" ] || username="admin"

printf '%sFull name [Administrator]: %s' "$C_INFO" "$C_RESET"
read -r full_name
[ -n "$full_name" ] || full_name="Administrator"

# Read password without echo; confirm it.
password=""
while :; do
    printf '%sPassword  [password]: %s' "$C_INFO" "$C_RESET"
    stty -echo 2>/dev/null
    read -r password
    stty echo 2>/dev/null
    printf '\n'

    if [ -z "$password" ]; then
        password="password"
        warn "Using default password: password"
        break
    fi

    printf '%sConfirm password: %s' "$C_INFO" "$C_RESET"
    stty -echo 2>/dev/null
    read -r password_confirm
    stty echo 2>/dev/null
    printf '\n'

    if [ "$password" = "$password_confirm" ]; then
        break
    fi
    warn "Passwords did not match. Try again."
done

# Basic sanity on the username.
case "$username" in
    *[!a-zA-Z0-9._-]*) die "Username contains invalid characters: $username" ;;
esac

HOME_DIR="$DATA_VOL/Users/$username"
USER_PATH="/Local/Default/Users/$username"

printf '\n'
info "About to create this account:"
printf '      username : %s\n' "$username"
printf '      full name: %s\n' "$full_name"
printf '      UID/GID  : 501 / 20 (admin)\n'
printf '      shell    : /bin/zsh\n'
printf '      home     : /Users/%s  (on %s)\n' "$username" "$DATA_VOL"
printf '%sProceed? [y/N]: %s' "$C_WARN" "$C_RESET"
read -r confirm
case "$confirm" in
    y|Y|yes|YES) ;;
    *) die "Aborted by user." ;;
esac

# ---------------------------------------------------------------------------
# 3. Provision the local administrator user via dscl -f against the node
# ---------------------------------------------------------------------------
DSCL="dscl -f $DSLOCAL_NODE localonly"

printf '\n'
info "Creating user record at $USER_PATH ..."

# If a record already exists, warn the user.
if dscl -f "$DSLOCAL_NODE" localonly -read "$USER_PATH" >/dev/null 2>&1; then
    warn "A user record already exists at $USER_PATH; updating it."
fi

dscl -f "$DSLOCAL_NODE" localonly -create "$USER_PATH" \
    || die "Failed to create user record."
dscl -f "$DSLOCAL_NODE" localonly -create "$USER_PATH" RealName "$full_name" \
    || die "Failed to set RealName."
dscl -f "$DSLOCAL_NODE" localonly -create "$USER_PATH" UniqueID 501 \
    || die "Failed to set UniqueID."
dscl -f "$DSLOCAL_NODE" localonly -create "$USER_PATH" PrimaryGroupID 20 \
    || die "Failed to set PrimaryGroupID."
dscl -f "$DSLOCAL_NODE" localonly -create "$USER_PATH" UserShell /bin/zsh \
    || die "Failed to set UserShell."
dscl -f "$DSLOCAL_NODE" localonly -create "$USER_PATH" NFSHomeDirectory "/Users/$username" \
    || die "Failed to set NFSHomeDirectory."

info "Setting the account password ..."
dscl -f "$DSLOCAL_NODE" localonly -passwd "$USER_PATH" "$password" \
    || die "Failed to set password."

ok "User record created."

# ---------------------------------------------------------------------------
# Append the user to the admin group (GroupMembership and GroupMembers)
# ---------------------------------------------------------------------------
info "Granting administrator rights ..."
ADMIN_GROUP="/Local/Default/Groups/admin"

# GroupMembership stores the short name.
if dscl -f "$DSLOCAL_NODE" localonly -read "$ADMIN_GROUP" GroupMembership 2>/dev/null \
        | tr ' ' '\n' | grep -qx "$username"; then
    info "User already present in admin GroupMembership."
else
    dscl -f "$DSLOCAL_NODE" localonly -append "$ADMIN_GROUP" GroupMembership "$username" \
        || warn "Could not append to GroupMembership."
fi

# GroupMembers stores the user's GeneratedUID; fetch it and append.
USER_GUID="$(dscl -f "$DSLOCAL_NODE" localonly -read "$USER_PATH" GeneratedUID 2>/dev/null | awk '{print $2}')"
if [ -n "$USER_GUID" ]; then
    if dscl -f "$DSLOCAL_NODE" localonly -read "$ADMIN_GROUP" GroupMembers 2>/dev/null \
            | tr ' ' '\n' | grep -qx "$USER_GUID"; then
        info "User GUID already present in admin GroupMembers."
    else
        dscl -f "$DSLOCAL_NODE" localonly -append "$ADMIN_GROUP" GroupMembers "$USER_GUID" \
            || warn "Could not append to GroupMembers."
    fi
else
    warn "Could not determine GeneratedUID; skipped GroupMembers."
fi

ok "Administrator rights granted."

# ---------------------------------------------------------------------------
# Create the home directory and set ownership to 501:20
# ---------------------------------------------------------------------------
info "Creating home directory at $HOME_DIR ..."
mkdir -p "$HOME_DIR" || die "Failed to create home directory."

# Seed the standard user subdirectories if a skeleton is available.
for sub in Desktop Documents Downloads Library Movies Music Pictures Public; do
    mkdir -p "$HOME_DIR/$sub"
done

chown -R 501:20 "$HOME_DIR" || warn "Could not chown home directory."
ok "Home directory ready."

# ---------------------------------------------------------------------------
# 4. Skip the Setup Assistant
# ---------------------------------------------------------------------------
printf '\n'
info "Disabling the initial Setup Assistant ..."
DB_DIR="$DATA_VOL/private/var/db"
mkdir -p "$DB_DIR"
touch "$DB_DIR/.AppleSetupDone"            || warn "Could not touch .AppleSetupDone"
touch "$DB_DIR/.AppleDiagnosticsSetupDone" || warn "Could not touch .AppleDiagnosticsSetupDone"
ok "Setup Assistant will be skipped on next boot."

# ---------------------------------------------------------------------------
# 5. Append local sinkhole entries to /etc/hosts
# ---------------------------------------------------------------------------
printf '\n'
info "Adding sinkhole host entries ..."
HOSTS_FILE="$DATA_VOL/private/etc/hosts"

if [ ! -f "$HOSTS_FILE" ]; then
    warn "hosts file not found at $HOSTS_FILE; creating a new one."
    printf '127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1\tlocalhost\n' > "$HOSTS_FILE"
fi

SINKHOLE_HOSTS="deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com acmdm.apple.com"
added_any=0
for host in $SINKHOLE_HOSTS; do
    if grep -qE "[[:space:]]$host([[:space:]]|\$)" "$HOSTS_FILE" 2>/dev/null; then
        info "Already present: $host"
    else
        printf '0.0.0.0\t%s\n' "$host" >> "$HOSTS_FILE" \
            && { ok "Sinkholed: $host"; added_any=1; } \
            || warn "Could not add: $host"
    fi
done
[ "$added_any" -eq 1 ] && ok "hosts file updated." || info "hosts file already up to date."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf '\n'
ok "All done."
info "Summary:"
printf '      account : %s (%s), admin, UID 501\n' "$username" "$full_name"
printf '      home    : /Users/%s\n' "$username"
printf '      volume  : %s\n' "$DATA_VOL"
printf '\n'
info "Next steps:"
printf '      1. Type: reboot\n'
printf '      2. At the login window, sign in as "%s".\n' "$username"
printf '\n'
