"""Patch slurmweb/views/agent.py jobs() to merge sacct history. Idempotent."""
import re
import sys

PATH = "/usr/lib/python3/dist-packages/slurmweb/views/agent.py"
SENTINEL = "INSMED PATCH: merge sacct history"

new_jobs_func = '''def jobs():
    # INSMED PATCH: merge sacct history (last 7 days) into the live job list.
    # slurm-web v4 only sees live jobs in slurmctld; sacct provides completion
    # records from slurmdbd. De-dupe by job_id so live entries win.
    node = request.args.get("node")
    if node:
        return jsonify(slurmrest("jobs_by_node", node))
    live = slurmrest("jobs")
    try:
        import subprocess
        out = subprocess.run(
            ["sacct", "-a", "-X", "-P", "--noheader", "--starttime", "now-7days",
             "--format",
             "JobID,Account,User,Partition,State,Reason,QoS,AllocCPUs,NodeList"],
            capture_output=True, text=True, timeout=10,
        )
        live_ids = {j.get("job_id") for j in live}
        for line in out.stdout.splitlines():
            parts = line.split("|")
            if len(parts) < 9:
                continue
            jid, account, user, partition, state, reason, qos, cpus, nodelist = parts[:9]
            try:
                job_id = int(jid)
            except ValueError:
                continue
            if job_id in live_ids:
                continue
            try:
                n_cpus = int(cpus)
            except ValueError:
                n_cpus = 0
            live.append({
                "account": account,
                "cpus": {"infinite": False, "number": n_cpus, "set": True},
                "job_id": job_id,
                "job_state": state.split()[0],
                "node_count": {"infinite": False, "number": 1, "set": True},
                "nodes": nodelist,
                "partition": partition,
                "priority": {"infinite": False, "number": 0, "set": True},
                "qos": qos,
                "state_reason": reason or "None",
                "user_name": user,
            })
    except Exception as exc:
        current_app.logger.warning(f"sacct history merge failed: {exc}")
    return jsonify(live)
'''

src = open(PATH).read()

if SENTINEL in src:
    print(f"already patched: {PATH}")
    sys.exit(0)

# Replace original 5-line jobs() function with the patched version.
pat = re.compile(
    r"def jobs\(\):\n"
    r"    node = request\.args\.get\(\"node\"\)\n"
    r"    if node:\n"
    r"        return jsonify\(slurmrest\(\"jobs_by_node\", node\)\)\n"
    r"    else:\n"
    r"        return jsonify\(slurmrest\(\"jobs\"\)\)\n"
)

new_src, n = pat.subn(new_jobs_func, src)
if n != 1:
    print(f"ERROR: expected exactly 1 jobs() function to replace; found {n}")
    sys.exit(1)

open(PATH, "w").write(new_src)
print(f"patched: {PATH}")
