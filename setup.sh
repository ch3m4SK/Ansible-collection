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

# 1. Build host list from SSH config + manual option
KNOWN_HOSTS=$(grep "^Host " ~/.ssh/config 2>/dev/null | awk '{print $2}' | grep -v '[*?]' | sort)

if [ -n "$KNOWN_HOSTS" ]; then
    MENU_OPTIONS=$(printf "%s\n" "$KNOWN_HOSTS" "[ Enter manually ]")
else
    MENU_OPTIONS="[ Enter manually ]"
fi

MENU_ARRAY=()
while IFS= read -r line; do
    MENU_ARRAY+=("$line")
done <<< "$MENU_OPTIONS"

while true; do
    SELECTION=$(gum choose --no-limit \
        --header "Select target hosts (space = select, enter = confirm):" \
        "${MENU_ARRAY[@]}") || true
    [ -n "$SELECTION" ] && break
    gum style --foreground 196 "Select at least one host."
done

# 2. Handle manual entry
MANUAL_HOST=""
if echo "$SELECTION" | grep -q "\[ Enter manually \]"; then
    MANUAL_HOST=$(gum input --placeholder "IP or hostname")
fi

FINAL_HOSTS=$(echo "$SELECTION" | grep -v "\[ Enter manually \]" || true)
[ -n "$MANUAL_HOST" ] && FINAL_HOSTS="${FINAL_HOSTS:+$FINAL_HOSTS$'\n'}$MANUAL_HOST"
FINAL_HOSTS=$(echo "$FINAL_HOSTS" | grep -v '^$')

[ -z "$FINAL_HOSTS" ] && exit 0

HOST_COUNT=$(echo "$FINAL_HOSTS" | grep -c '.')

# 3. Check connectivity
echo ""
ALL_OK=true
while IFS= read -r host; do
    # Resolve real IP via SSH config (HostName), fall back to host itself
    REAL_HOST=$(ssh -G "$host" 2>/dev/null | awk '/^hostname / {print $2}')
    [ -z "$REAL_HOST" ] && REAL_HOST="$host"
    if gum spin --spinner dot --title "Checking $host:22..." -- bash -c "nc -z -w 5 '$REAL_HOST' 22"; then
        gum style --foreground 82 "$host reachable"
    else
        gum style --foreground 196 "$host — port 22 not reachable"
        ALL_OK=false
    fi
done <<< "$FINAL_HOSTS"
$ALL_OK || exit 1

# 4. Resolve user + key auth + role detection
KEY_AUTH=false
INSTALLED_ROLES=""
REMOTE_USER="chema"

if [ "$HOST_COUNT" -eq 1 ]; then
    SINGLE_HOST=$(echo "$FINAL_HOSTS" | head -1)

    # Resolve user from SSH config if it's a named host
    SSH_CONFIG_USER=$(ssh -G "$SINGLE_HOST" 2>/dev/null | awk '/^user / {print $2}')
    if [[ ! "$SINGLE_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ -n "$SSH_CONFIG_USER" ]; then
        REMOTE_USER="$SSH_CONFIG_USER"
        gum style --foreground 244 "User from SSH config: $REMOTE_USER"
    else
        REMOTE_USER=$(gum input --placeholder "SSH user" --value "chema")
        [ -z "$REMOTE_USER" ] && exit 0
    fi

    # Try key-based auth
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$REMOTE_USER@$SINGLE_HOST" "exit" 2>/dev/null; then
        KEY_AUTH=true
        gum spin --spinner dot --title "Detecting installed roles..." -- sleep 0.3

        INSTALLED_ROLES=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$SINGLE_HOST" bash <<'REMOTE'
            installed=""
            (sudo -n true 2>/dev/null || [ -s "$HOME/.ssh/authorized_keys" ]) && installed="$installed,initial_setup"
            command -v docker &>/dev/null && installed="$installed,docker_install"
            systemctl list-units --type=service --no-legend 2>/dev/null | grep -q "actions.runner" && installed="$installed,github_runner"
            systemctl is-active --quiet zabbix-agent2 2>/dev/null && installed="$installed,zabbix_agent"
            echo "${installed#,}"
REMOTE
        )
        gum style --foreground 244 "Installed: ${INSTALLED_ROLES:-none}"
    else
        gum style --foreground 220 "No key auth — will use password"
    fi
else
    # Multi-host: ask user once, skip detection
    REMOTE_USER=$(gum input --placeholder "SSH user for all hosts" --value "chema")
    [ -z "$REMOTE_USER" ] && exit 0
    gum style --foreground 244 "Running on $HOST_COUNT hosts — role detection skipped"
fi

# 5. Select roles (mark installed but don't pre-select)
label_role() {
    local role=$1
    echo "$INSTALLED_ROLES" | grep -q "$role" && echo "$role [installed]" || echo "$role"
}

echo ""
while true; do
    SELECTED=$(gum choose --no-limit \
        --header "Space = select/deselect, enter = confirm. [installed] = already present:" \
        "$(label_role initial_setup)" \
        "$(label_role docker_install)" \
        "$(label_role github_runner)" \
        "$(label_role zabbix_agent)") || true
    [ -n "$SELECTED" ] && break
    gum style --foreground 196 "Select at least one role."
done

TAGS=$(echo "$SELECTED" | sed 's/ \[installed\]//' | tr '\n' ',' | sed 's/,$//')
INVENTORY=$(echo "$FINAL_HOSTS" | tr '\n' ',' | sed 's/,$/,/')

# 6. Build ansible flags
INITIAL_SETUP_INSTALLED=$(echo "$INSTALLED_ROLES" | grep -c "initial_setup" || true)
ANSIBLE_FLAGS=(-i "$INVENTORY" "$SCRIPT_DIR/site.yml" --tags "$TAGS" -e "ansible_user=$REMOTE_USER")

if [ "$KEY_AUTH" = false ]; then
    ANSIBLE_FLAGS+=(--ask-pass --ask-become-pass)
elif [ "$INITIAL_SETUP_INSTALLED" -eq 0 ]; then
    ANSIBLE_FLAGS+=(--ask-become-pass)
fi

# 7. Run ansible
echo ""
gum style --foreground 244 "ansible-playbook -i \"$INVENTORY\" site.yml --tags $TAGS"
echo ""

"$ANSIBLE_BIN" "${ANSIBLE_FLAGS[@]}"

ANSIBLE_EXIT=$?
[ $ANSIBLE_EXIT -ne 0 ] && { gum style --foreground 196 "Ansible failed (exit $ANSIBLE_EXIT)"; exit $ANSIBLE_EXIT; }
gum style --foreground 82 "Ansible completed successfully"

# 8. Offer to add new manual host to SSH config
if [ -n "$MANUAL_HOST" ] && ! grep -qs "HostName $MANUAL_HOST" ~/.ssh/config && ! grep -qs "^Host $MANUAL_HOST$" ~/.ssh/config; then
    echo ""
    if gum confirm "Add $MANUAL_HOST to ~/.ssh/config?"; then
        NAME=$(gum input --placeholder "Host alias (e.g. ax-supabase)")
        if [ -n "$NAME" ]; then
            cat >> ~/.ssh/config <<EOF

Host $NAME
    HostName $MANUAL_HOST
    User $REMOTE_USER
    IdentityFile ~/.ssh/id_ed25519
    Port 22
    AddKeysToAgent yes
    UseKeychain yes
EOF
            gum style --foreground 82 "Added '$NAME' to ~/.ssh/config"
        fi
    fi
fi
