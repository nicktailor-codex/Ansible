# Spack + Lmod Guide — Insmed Research Cluster

Companion to [Slurm-Cheatsheet.md](Slurm-Cheatsheet.md). Covers how to use modules in jobs and how admins add/swap versions.

---

## TL;DR

```bash
module avail                          # see what's installed
module load regenie/3.4.1             # add a tool to your shell
module load regenie plink2 bcftools r # several at once
which regenie                         # /software/spack/opt/spack/regenie-3.4.1-.../bin/regenie
module list                           # what's loaded right now
module unload regenie                 # remove it
module purge                          # unload everything
```

`/software/spack/` is NetApp-shared, so the same modules are visible on **every node** (cpu01, gpu01, gpu02, cgpu01) with no per-node action.

---

## What's installed (the `burden` stack)

Mirrors the `egardner413/mrcepid-burdentesting` Docker image so the same tool versions are available natively for fine-grained version swapping.

| Tool      | Version          | Notes |
|-----------|------------------|-------|
| `regenie` | 3.4.1            | Pre-built static gz binary from upstream release |
| `plink`   | 1.9-beta6.27     | Functionally equivalent to image's 1.90b7.2 (perpetual-beta line) |
| `plink2`  | 2.00a5.11        | Exact image match |
| `bcftools`| 1.20             | Exact image match |
| `samtools`| 1.20             | Exact image match |
| `htslib`  | 1.20             | Exact image match — shared dep of bcftools/samtools |
| `gcta`    | 1.94.1           | Image had 1.94.4 (only available on Yang Lab CN host, blocked from cpu01) |
| `r`       | 4.3.3            | Exact image match. Base R only — user installs CRAN/Bioconductor packages themselves |
| `python`  | 3.11.9           | Image had 3.8.10 (EOL in Spack); 3.11.9 is the supported modern equivalent |
| `jq`      | 1.7.1            | Utility (JSON parsing) |

All packages installed under `/software/spack/opt/spack/<name>-<version>-<hash>/`.

---

## Using modules in Slurm jobs

**Critical:** Slurm runs batch scripts in **non-login** shells by default. `/etc/profile.d/lmod.sh` (which sets up the `module` command) is **not** sourced. You must do one of:

1. Add `-l` to the shebang: `#!/bin/bash -l`  ← simplest, recommended
2. Or explicitly: `source /etc/profile.d/lmod.sh` near the top of your script

Without one of these, you'll get `module: command not found`.

### Template — sbatch script using modules

Copy this and adapt:

```bash
#!/bin/bash -l
#SBATCH -J myjob
#SBATCH -A informatics
#SBATCH -p cpu
#SBATCH -c 8
#SBATCH --mem=32G
#SBATCH -t 4:00:00
#SBATCH -o myjob-%j.out
#SBATCH --mail-user=ntailor --mail-type=END,FAIL

# Load tools — autoload pulls dependencies automatically
module load regenie/3.4.1 plink2/2.00a5.11 bcftools/1.20

# Verify (optional — handy when debugging)
echo "Using: $(which regenie)"
regenie --version 2>&1 | head -1

# Your real work
cd /mnt/humgen/my-analysis
regenie --step 2 \
        --bgen ukbb/chr1.bgen \
        --phenoFile phenos/binary.tsv \
        --bt --firth --approx \
        --out /scratch/$USER/burden_chr1
```

### Or — load specific versions side-by-side

```bash
module load regenie/3.4.1         # pin to 3.4.1
regenie ...                       # uses 3.4.1
module unload regenie
module load regenie/3.5.0         # swap to 3.5.0 (once admin builds it)
regenie ...                       # now uses 3.5.0
```

`module load <name>` without a version picks the default. To see what `default` resolves to:
```bash
module avail regenie
```

### Comparison — modules vs container

| When to use | Pattern |
|---|---|
| **Reproducibility** matters, frozen toolchain, prod pipeline | `--container-image=docker://egardner413/mrcepid-burdentesting:latest` (the existing approach) |
| **Version flexibility** — swap one tool's version, test a patch | `module load regenie/3.5.0` |
| **Light work** — quick one-off analysis, prototyping | `module load ...`, no container overhead |
| **Heavy custom dependencies** beyond the burden stack | Container (build once, reuse) |

Both can coexist. You can even bind-mount the Spack tree into a container if you need a specific module-built tool inside a pipeline:
```
sbatch --container-image=... --container-mounts=/software/spack:/software/spack ...
```

---

## Admin: managing versions

All admin commands run on **cpu01 only** (the build host). Output appears on every node automatically because `/software/spack` is NetApp-shared.

Always work inside the burden environment so changes are tracked in its `spack.yaml`:

```bash
sudo -i
source /software/spack/share/spack/setup-env.sh
spack env activate burden
```

### Add a new version of an existing tool

Example: add regenie 3.5.0 alongside 3.4.1.

```bash
# Edit the env spec list
$EDITOR /software/spack/var/spack/environments/burden/spack.yaml
# Add a line:    - regenie@3.5.0

spack concretize -f                              # recompute graph
spack install                                    # build only the new piece
spack module lmod refresh --delete-tree -y       # regenerate modulefiles
```

Users immediately see both `regenie/3.4.1` and `regenie/3.5.0` in `module avail`.

**Note for custom packages (regenie, samtools/bcftools/gcta backports):** these live in `/software/spack/var/spack/repos/insmed/packages/`. Adding a new version means editing the `package.py` to add a new `version(...)` line with the upstream URL + SHA. See the existing entries for the pattern.

### Remove a version

```bash
spack uninstall regenie@3.4.1
spack module lmod refresh --delete-tree -y
```

Users who had it loaded should `module purge && module load regenie/<remaining-version>`.

### Add a brand-new tool

If the tool exists in Spack's built-in repo:
```bash
# Inside the burden env
$EDITOR /software/spack/var/spack/environments/burden/spack.yaml
# Add:    - vcftools@0.1.16

spack concretize -f
spack install
spack module lmod refresh --delete-tree -y
```

If it's not in Spack's repo, write a custom package in our `insmed` overlay:
```
/software/spack/var/spack/repos/insmed/packages/<tool>/package.py
```
Model on `regenie/package.py` (binary install) or `samtools/package.py` (subclass of builtin). See [the role's README](../../ansible-dev/roles/spack-lmod/README.md).

### Bump Spack itself

```bash
# In ansible-dev: edit spack_version in roles/spack-lmod/defaults/main.yml
ansible-playbook playbooks/spack-lmod.yml --tags spack
```

The role updates the spack git tree to the new tag. Existing installs under `/software/spack/opt/spack/` persist — only the package definitions update. Subsequent `spack install` invocations use the new package recipes.

### Wipe + rebuild from scratch

If something gets out of whack:
```bash
sudo rm -rf /software/spack/opt/spack/*           # all installed binaries
sudo rm -rf /software/spack/share/spack/lmod/*    # all modulefiles
# Optional — wipe per-user build stage caches:
sudo rm -rf /scratch/*/spack-stage

# Then re-trigger the build
sudo spack-build-burden    # uses tmux, attach with `tmux attach -t spack-build`
```

The Spack git tree (`/software/spack/`) and the burden env config (`/software/spack/var/spack/environments/burden/spack.yaml`) are NOT touched. Only build output.

---

## Module commands quick reference

```bash
# Discovery
module avail                          # all available modules
module avail regenie                  # versions of one tool
module spider                         # all packages (including hidden deps)
module spider regenie                 # detailed info about a tool
module overview                       # count of modules per name

# Loading
module load regenie                   # default version (highest)
module load regenie/3.4.1             # specific version
module load regenie plink2 bcftools   # multiple at once
ml regenie                            # `ml` is a shortcut for `module load`

# Inspecting
module list                           # what's loaded
module list -t                        # terse (one per line)
module show regenie                   # what env vars a module sets

# Removing
module unload regenie                 # remove one
module purge                          # remove all

# Save / restore your own load-sets
module save mywork                    # remember current load-set
module restore mywork                 # bring it back later
module savelist                       # see your saved sets
```

---

## Troubleshooting

**`module: command not found` inside a Slurm job**
- Add `-l` to your shebang (`#!/bin/bash -l`) — Slurm's non-login shells don't source `/etc/profile.d/lmod.sh` automatically.

**`module avail` shows nothing on a compute node**
- `/software` not mounted? Check `mount | grep /software`. Should auto-mount; if not, file an ops ticket.

**`The following dependent module(s) are not currently loaded: curl/...`**
- Cosmetic warning. The tools you loaded work correctly — `which regenie` returns a real path and `regenie --version` runs. Lmod prints this because we hide implicit deps from `module avail` but autoload still loads them. Ignore.

**A tool version I want isn't in `module avail`**
- Ask an admin to add it (see "Add a new version" above). Takes minutes to hours depending on the tool.

**Slow first `module load` on a node**
- Lmod caches per-user under `~/.lmod.d/`. First load on a node has to scan the modulepath. Subsequent loads are fast.

---

## Layer cake — how it all fits

```
┌──────────────────────────────────────────────────────────────┐
│  USER:  module load regenie/3.4.1                            │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────┐
│  LMOD:  reads modulefiles from /software/spack/share/spack/  │
│         lmod/.../Core/regenie/3.4.1.lua                      │
│         autoloads dependency modules (htslib, zlib, ...)     │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────┐
│  PATH/LD_LIBRARY_PATH:  /software/spack/opt/spack/regenie-   │
│                         3.4.1-.../bin                        │
│                         (NetApp-shared, same on all nodes)   │
└──────────────────────────────────────────────────────────────┘
```

`module avail` and the binaries themselves are *the same file tree on every node*, served from NetApp. Build once on cpu01, use everywhere.
