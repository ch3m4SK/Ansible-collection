# homelab-ansible

Ansible playbooks and roles to provision and configure self-hosted homelab machines.
Targets Debian/Ubuntu hosts and sets up a fully operational GitHub Actions self-hosted runner with Docker support.

## Table of contents

- [Requirements](#requirements)
- [Project structure](#project-structure)
- [Roles](#roles)
  - [initial\_setup](#initial_setup)
  - [docker\_install](#docker_install)
  - [github\_runner](#github_runner)
- [Quick start](#quick-start)
  - [1. Install dependencies](#1-install-dependencies)
  - [2. Configure inventory](#2-configure-inventory)
  - [3. Run the playbook](#3-run-the-playbook)
- [Running individual roles](#running-individual-roles)
- [Variables reference](#variables-reference)
- [CI — Ansible Lint](#ci--ansible-lint)

---

## Requirements

**Control node (your machine):**

| Tool | Version |
|------|---------|
| Python | >= 3.10 |
| Ansible | >= 10.0 |
| ansible-lint | >= 24.0 |

**Managed nodes:**

- Debian 11/12 or Ubuntu 20.04 / 22.04 / 24.04
- SSH access with a user that can `sudo`

---

## Project structure

```
.
├── ansible.cfg               # Ansible configuration
├── site.yml                  # Main playbook
├── inventory/
│   └── hosts                 # Host definitions and group vars
├── requirements.txt          # Python dependencies (ansible, ansible-lint)
├── requirements.yml          # Ansible collection dependencies
├── roles/
│   ├── initial_setup/        # Bootstrap user, SSH key, sudoers
│   ├── docker_install/       # Docker CE from official repo
│   ├── github_runner/        # GitHub Actions self-hosted runner
│   └── ask/                  # Internal helper: interactive prompts
└── .github/
    └── workflows/
        └── ansible-lint.yml  # CI pipeline
```

---

## Roles

### initial_setup

Bootstraps a fresh machine with a non-root user ready for passwordless SSH and sudo.

**What it does:**
- Installs `sudo` if missing
- Creates the target user with a home directory
- Adds the user to `sudoers.d` with `NOPASSWD:ALL`
- Deploys the SSH public key to `authorized_keys`

> Designed to run once on virgin machines. Requires `--ask-pass --ask-become-pass` on the first run.

---

### docker_install

Installs Docker CE from the official Docker APT repository.

**What it does:**
- Removes conflicting packages (`docker.io`, `podman-docker`, etc.)
- Adds the official Docker GPG key and APT repo
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Enables and starts the `docker` systemd service
- Adds specified users to the `docker` group

---

### github_runner

Installs, configures and registers a GitHub Actions self-hosted runner as a systemd service.

**What it does:**
- Installs system dependencies including `python3`, `python3-venv` and `python3-pip` (required for Ansible lint CI pipelines)
- Installs Node.js via NodeSource
- Downloads and extracts the Actions runner package
- Registers the runner against a repository or organisation (interactive if token/URL not provided)
- Installs the runner as a `systemd` service with Docker group access

---

## Quick start

### 1. Install dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure inventory

Edit `inventory/hosts` and set your machine's address and user:

```ini
[machines]
your-hostname-or-ip

[machines:vars]
ansible_user=youruser
ansible_python_interpreter=/usr/bin/python3
```

### 3. Run the playbook

**First run on a virgin machine** (no SSH cert, no sudoers configured yet):

```bash
ansible-playbook site.yml --ask-pass --ask-become-pass
```

**Subsequent runs** (SSH key already deployed):

```bash
ansible-playbook site.yml
```

The `github_runner` role will interactively ask for the repository URL and registration token if they are not provided as extra vars.

---

## Running individual roles

Use tags to run a single role without touching the rest:

```bash
# Bootstrap only
ansible-playbook site.yml --tags initial_setup

# Docker only
ansible-playbook site.yml --tags docker_install

# GitHub runner only — pass vars to skip interactive prompts
ansible-playbook site.yml --tags github_runner \
  --extra-vars "github_runner_url=https://github.com/org/repo github_runner_token=TOKEN"
```

---

## Variables reference

### initial_setup

| Variable | Default | Description |
|----------|---------|-------------|
| `initial_setup_user` | `{{ ansible_user }}` | User to create and configure |
| `initial_setup_ssh_pubkey_path` | `~/.ssh/id_ed25519.pub` | Local path to the SSH public key to deploy |

### docker_install

| Variable | Default | Description |
|----------|---------|-------------|
| `docker_install_users` | `["{{ ansible_user }}"]` | Users to add to the `docker` group |
| `docker_install_packages` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` | Packages to install |

### github_runner

| Variable | Default | Description |
|----------|---------|-------------|
| `github_runner_version` | `2.333.1` | Runner version to download |
| `github_runner_arch` | `linux-x64` | Runner architecture |
| `github_runner_checksum` | *(see defaults)* | SHA256 checksum for the runner tarball |
| `github_runner_user` | `{{ ansible_user }}` | System user that runs the runner service |
| `github_runner_install_dir` | `/home/{{ github_runner_user }}/actions-runner` | Installation directory |
| `github_runner_name` | `{{ inventory_hostname }}` | Runner name shown in GitHub |
| `github_runner_labels` | `""` | Comma-separated custom labels |
| `github_runner_node_version` | `20` | Node.js major version |
| `github_runner_url` | *(required, prompted if missing)* | Repository or organisation URL |
| `github_runner_token` | *(required, prompted if missing)* | Runner registration token from GitHub |

---

## CI — Ansible Lint

Every push and pull request to `main` runs `ansible-lint` on the self-hosted runner:

```
.github/workflows/ansible-lint.yml
```

The workflow creates a fresh Python virtualenv, installs dependencies from `requirements.txt` and collections from `requirements.yml`, then runs `ansible-lint` against the entire repository.
