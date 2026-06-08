# spack-lmod role

Provides the cluster's user-facing module system.

- **Lmod** (apt-installed on every node) — gives users the `module load/avail/list` commands.
- **Spack** (cloned to `/software/spack`, NetApp shared) — source-based package manager. Builds tools natively, generates Lmod modulefiles automatically.

## Why this exists

Burdentesting + similar workloads run inside Docker containers (Pyxis/Enroot). That's the right path for heavy, reproducible workloads.

But sometimes users need **side-by-side minor versions** of one tool — e.g. plink 1.9 vs 2.0, or two R versions for a legacy vs current pipeline. Rebuilding the Docker image for every minor version is painful. Modules let users `module load plink/1.9` and `module unload plink && module load plink/2.0` without touching containers.

This role installs the infrastructure. Actual package builds are admin-driven.

## What the role does

- `apt install lmod` on all 4 nodes
- `apt install` Spack build deps (git, build-essential, gfortran, python3, etc.) on cpu01
- Clones Spack v0.22.4 to `/software/spack`
- Drops site config (`/software/spack/etc/spack/config.yaml`, `modules.yaml`)
- Drops the `burden` environment (`/software/spack/var/spack/environments/burden/spack.yaml`) — pinned to versions matching the burdentesting Docker image
- Drops `/etc/profile.d/spack.sh` on all 4 nodes so users get `spack` and `module` in their PATH at login

## What the role does NOT do

- Run any `spack install`. Building the burden stack is hours of compilation. Doing that inside `ansible-playbook` would be wrong — it would block the playbook for hours and isn't idempotent in any useful sense.

## Admin: building the burden stack (one-time, hours)

After the role has been applied, on cpu01:

```bash
sudo spack-build-burden
```

That kicks off the full build inside a detached tmux session named `spack-build` and returns to your shell. Inside the session it sources Spack, registers compilers, activates the `burden` environment, concretizes, runs `spack install`, and regenerates the Lmod modulefiles at the end. Build survives SSH disconnects.

```bash
# Watch progress
tmux attach -t spack-build

# Detach (build keeps running)
Ctrl-b  then  d

# Check whether the session is still alive
tmux ls
```

If you'd rather drive it manually:

```bash
. /software/spack/share/spack/setup-env.sh
spack compiler find
spack env activate burden
spack concretize --reuse
spack install
spack module lmod refresh --delete-tree -y
```

Verify on any node:
```bash
module avail
# Should see regenie/3.4.1, plink/1.9-20231211, plink2/2.00a5.11, etc.
module load regenie
regenie --version
```

## Adding a new version side-by-side

```bash
ssh cpu01
sudo -i
. /software/spack/share/spack/setup-env.sh
spack env activate burden

# Edit /software/spack/var/spack/environments/burden/spack.yaml,
# add e.g.:  - regenie@3.5.0
spack concretize --reuse
spack install
spack module lmod refresh --delete-tree -y
```

Users instantly see `module avail regenie` showing both 3.4.1 and 3.5.0.

## Files

| File | Purpose |
|---|---|
| `defaults/main.yml` | Paths, version pins, apt package lists |
| `tasks/main.yml` | The role's tasks |
| `files/burden-stack.yaml` | Spack environment file — pinned burdentesting versions |
| `files/spack-profile.sh` | `/etc/profile.d/spack.sh` — sources setup-env, makes `module` find spack's modulefiles |
| `templates/config.yaml.j2` | Spack site config (install_tree, build_stage, build_jobs) |
| `templates/modules.yaml.j2` | Lmod generation rules (flat layout, exclude noise) |

## Bumping Spack itself

Change `spack_version` in `defaults/main.yml` and re-apply. Existing installs under `/software/spack/opt/spack/` persist — the bump only affects future `spack install` invocations.
