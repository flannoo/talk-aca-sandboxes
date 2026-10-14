# Runs INSIDE the agent's sandbox, next to the transform the agent wrote (Demo 3.4).
# It holds the mapping in memory, waits for a human to approve it, then maps every
# partner file that lands in /work/inbox. One status line per second in /work/worker.status.
import os, pathlib, subprocess, time

work = pathlib.Path("/work")
inbox, outbox = work / "inbox", work / "outbox"
inbox.mkdir(exist_ok=True)
outbox.mkdir(exist_ok=True)

started = time.strftime("%H:%M:%S UTC")
heartbeat = 0
mapped = []

while True:
    heartbeat += 1
    approved = (work / "APPROVED").exists()
    if approved:
        for f in sorted(inbox.glob("*.csv")):
            if f.name in mapped:
                continue
            run = subprocess.run(["python3", "transform.py", str(f)], cwd=work, capture_output=True, text=True)
            (outbox / f"{f.stem}.json").write_text(run.stdout)
            mapped.append(f.name)
    state = "LIVE" if approved else "waiting for approval"
    (work / "worker.status").write_text(
        f"pid {os.getpid()} | started {started} | heartbeat #{heartbeat} | {state} | files mapped: {len(mapped)}\n")
    time.sleep(1)
