# `storage` role

Codifies the cluster's persistent storage state: NetApp NFS mounts,
NFSv4 ID mapping, and the local `/scratch` bootstrap area.

## What it does

- Creates mount points for `/software` and `/mnt/<team-volume>` (5 total)
- Mounts NetApp NFSv4 volumes via `ansible.posix.mount` (handles both fstab
  entry and active mount state in one shot)
- Sets `Domain = insmed.local` in `/etc/idmapd.conf` (matches AD realm)
- Triggers `nfsidmap -c` handler when idmapd config changes
- Creates `/scratch/cluster-software/` (sticky-bit world-writable)

## What it does NOT do
- `nfs-common` install — handled by the `base` role (run base first)
- Policy routing for the dedicated NetApp NIC — out of scope (network config,
  not storage); would be a separate `network` role
- NFSv4 ACLs / chowns to AD groups — out of scope, waits on storage's
  `v4-id-domain` flip + IT delivering AD team groups; future `permissions` role
- Per-user `/scratch/$USER/enroot/{cache,data,runtime,tmp}` — these belong in
  a Slurm Prolog (create-on-job-launch), not in idempotent provisioning

## Variables

See `defaults/main.yml`. Key knobs:
- `storage_nfs_mounts` — list of `{src, path}` dicts (edit to add/remove volumes)
- `storage_nfs_opts` — NFS mount options
- `storage_idmapd_domain` — must match NetApp SVM `-v4-id-domain`

## Run

```bash
cd /home/ntailor/ansible-dev
ansible-playbook playbooks/storage.yml --check --diff    # dry-run first
ansible-playbook playbooks/storage.yml                   # apply
```

A clean run on the current cluster state should produce `changed=0` per node.

## Outstanding storage-side dependencies

The mounts currently show `nobody:nogroup` ownership because NetApp's SVM
`-v4-id-domain` hasn't been set to `insmed.local`. Once storage applies:
```
vserver nfs modify -vserver <svm> -v4-id-domain insmed.local
```
ownership resolves to real AD identities and the per-folder ACL model
becomes useful.
