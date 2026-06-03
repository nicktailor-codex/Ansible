# Slurm Cheat Sheet — Insmed Research Cluster

Cluster: **research-cluster** (4 nodes — cpu01 controller + gpu01/gpu02/cgpu01 compute). Slurm 23.11.4.

Web dashboard: **http://10.174.16.55:5011/**

---

## At-a-glance — what's free?

```bash
cluster-status                   # custom helper, on every node — free cores/mem/GPU + queue depth
sinfo                            # default Slurm view (per-partition)
sinfo -N -l                      # per-node detail
squeue                           # running + pending jobs cluster-wide
squeue -u $USER                  # just my jobs
squeue --start                   # estimated start times for pending jobs
```

---

## Partitions

| Partition       | Nodes                    | Max walltime | Notes |
|-----------------|--------------------------|--------------|-------|
| `cpu` *(default)* | cpu01 (128c / 512G)    | 5 days       | CPU-only, default |
| `gpu01`         | gpu01 (64c / 256G / H200)| 5 days       | Heavy ML / FEP+ |
| `gpu02`         | gpu02 (64c / 256G / H200)| 5 days       | Heavy ML / FEP+ |
| `cgpu01`        | cgpu01 (64c / 256G / L4) | 2 days       | Light ML / inference |
| `interactive`   | cpu01 + cgpu01           | 8 hours      | Short jobs, high priority |
| `cpu-overflow`  | all 4 nodes              | 1 day        | CPU-only spill onto GPU nodes; cap 48 cores/node |

## QoS

| QoS      | Priority | Max wall | When to use |
|----------|----------|----------|-------------|
| `normal` | 0        | 5 days   | Default — all production work |
| `debug`  | 500      | 60 mins  | Interactive testing — jumps queue |

## GPUs

| Node    | GPU           | gres string         |
|---------|---------------|---------------------|
| gpu01   | H200 NVL 141G | `gpu:h200_nvl:1`    |
| gpu02   | H200 NVL 141G | `gpu:h200_nvl:1`    |
| cgpu01  | L4 24G        | `gpu:l4:1`          |

---

## Submitting jobs

### `sbatch` — batch script
```bash
sbatch myjob.sh                              # submit a script
sbatch --wrap='python train.py'              # one-liner, no script file
```

### Common flags

```bash
-J / --job-name=NAME           # name in squeue
-p / --partition=cpu           # which partition
-q / --qos=debug               # which QoS
-A / --account=informatics     # billing account (required by sacctmgr)
-n / --ntasks=4                # number of tasks (default 1)
-c / --cpus-per-task=8         # cores per task
--mem=32G                      # total memory (use --mem-per-cpu= for per-core)
-t / --time=04:00:00           # walltime — HH:MM:SS or D-HH:MM:SS
-o / --output=%x-%j.out        # stdout — %x=name, %j=jobid, %A=array, %a=array idx
-e / --error=%x-%j.err         # stderr
--gres=gpu:1                   # request 1 GPU (any type)
--gres=gpu:h200_nvl:1          # request a specific GPU type
-w / --nodelist=insiiukgpu01   # pin to a specific node
-d / --dependency=afterok:NNN  # wait for job NNN to succeed
--mail-user=you                # gets qualified to @insmed.com automatically
--mail-type=END,FAIL           # when to email
```

### Examples

```bash
# CPU-only, 16 cores, 4 hours, default partition
sbatch -n 16 -t 4:00:00 --wrap='snakemake -j 16'

# Spread CPU work onto GPU nodes (don't compete with GPU jobs)
sbatch -p cpu-overflow -n 32 -t 1-00:00:00 myjob.sh

# Interactive debug GPU session — 60 min cap
srun -p interactive -q debug --gres=gpu:1 --pty bash

# Production GPU training, 5-day cap, H200 specifically
sbatch -p gpu01 --gres=gpu:h200_nvl:1 -c 8 --mem=64G -t 5-00:00:00 train.sh

# Array job — 100 tasks, max 10 concurrent
sbatch --array=1-100%10 -t 30:00 array.sh    # use $SLURM_ARRAY_TASK_ID inside
```

### Containers (Pyxis + Enroot)

> ⚠️ **Minimum `--mem=3G` for any container job.** Pyxis builds an uncompressed SquashFS overlay during container start; peaks at ~2 GB RAM during the build. Below ~2.5 GB the build OOM-kills before your script runs. Symptom: `FAILED` with `ExitCode 0:53` and `Elapsed 00:00:01` (the elapsed timer doesn't include container setup, so the OOM looks instant in sacct).

```bash
# Minimum viable container job — note the 3G floor
sbatch --mem=3G --container-image=docker://ubuntu:24.04 --wrap='ls /'

# Cached image (saves the 2-5min pull on subsequent jobs — shared cache on /software)
sbatch --mem=3G --container-image=egardner413/mrcepid-burdentesting:latest myjob.sh

# Mount host paths into the container (works for /home, /mnt/*, /software, /scratch)
sbatch --mem=3G --container-image=... --container-mounts=/mnt/informatics:/data myjob.sh
```

### `srun` — interactive / inside an allocation
```bash
srun -p interactive -n 1 -c 4 --pty bash         # interactive shell
srun --jobid=NNN hostname                        # run inside existing alloc
```

### `salloc` — interactive allocation, multiple `srun` steps
```bash
salloc -p interactive --gres=gpu:1 -t 2:00:00    # grab the resources
srun hostname                                    # run things inside it
srun python -c 'import torch; print(torch.cuda.is_available())'
exit                                             # release the allocation
```

---

## Monitoring jobs

```bash
squeue -u $USER                              # my jobs
squeue -j NNN                                # one job
squeue -t RUNNING                            # only running
squeue -p gpu01                              # one partition

scontrol show job NNN                        # full job detail (resources, state, reason)
scontrol show node insiiukgpu01              # node detail
scontrol show partition cpu                  # partition detail

sacct -u $USER --starttime=today             # my completed jobs today
sacct -j NNN --format=JobID,State,ExitCode,Elapsed,MaxRSS,MaxVMSize
sacct -X --starttime=2026-05-25 --format=JobID,JobName,State,Elapsed,NodeList
```

## Job control

```bash
scancel NNN                                  # cancel one
scancel -u $USER                             # cancel ALL my jobs (careful)
scancel -t PENDING -u $USER                  # cancel only my pending
scontrol hold NNN                            # prevent from starting
scontrol release NNN                         # un-hold
scontrol requeue NNN                         # requeue a running/completed job
scontrol update jobid=NNN timelimit=2-00:00:00   # extend walltime
scontrol update jobid=NNN partition=cpu-overflow # move to a different partition (must be PENDING)
```

---

## State reasons (the `(REASON)` in squeue)

| Reason | Meaning |
|---|---|
| `Resources` | Waiting for cores/mem/GPU to free up |
| `Priority` | Another job is ahead in the queue |
| `Dependency` | Waiting on a prerequisite job |
| `JobHeldUser` | You held it with `scontrol hold` |
| `JobHeldAdmin` | Admin held it |
| `launch failed requeued held` | Slurm tried to launch, failed, requeued, then auto-held to prevent loop. **Release with `scontrol release NNN` or cancel.** |
| `QOSMaxWallDurationPerJobLimit` | Job's `--time` exceeds the QoS's max walltime |
| `PartitionTimeLimit` | Job's `--time` exceeds the partition's max walltime |
| `AssocGrpCPURunMinutesLimit` | Account/QoS limit on CPU·minutes hit |

`EnforcePartLimits=ALL` is on, so submit-time `--time` over either partition or QoS limit gets rejected immediately.

---

## Admin: partition access control

Use the `slurm-allow` helper (on every node) to manage `AllowGroups` on a partition without hand-editing slurm.conf:

```bash
slurm-allow show <partition>            # current AllowGroups
slurm-allow add <part> <ad-group>       # add a group — validates via getent first
slurm-allow remove <part> <ad-group>    # remove a group (refuses to empty list)
slurm-allow set <part> g1,g2,g3         # replace whole list at once
slurm-allow open <partition>            # back to AllowGroups=ALL
```

Examples:
```bash
slurm-allow add gpu01 HPC-CompChem            # only HPC-CompChem can use gpu01
slurm-allow add gpu01 HPC-HumanGent           # plus HPC-HumanGent
slurm-allow show gpu01                        # → HPC-CompChem,HPC-HumanGent
```

**Runtime-only.** Changes apply immediately via `scontrol update` but **revert on slurmctld restart or `ansible-playbook playbooks/slurm.yml`**. To persist, edit `~/ansible-dev/roles/slurm/files/slurm.conf` to match.

**Safety:** validates each group resolves via SSSD/AD before applying, so typos can't lock out a team. Also: once you set AllowGroups to a non-`ALL` value, non-member users (including the admin running the command, unless they're in the group) lose visibility of the partition in `scontrol show` — the helper uses sudo for reads so admins still see everything.

## Accounting tree

```
research (root)
├── bioinformatics
├── compchem
├── human_genetics
└── informatics       ← my default
```

Check yours: `sacctmgr show user $USER`

---

## Common patterns

### How much will my job actually get?
1. Run `cluster-status` first — shows free cores/mem/GPU per node and per partition.
2. Submit with `--test-only` to dry-run: `sbatch --test-only -p gpu01 --gres=gpu:1 myjob.sh`

### My job is PENDING forever — why?
```bash
scontrol show job NNN | grep -E 'JobState|Reason|StartTime'
```
The `Reason` tells you why. `StartTime` (if set) is the scheduler's estimate.

### Estimate when I'll start
```bash
squeue --start -j NNN
```

### Job died, what happened?
```bash
sacct -j NNN --format=JobID,State,ExitCode,Reason,DerivedExitCode    # exit codes
# Then look at the .out / .err files (or use --output= path)
```
Common: `OUT_OF_MEMORY`, `TIMEOUT`, `NODE_FAIL`, `CANCELLED+`.

### Cancel everything quickly
```bash
scancel -u $USER                  # all my jobs
scancel -u $USER -t PENDING       # only my pending
scancel --name=myjob              # by job name
```

---

## Gotchas specific to this cluster

- **`module load` in Slurm scripts requires `#!/bin/bash -l`** — Slurm's batch shells are non-login, so `/etc/profile.d/lmod.sh` doesn't auto-source and `module: command not found`. Add `-l` to your shebang, or explicitly `source /etc/profile.d/lmod.sh`. See [Spack-Lmod-Guide.md](Spack-Lmod-Guide.md) for the full module-system docs.
- **`--mem=3G` floor for container jobs.** Pyxis's SquashFS build during container start peaks at ~2 GB RAM. Anything less OOM-kills before your script runs (`ExitCode 0:53`, `Elapsed 00:00:01` — but the kill happens in stepd setup, not in your code). When in doubt, set `--mem=3G` minimum on every `--container-image=` job; bump higher based on what your actual workload needs.
- **No MPI** — `MaxNodes=1` on every partition. A single job can't span multiple nodes.
- **One GPU per GPU node** — `--gres=gpu:1` is the max per job. Multiple GPU jobs queue, they don't share a card.
- **No preemption** (`PreemptMode=OFF`) — a running job is never killed by a higher-priority job. It waits.
- **`/scratch/$USER/enroot/`** is created by the prolog on job launch — use it for container scratch/runtime, not `/tmp`.
- **`/software/enroot-cache/`** is the shared image cache (NetApp). First user to `--container-image=foo` pulls it; everyone else reuses.
- **Walltime defaults** are short (08:00:00 on cpu, 04:00:00 on gpu*, 02:00:00 on cgpu01/interactive). Specify `-t` if you want longer.
- **Email** auto-qualifies to `@insmed.com` if you pass `--mail-user=ntailor`. Bare local-part is fine.

---

## Typical workflows — copy/paste templates

Each example: the `sbatch` command + the script + how to check progress + how to know it worked.

---

### 1. Bioinformatics array job — one sample per task

500 samples, each runs `process_sample.sh` independently. 10 concurrent at a time so we don't flood I/O.

```bash
sbatch <<'EOF'
#!/bin/bash
#SBATCH -J samples
#SBATCH -A bioinformatics
#SBATCH -p cpu
#SBATCH --array=1-500%10
#SBATCH -c 4
#SBATCH --mem=16G
#SBATCH -t 2:00:00
#SBATCH -o logs/sample-%A_%a.out
#SBATCH --mail-user=ntailor --mail-type=END,FAIL

mkdir -p logs
SAMPLE=$(sed -n "${SLURM_ARRAY_TASK_ID}p" samples.txt)
echo "Processing $SAMPLE on $(hostname)"
./process_sample.sh "$SAMPLE"
EOF
```

**Check progress:**
```bash
squeue -u $USER --array                              # all 500 array tasks
squeue -j 12345 --array | grep RUNNING | wc -l       # how many running now
sacct -j 12345 --format=JobID,State,ExitCode | tail  # latest completed
ls logs/sample-12345_*.out | wc -l                   # output files appearing
```

**Verify it worked:**
```bash
sacct -j 12345 -X --format=JobID,State,ExitCode --noheader | awk '$2!="COMPLETED"'   # show only failures
```
Empty output = all 500 succeeded.

---

### 2. REGENIE burden test (containerised)

The canonical genetics job — uses `egardner413/mrcepid-burdentesting` from Docker Hub via Pyxis.

```bash
sbatch <<'EOF'
#!/bin/bash
#SBATCH -J burden
#SBATCH -A human_genetics
#SBATCH -p cpu
#SBATCH -c 16
#SBATCH --mem=64G
#SBATCH -t 1-00:00:00
#SBATCH --container-image=docker://egardner413/mrcepid-burdentesting:latest
#SBATCH --container-mounts=/mnt/humgen:/data,/scratch/$USER:/out
#SBATCH -o burden-%j.out
#SBATCH --mail-user=ntailor --mail-type=END,FAIL

regenie --step 2 \
        --bgen /data/ukbb/chr1.bgen \
        --phenoFile /data/phenos/binary.tsv \
        --bt --firth --approx \
        --out /out/burden_chr1
EOF
```

**Check progress:**
```bash
squeue -j 12345                                 # state + node
tail -f burden-12345.out                        # live output
scontrol show job 12345 | grep -E 'NodeList|RunTime|TimeLimit'
```

**Verify it worked:**
```bash
sacct -j 12345 --format=JobID,State,ExitCode,Elapsed,MaxRSS
# State=COMPLETED, ExitCode=0:0 → success
ls /scratch/$USER/burden_chr1*.regenie          # output files written
```

---

### 3. Snakemake orchestrator — one Slurm job, internally fans out

The orchestrator stays in one Slurm allocation; Snakemake uses local cores to dispatch rule shards.

```bash
sbatch <<'EOF'
#!/bin/bash
#SBATCH -J snakemake
#SBATCH -A informatics
#SBATCH -p cpu-overflow
#SBATCH -n 32
#SBATCH --mem=128G
#SBATCH -t 1-00:00:00
#SBATCH --container-image=docker://snakemake/snakemake:stable
#SBATCH --container-mounts=/mnt/informatics:/data,/scratch/$USER:/out
#SBATCH -o snakemake-%j.out

cd /data/my-pipeline
snakemake --cores $SLURM_NTASKS --rerun-incomplete --directory /out
EOF
```

> Why `cpu-overflow`? 32 cores fits within a single GPU-node's 48-core cap, freeing cpu01 for other work.
>
> No system-installed snakemake on the cluster — the example uses the official `snakemake/snakemake` container via Pyxis, consistent with the container-first pattern.

**Check progress:**
```bash
grep -E "rules to run|Finished job" snakemake-12345.out | tail
```

---

### 4. GPU training — single H200

Pin to the H200 explicitly so it doesn't land on the L4.

```bash
sbatch <<'EOF'
#!/bin/bash
#SBATCH -J train
#SBATCH -A compchem
#SBATCH -p gpu01
#SBATCH --gres=gpu:h200_nvl:1
#SBATCH -c 16
#SBATCH --mem=128G
#SBATCH -t 3-00:00:00
#SBATCH --container-image=docker://pytorch/pytorch:2.5.0-cuda12.4-cudnn9-runtime
#SBATCH --container-mounts=/mnt/compchem:/data,/scratch/$USER:/out
#SBATCH -o train-%j.out
#SBATCH --mail-user=ntailor --mail-type=END,FAIL

nvidia-smi
python /data/scripts/train.py \
       --data /data/dataset \
       --out /out/model_${SLURM_JOB_ID} \
       --epochs 50
EOF
```

**Check progress:**
```bash
tail -f train-12345.out                            # training logs
ssh insiiukgpu01 nvidia-smi                        # GPU utilisation (need ssh access)
sacct -j 12345 --format=JobID,State,Elapsed,MaxRSS
```

**Verify it worked:**
```bash
sacct -j 12345 --format=JobID,State,ExitCode      # COMPLETED 0:0
ls /scratch/$USER/model_12345/                    # checkpoints written
```

---

### 5. Lightweight inference on L4

`cgpu01` for batch inference / fine-tuning — cheaper card, 2-day cap.

```bash
sbatch <<'EOF'
#!/bin/bash
#SBATCH -J infer
#SBATCH -A informatics
#SBATCH -p cgpu01
#SBATCH --gres=gpu:l4:1
#SBATCH -c 8
#SBATCH --mem=32G
#SBATCH -t 4:00:00
#SBATCH --container-image=docker://pytorch/pytorch:2.5.0-cuda12.4-cudnn9-runtime
#SBATCH --container-mounts=/mnt/informatics:/data
#SBATCH -o infer-%j.out

python /data/inference/run_batch.py --batch_size 64
EOF
```

---

### 6. Interactive debug session (60min, jumps queue)

Quick "I need to test something on a GPU node right now" — uses the `debug` QoS to bypass long queues.

```bash
srun -p interactive -q debug --gres=gpu:1 -c 4 --mem=16G -t 60:00 --pty bash
```

Inside the shell, you're on the node with the GPU allocated. `nvidia-smi`, `python -c 'import torch'`, etc. `exit` to release.

For CPU-only debug:
```bash
srun -p interactive -q debug -c 8 --mem=32G -t 60:00 --pty bash
```

---

### 7. FEP+ / molecular dynamics (compchem)

GROMACS or similar — heavy GPU + heavy CPU prep stages. Run as two dependent jobs.

```bash
# Stage 1: CPU prep (topology, minimisation)
PREP=$(sbatch --parsable <<'EOF'
#!/bin/bash
#SBATCH -J fep-prep
#SBATCH -A compchem
#SBATCH -p cpu
#SBATCH -c 32
#SBATCH --mem=128G
#SBATCH -t 4:00:00
#SBATCH -o fep-prep-%j.out

gmx grompp -f em.mdp -c system.gro -p topol.top -o em.tpr
gmx mdrun -deffnm em -ntomp 32
EOF
)
echo "Prep job: $PREP"

# Stage 2: GPU production run, starts only if prep succeeds
sbatch --dependency=afterok:$PREP <<EOF
#!/bin/bash
#SBATCH -J fep-prod
#SBATCH -A compchem
#SBATCH -p gpu01
#SBATCH --gres=gpu:h200_nvl:1
#SBATCH -c 16
#SBATCH --mem=64G
#SBATCH -t 2-00:00:00
#SBATCH -o fep-prod-%j.out

gmx grompp -f md.mdp -c em.gro -p topol.top -o md.tpr
gmx mdrun -deffnm md -ntmpi 1 -ntomp 16 -gpu_id 0 -nb gpu -pme gpu
EOF
```

**Check progress of the chain:**
```bash
squeue -u $USER -o "%i %j %T %R"
# fep-prod shows (Dependency) until fep-prep finishes COMPLETED
```

---

## How to check a job — the universal cheat

```bash
# Is it running yet?
squeue -j NNN

# Why isn't it running?
scontrol show job NNN | grep -E 'JobState|Reason|StartTime'

# What's it printing right now?
tail -f <output-file>          # path from -o, e.g. burden-12345.out

# Did it finish? Did it succeed?
sacct -j NNN --format=JobID,State,ExitCode,Elapsed,MaxRSS,NodeList

# State=COMPLETED ExitCode=0:0   → success
# State=FAILED                    → check .err / .out for traceback
# State=TIMEOUT                   → walltime too short, bump -t
# State=OUT_OF_MEMORY             → bump --mem
# State=CANCELLED+ by NNN         → killed by user/admin
# State=NODE_FAIL                 → infra issue, requeue with `scontrol requeue NNN`

# Resource usage — was your --mem / --cpus right?
sacct -j NNN --format=JobID,MaxRSS,MaxVMSize,AveCPU,ReqMem,ReqCPUS
# MaxRSS << ReqMem → you over-asked, reduce --mem next time
# MaxRSS == ReqMem → you're at the line, bump --mem
```

---

## When something's wrong

```bash
sinfo -R                                       # which nodes are drained/down and why
scontrol show node insiiukgpu01 | grep Reason  # specific node's drain reason
sudo journalctl -u slurmd -n 50 --no-pager     # local slurmd log
sudo journalctl -u slurmctld -n 50 --no-pager  # controller log (cpu01 only)
```

Slurm-web UI also shows node states colour-coded at http://10.174.16.55:5011/ .
