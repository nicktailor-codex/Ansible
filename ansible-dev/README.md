# research-cluster Ansible

Codifies the cluster build for the 4-node Slurm cluster (cpu01 + 3 GPU nodes).

## Layout
```
/home/ntailor/ansible-dev/
├── ansible.cfg          ← project-local config (auto-loaded here)
├── inventory/hosts.ini  ← 4 nodes, grouped
├── group_vars/          ← shared variables (all.yml etc.)
├── host_vars/           ← per-host overrides
├── playbooks/           ← entry points (e.g. site.yml, base.yml)
└── roles/               ← reusable components (base/, slurm/, pyxis/, ...)
```

## Run
```bash
cd /home/ntailor/ansible-dev
ansible all -m ping
ansible-playbook playbooks/site.yml --check     # dry-run first
```
