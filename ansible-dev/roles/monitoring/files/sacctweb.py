#!/usr/bin/env python3
"""sacctweb — minimal web UI for sacct.

Wraps `sacct --parsable2` so users get a searchable, filterable, paginated
job-history view that slurm-web v4 doesn't provide. Read-only.

Run:    python3 sacctweb.py
Browse: http://<host>:5012/
"""
from flask import Flask, request, render_template_string
import subprocess
import shlex
import html

app = Flask(__name__)
PORT = 5013

# Fields we pull from sacct. Order matters — matches the columns we render.
FIELDS = [
    "JobID", "JobName", "User", "Account", "Partition",
    "State", "ExitCode", "Submit", "Start", "Elapsed", "NodeList",
]

PAGE_SIZE = 50


def run_sacct(state="", user="", partition="", since="1day"):
    """Call sacct, return list[dict] of jobs (top-level allocations only)."""
    cmd = [
        "sacct", "-a", "-X", "-P", "-n",
        f"--starttime=now-{since}",
        "--format=" + ",".join(FIELDS),
    ]
    if state:     cmd += ["--state", state]
    if user:      cmd += ["--user", user]
    if partition: cmd += ["--partition", partition]

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=True).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return [], str(e)

    jobs = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) != len(FIELDS):
            continue
        jobs.append(dict(zip(FIELDS, parts)))
    return jobs, None


TEMPLATE = """<!doctype html>
<html><head><meta charset="utf-8"><title>sacct web</title>
<style>
body { font-family: -apple-system, system-ui, sans-serif; margin: 1.5em; color: #222; }
h1 { font-size: 1.4em; margin: 0 0 0.5em; }
form { margin: 0.5em 0 1em; padding: 0.8em; background: #f6f6f6; border-radius: 6px; }
form input, form select { padding: 0.35em 0.5em; margin-right: 0.5em; font-size: 0.95em; }
form button { padding: 0.4em 1em; background: #2a6df4; color: white; border: none; border-radius: 4px; cursor: pointer; }
table { border-collapse: collapse; width: 100%; font-size: 0.9em; }
th, td { text-align: left; padding: 0.4em 0.6em; border-bottom: 1px solid #eee; }
th { background: #fafafa; font-weight: 600; position: sticky; top: 0; }
tr:hover { background: #f9fcff; }
.state-COMPLETED { color: #2a8c2a; }
.state-FAILED, .state-TIMEOUT, .state-NODE_FAIL, .state-OUT_OF_MEMORY, .state-CANCELLED { color: #c0392b; }
.state-RUNNING, .state-PENDING { color: #d68910; }
.muted { color: #888; }
.pager { margin: 1em 0; }
.pager a { padding: 0.3em 0.7em; background: #eee; border-radius: 3px; text-decoration: none; color: #333; margin-right: 0.3em; }
.pager a:hover { background: #ddd; }
.pager .current { background: #2a6df4; color: white; }
.summary { color: #555; font-size: 0.9em; margin-bottom: 0.5em; }
</style></head><body>
<h1>sacct web — job history</h1>

<form method="get">
  <input name="q"         value="{{ q }}"         placeholder="search (any column)" size="28">
  <select name="state">
    <option value="">any state</option>
    {% for s in ["COMPLETED","FAILED","RUNNING","PENDING","CANCELLED","TIMEOUT","OUT_OF_MEMORY","NODE_FAIL"] %}
      <option value="{{ s }}" {% if state==s %}selected{% endif %}>{{ s }}</option>
    {% endfor %}
  </select>
  <input name="user"      value="{{ user }}"      placeholder="user" size="12">
  <input name="partition" value="{{ partition }}" placeholder="partition" size="10">
  <select name="since">
    {% for s in ["1hour","6hour","1day","7day","30day","90day"] %}
      <option value="{{ s }}" {% if since==s %}selected{% endif %}>last {{ s }}</option>
    {% endfor %}
  </select>
  <button type="submit">apply</button>
  <a href="/" class="muted" style="margin-left:1em;">reset</a>
</form>

<div class="summary">
{% if error %}
  <span style="color:#c0392b;">ERROR: {{ error }}</span>
{% else %}
  showing {{ start+1 }}–{{ start+jobs|length }} of {{ total }} matching jobs
{% endif %}
</div>

<table>
<thead><tr>
  <th>JobID</th><th>Name</th><th>User</th><th>Account</th><th>Partition</th>
  <th>State</th><th>Exit</th><th>Submit</th><th>Elapsed</th><th>Node</th>
</tr></thead>
<tbody>
{% for j in jobs %}
<tr>
  <td><strong>{{ j.JobID }}</strong></td>
  <td>{{ j.JobName }}</td>
  <td>{{ j.User }}</td>
  <td>{{ j.Account }}</td>
  <td>{{ j.Partition }}</td>
  <td class="state-{{ j.State.split()[0] }}">{{ j.State }}</td>
  <td>{{ j.ExitCode }}</td>
  <td class="muted">{{ j.Submit }}</td>
  <td>{{ j.Elapsed }}</td>
  <td class="muted">{{ j.NodeList }}</td>
</tr>
{% endfor %}
</tbody>
</table>

<div class="pager">
  {% if start > 0 %}<a href="?{{ qs(start - page_size) }}">‹ prev</a>{% endif %}
  <span class="current">page {{ page+1 }} / {{ pages }}</span>
  {% if start + page_size < total %}<a href="?{{ qs(start + page_size) }}">next ›</a>{% endif %}
</div>

<p class="muted" style="margin-top:2em; font-size:0.85em;">
  Sourced from <code>sacct</code>. Per-job detail: <code>ssh insiiukcpu01 jobinfo &lt;jobid&gt;</code>.
</p>
</body></html>
"""


@app.route("/")
def index():
    q         = request.args.get("q", "").strip()
    state     = request.args.get("state", "").strip()
    user      = request.args.get("user", "").strip()
    partition = request.args.get("partition", "").strip()
    since     = request.args.get("since", "1day").strip()
    start     = int(request.args.get("start", 0))

    jobs, error = run_sacct(state=state, user=user, partition=partition, since=since)

    # Free-text filter across all fields
    if q and not error:
        ql = q.lower()
        jobs = [j for j in jobs if any(ql in (v or "").lower() for v in j.values())]

    total = len(jobs)
    pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    page = start // PAGE_SIZE
    paged = jobs[start:start + PAGE_SIZE]

    # Build query string preserving filters (used by pager)
    def qs(new_start):
        params = {
            "q": q, "state": state, "user": user,
            "partition": partition, "since": since,
            "start": new_start,
        }
        return "&".join(f"{k}={html.escape(str(v))}" for k, v in params.items() if v != "")

    return render_template_string(
        TEMPLATE,
        jobs=paged, total=total, start=start, page=page, pages=pages,
        page_size=PAGE_SIZE,
        q=q, state=state, user=user, partition=partition, since=since,
        error=error, qs=qs,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
