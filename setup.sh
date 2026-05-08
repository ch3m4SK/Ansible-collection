#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_BIN="$SCRIPT_DIR/.venv/bin/ansible-playbook"

if [ ! -f "$ANSIBLE_BIN" ]; then
    echo "ansible-playbook not found at $ANSIBLE_BIN"
    exit 1
fi

if ! command -v gum &>/dev/null; then
    echo "gum not installed. Run: brew install gum"
    exit 1
fi

gum style \
    --foreground 212 --border-foreground 212 --border double \
    --align center --width 50 --margin "1 2" \
    "Ansible Machine Setup"

# 1. Connection details
IP=$(gum input --placeholder "IP or hostname (e.g. 192.168.1.100)")
[ -z "$IP" ] && exit 0

USER=$(gum input --placeholder "SSH user" --value "chema")
[ -z "$USER" ] && exit 0

# 2. Check connectivity
if ! gum spin --spinner dot --title "Checking $IP:22..." -- bash -c "nc -z -w 5 '$IP' 22"; then
    gum style --foreground 196 "Port 22 not reachable on $IP"
    exit 1
fi
gum style --foreground 82 "Port 22 reachable"

# 3. Select roles
SELECTED=$(gum choose --no-limit \
    --header "Select roles (space = select, enter = confirm):" \
    "initial_setup" \
    "docker_install" \
    "github_runner")

if [ -z "$SELECTED" ]; then
    gum style --foreground 196 "No roles selected."
    exit 1
fi

TAGS=$(echo "$SELECTED" | tr '\n' ',' | sed 's/,$//')

# 4. Run ansible
echo ""
gum style --foreground 244 "ansible-playbook -i \"$IP,\" site.yml --tags $TAGS"
echo ""

"$ANSIBLE_BIN" \
    -i "$IP," \
    "$SCRIPT_DIR/site.yml" \
    --tags "$TAGS" \
    -e "ansible_user=$USER" \
    --ask-pass \
    --ask-become-pass

ANSIBLE_EXIT=$?

if [ $ANSIBLE_EXIT -ne 0 ]; then
    gum style --foreground 196 "Ansible failed (exit $ANSIBLE_EXIT)"
    exit $ANSIBLE_EXIT
fi

gum style --foreground 82 "Ansible completed successfully"

# 5. Add to SSH config
echo ""
if gum confirm "Add $IP to ~/.ssh/config?"; then
    NAME=$(gum input --placeholder "Host alias (e.g. ax-supabase)")
    if [ -n "$NAME" ]; then
        cat >> ~/.ssh/config <<EOF

Host $NAME
    HostName $IP
    User $USER
    IdentityFile ~/.ssh/id_ed25519
    Port 22
    AddKeysToAgent yes
    UseKeychain yes
EOF
        gum style --foreground 82 "Added '$NAME' to ~/.ssh/config"
    fi
fi
