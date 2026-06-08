# `base` role

Baseline that every cluster node needs, regardless of role (controller / compute / GPU).

## What it does

- Cluster `/etc/hosts` block (short + FQDN for cpu01, gpu01, gpu02, cgpu01)
- Required packages installed (`nfs-common`, `acl`, `nfs4-acl-tools`, `exim4`)
- Unwanted packages removed (`bsd-mailx`, `mailutils` — exim's sendmail is enough)
- `kernel.unprivileged_userns_clone = 1` (required for enroot)

## What it does NOT do
- Sudoers / NOPASSWD — handled separately (currently temporary; will be removed when build-out is done)
- NVIDIA driver holds — `nvidia` role
- NFS mounts — `storage` role
- Slurm config — `slurm` role
- Pyxis + Enroot — `pyxis-enroot` role
- exim smarthost configuration — `mail` role (waits on SMTP relay from IT)

## Variables

See `defaults/main.yml`. Override `base_packages_present` / `base_packages_absent` in
`group_vars/` if a subset of nodes needs different packages.

## Idempotency check

The role is written to be a no-op against the current cluster state. Validate with:
```
cd /home/ntailor/ansible-dev
ansible-playbook playbooks/base.yml --check --diff
```
A clean run shows `changed=0` per node.
