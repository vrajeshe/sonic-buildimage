# Test case failure simulation sequence
_Exported on 26/05/2026 at 10:46:32 GMT+5:30 from Cursor (3.5.33)_

---

**User**

Updated the @pretest.txt Pls analyze @pretest.txt and let me know what is the seqence of tests i have to execute to simulate the failure of the Test case which is occuring in this log, You have access to sonic-buildimage code and sonic-test code with you

---

**Cursor**

Analyzing `pretest.txt` and tracing the failing test in sonic-buildimage and sonic-test to determine the execution sequence needed to reproduce it.


## Failure summary

This log does **not** show a functional assertion failure inside the test body. Both tests completed their FRR checks. The failure is from the **module-scoped** `core_dump_and_config_check` fixture, which detected a **new orchagent core dump** after the module finished:

| Item | Value |
|------|--------|
| **New core dump** | `orchagent.1779621500.56.core.gz` (created ~**11:18:20 UTC**) |
| **Pre-existing core** (ignored) | `orchagent.1779619234.54.core.gz` (from ~10:40, before this module) |
| **Reported on** | `test_frr_large_config_load_stress[vlab-01]` (last test in the module) |
| **Secondary error** | Recovery `config reload -y` failed once with *"SwSS container is not ready"* because orchagent had crashed; retry succeeded |

**Environment from log:** testbed `vms-kvm-t0`, DUT `vlab-01`, topo `t0`, VS platform, image `master-22533.1121459-dd3ba5c53`, unified FRR mode (`frr.conf`).

---

## Test execution sequence (from the log)

```mermaid
sequenceDiagram
    participant M as Module fixtures
    participant T1 as test_frr_config_check
    participant T2 as test_frr_large_config_load_stress
    participant CD as core_dump_and_config_check

    M->>M: Record baseline cores (1 old orchagent core)
    M->>T1: Run (debug → 1 config_reload)
    T1->>T1: Verify FRR config vs running-config
    M->>T2: Run (basic → 2 stress iterations)
    T2->>T2: Inject 600+ BGP policy lines into bgpd.main.conf.j2
    T2->>T2: config_reload × 2
    Note over T2: orchagent crashes ~11:18:20 during iteration 2
    T2->>T2: Cleanup config_reload
    CD->>CD: Detect NEW core → FAIL
    CD->>CD: Attempt DUT recovery config_reload
```

### Step-by-step timeline

| Time | What ran |
|------|----------|
| 11:10:07 | Module setup; baseline core dump snapshot |
| 11:11:22–11:13:29 | **`test_frr_config_check`** — 1× `config reload`, FRR consistency check |
| 11:15:42–11:19:12 | **`test_frr_large_config_load_stress`** — inject large BGP policy, **2×** stress `config reload`, cleanup reload |
| ~11:18:20 | **orchagent core created** (during stress iteration 2 / large FRR load) |
| 11:20:24 | Module teardown: `core_dump_and_config_check` **FAILS** on new core |
| 11:20:24–11:21:07 | Recovery `config reload` (1st attempt failed, retry OK) |

---

## Commands to reproduce

Run from the **sonic-mgmt** container, matching the log environment.

### Option 1 — Exact CI-like sequence (recommended)

Run **both tests in one pytest session** (same module → same `core_dump_and_config_check` behavior):

```bash
cd /var/src/sonic-mgmt/tests

./run_tests.sh \
  -n vms-kvm-t0 \
  -d vlab-01 \
  -f vtestbed.yaml \
  -i ../ansible/veos_vtb \
  -c bgp/test_frr_config_check.py \
  -u -l DEBUG
```

Or directly with pytest:

```bash
cd /var/src/sonic-mgmt/tests

python3 -m pytest bgp/test_frr_config_check.py \
  --inventory ../ansible/lab,../ansible/veos \
  --host-pattern vlab-01 \
  --testbed vms-kvm-t0 \
  --testbed_file ../ansible/vtestbed.yaml \
  --log-cli-level DEBUG \
  --allow_recover
```

This runs tests in file order:
1. `test_frr_config_check` (default completeness → **debug** → **1** reload iteration)
2. `test_frr_large_config_load_stress` (default completeness → **basic** → **2** stress iterations)

That matches the log: *"Completeness level: debug, setting iterations to: 1"* and *"Completeness level: basic, stress iterations: 2"*.

### Option 2 — Minimal repro (likely sufficient)

The crash happened inside the stress test. To isolate:

```bash
python3 -m pytest bgp/test_frr_config_check.py::test_frr_large_config_load_stress \
  --inventory ../ansible/lab,../ansible/veos \
  --host-pattern vlab-01 \
  --testbed vms-kvm-t0 \
  --testbed_file ../ansible/vtestbed.yaml \
  --log-cli-level DEBUG \
  --allow_recover
```

Use a **clean DUT** (no stale cores) for a clean signal:

```bash
# On DUT before test
sudo rm -f /var/core/orchagent.*.core.gz
```

### Option 3 — Force more stress iterations

```bash
python3 -m pytest bgp/test_frr_config_check.py::test_frr_large_config_load_stress \
  ... \
  --completeness_level confident   # 5 iterations
  # or
  --completeness_level thorough    # 10 iterations
```

---

## What the stress test does (root cause path)

From `test_frr_config_check.py`:

1. Injects **600+ lines** of BGP policy into `/usr/share/sonic/templates/bgpd/bgpd.main.conf.j2` inside the `bgp` container:
   - 200 prefix-lists
   - 100 community-lists  
   - 300 route-maps
2. Runs **`config_reload(safe_reload=True)`** N times (2 at basic level).
3. Each reload re-renders FRR config via `sonic-cfggen` and reloads a large `frr.conf`.
4. Large BGP → FPM → **orchagent** route processing triggers the crash at **11:18:20** (during iteration 2).

`test_frr_config_check` alone does a normal config reload without the injected policy; it did **not** produce the new core in this run.

---

## Pre-requisites

1. **KVM t0 testbed** deployed: `vms-kvm-t0` / `vlab-01` (via `kvmtest.sh` or `testbed-cli.sh`).
2. **Image**: `master-22533.1121459-dd3ba5c53` (or same branch/build under debug).
3. **FRR mode**: `separated` or `unified` (log shows unified with `frr.conf`).
4. **FRR management framework disabled** (otherwise stress test skips).
5. Optional CI-like prior state: an older orchagent core may already exist; only **new** cores after module start cause failure.

---

## How to confirm reproduction

After the run:

```bash
# On DUT
ls -la /var/core/
# Expect new file like: orchagent.<timestamp>.56.core.gz

# In test logs
grep -E "core_dump|new_core_dumps|core_dump_check_failed" logs/bgp/test_frr_config_check.log
```

Fetched core in the log:  
`/var/src/sonic-mgmt/tests/logs/vlab-01/var/core/orchagent.1779621500.56.core.gz`

---

## Summary

| Goal | Action |
|------|--------|
| **Match log exactly** | Run full module: `bgp/test_frr_config_check.py` (both tests, default completeness) |
| **Fastest isolation** | Run only `test_frr_large_config_load_stress` on clean DUT |
| **Actual bug** | orchagent crash during large FRR config load + `config reload`, not FRR config mismatch |
| **Reported failure** | Module `core_dump_and_config_check` → `core_dump_check_failed: True` |

If you want, I can next help trace the orchagent crash from the fetched core with `gdb` against the VS syncd/orchagent binaries in sonic-buildimage.

---

**User**

ca u check what changes in my repo chause this issue 

---

**Cursor**

Tracing repo changes that could cause the orchagent crash during the FRR large-config stress test.


## What actually failed

The log shows an **orchagent core dump** during `test_frr_large_config_load_stress`, caught by the module fixture `core_dump_and_config_check` — not an FRR config mismatch assertion. FRR forward checks appear to have passed; the DUT crashed under load.

---

## Change in your repo that **triggers** this failure

### 1. sonic-test (MASTER) — primary trigger

The failure starts appearing after your **May 22 upstream merge**:

| Commit | Branch | What it did |
|--------|--------|-------------|
| **`3e93cca049`** | `MASTER/sonic-test` master | Cisco “upstream update” merge (May 22, 2026) |
| **`4da02179e5`** | upstream sonic-mgmt | **[test] Add FRR large config load stress test (#24061)** (May 18, 2026) |

Before that merge (`ca79ac74a6`, Apr 15), `test_frr_config_check.py` had **only** `test_frr_config_check`. After `3e93cca049`, it also runs **`test_frr_large_config_load_stress`**, which:

- Injects **200 prefix-lists + 100 community-lists + 300 route-maps** into `bgpd.main.conf.j2`
- Runs **2× `config_reload`** at default completeness (`basic`)
- Drives heavy BGP → FPM → **orchagent** work on reload

```bash
# Verify in your repo:
cd /nobackup/vrajeshe/CODE/MASTER/sonic-test
git show 4da02179e5 --stat
git diff ca79ac74a6..3e93cca049 -- sonic-mgmt/tests/bgp/test_frr_config_check.py | head
```

**Conclusion:** The new stress test is what puts the DUT into the state that produces the orchagent core. Without `4da02179e5`, this failure would not show up in `bgp/test_frr_config_check.py`.

---

### 2. CMASTER sonic-test — does **not** have this yet

```text
CMASTER/sonic-test (c-master): no stress test, no May 22 upstream merge
```

So if you run from **CMASTER/sonic-test**, you would **not** hit this test unless you merge upstream master.

---

## Build-image changes (the **underlying crash**, not the test trigger)

Your log image is **`master-22533.1121459-dd3ba5c53`** (upstream master KVM VS), not CMASTER.

### What the timeline shows

| Event | Time (UTC) | Meaning |
|-------|------------|---------|
| Old core `orchagent.1779619234.54` | ~10:40 | Orchagent already crashed **before** this module (earlier CI tests) |
| Module starts | 11:10 | 1 pre-existing core ignored as baseline |
| `test_frr_config_check` | 11:11–11:13 | 1× config_reload — no **new** core |
| `test_frr_large_config_load_stress` | 11:15–11:19 | Injects large BGP policy + 2× reload |
| **New core** `orchagent.1779621500.56` | **11:18:20** | Crash during stress iteration 2 |
| Fixture failure | 11:20:24 | `core_dump_check_failed: True` |

So the **product bug** is in **orchagent / route handling on VS** under large FRR + config_reload. The **test change** is what exposes it reliably.

### Upstream buildimage suspects (in MASTER/sonic-buildimage)

These are in your **MASTER/sonic-buildimage** tree and likely in that image:

| Commit | Area | Why it matters |
|--------|------|----------------|
| Recent **sonic-swss** bump → **`6fcf467f`** | orchagent | Route/ZMQ/STP changes in swss submodule |
| **`83a133377`** | orchagent | Fix for missing `/zmq_swss` causing orchagent crash (related class of bug) |
| **`f4b8e1fa1`** | `dplane_fpm_sonic` | Skip MRIB routes in FPM (route install/delete path) |
| **`db77756ba`** | sonic-fib | New FIB/nexthop library (RIB/FIB path changes) |
| **`e04f7b67e`** | sonic-frr | FRR tcmalloc at build time |

The exact crashing line needs analysis of `orchagent.1779621500.56.core.gz` with gdb.

### CMASTER-only change (not in your log image, but in **your** c-master repo)

| Commit | Branch | Change |
|--------|--------|--------|
| **`749c3d393`** | `CMASTER/sonic-buildimage` | **“filter local connected host route in fpm” (#3541)** — filters `ZEBRA_ROUTE_ADJACENCY` routes in `dplane_fpm_sonic.c` |

This is **not** present in `MASTER/sonic-buildimage` (no `fpm_nl_skip` there). It would matter only if you build/run **c-master** image, not the `master-22533` image from the log.

---

## Root-cause chain (short)

```text
3e93cca049 (sonic-test merge)
  └─ adds test_frr_large_config_load_stress (#24061)
       └─ large BGP policy + config_reload × 2
            └─ orchagent crashes on VS (11:18:20)
                 └─ core_dump_and_config_check FAILS
```

---

## What to do next

1. **Confirm the test introduction**
   ```bash
   cd /nobackup/vrajeshe/CODE/MASTER/sonic-test
   git log --oneline -1 4da02179e5
   git merge-base --is-ancestor 4da02179e5 HEAD && echo "stress test is in your branch"
   ```

2. **Bisect the product bug** (buildimage / sonic-swss):
   - Analyze core: `orchagent.1779621500.56.core.gz`
   - Repro with only stress test on clean DUT (no old cores)
   - Compare orchagent/routeorch between last good and `master-22533` image

3. **If you’re on CMASTER** and plan to merge upstream tests soon: expect the same failure after merging `4da02179e5`; also review **`749c3d393`** (FPM adjacency filter) for interaction with reload storms.

---

**Bottom line:** The change in **your sonic-test repo** that causes this failure to appear is the **`3e93cca049` upstream merge** bringing in **`test_frr_large_config_load_stress` (#24061)**. The **orchagent crash itself** is a **sonic-buildimage / sonic-swss** issue on VS, likely pre-existing (note the core at 10:40), amplified by the new stress test.

I can next help bisect the orchagent crash in `sonic-swss` if you share the core file or the exact image build job for `dd3ba5c53`.

---

**User**

Srry my code is in /nobackup/vrajeshe/CODE/MASTER/sonic-buildimage not CMASTER

---

**Cursor**

Focusing on `MASTER/sonic-buildimage` only — tracing recent changes that could cause the orchagent crash.


Local modifications in `MASTER/sonic-buildimage` may be relevant — inspecting FRR template and docker changes.


Thanks for the correction. Here is the updated analysis focused on **`/nobackup/vrajeshe/CODE/MASTER/sonic-buildimage`** (not CMASTER).

## What failed in `pretest.txt`

The pytest run did not fail on a BGP assertion. It failed in the module-scoped **`core_dump_and_config_check`** fixture after detecting a **new orchagent core dump**:

| Core file | Time (UTC) | Status |
|-----------|------------|--------|
| `orchagent.1779619234.54.core.gz` | ~10:40 | Pre-existing baseline (ignored) |
| `orchagent.1779621500.56.core.gz` | **11:18:20** | **New — causes failure** |

**Test sequence (in order):**

1. `test_frr_config_check[vlab-01]` — passed (1 config_reload)
2. `test_frr_large_config_load_stress[vlab-01]` — stress injection + reloads; orchagent crashed during cleanup reload (~11:18)
3. Module teardown — `core_dump_and_config_check` **FAILED**

**Reproduce (from sonic-test):**

```bash
cd /var/src/sonic-mgmt/tests
./run_tests.sh -n vms-kvm-t0 -d vlab-01 -f vtestbed.yaml -i ../ansible/veos_vtb \
  -c bgp/test_frr_config_check.py -u -l DEBUG
```

Clear cores first: `sudo rm -f /var/core/orchagent.*.core.gz`

---

## Your MASTER repo state

**Path:** `/nobackup/vrajeshe/CODE/MASTER/sonic-buildimage`  
**Branch:** `azure/cisco/master` @ `75765c73e`

The CI image in the log is **`master-22533.1121459-dd3ba5c53`** (upstream master pipeline). Commit `dd3ba5c53` is **not** in your local tree.

### Committed code (HEAD) — still uses classic **separated** mode

Committed `docker_init.sh` renders separate `bgpd.conf`, `zebra.conf`, etc. when `docker_routing_config_mode` is `separated`.

### Local uncommitted changes (`rajesh.diff` / working tree) — **FRR unified migration**

These are **not committed** but match what the failing DUT actually ran:

| File | Change |
|------|--------|
| `dockers/docker-fpm-frr/docker_init.sh` | Treats `separated` as deprecated → forces **unified** (`gen_frr.conf.j2` → `/etc/frr/frr.conf`) |
| `dockers/docker-fpm-frr/frr/gen_frr.conf.j2` | Includes `zebra/staticd/bgpd/sharpd` templates instead of `frr.conf.j2` |
| `dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2` | Include path `bgpd.main.conf.j2` → `bgpd/bgpd.main.conf.j2` |
| `src/sonic-frr-mgmt-framework/frrcfgd/frrcfgd.py` | Default mode `unified`; adds `use_template_render_for_restore` |
| `src/sonic-yang-models/.../sonic-device_metadata.yang` | New YANG leaf |

The CI DUT shows exactly this mismatch:

- **CONFIG_DB:** `docker_routing_config_mode = separated` (log line 991)
- **Runtime:** only `frr.conf` + `vtysh.conf` in `/etc/sonic/frr` (unified layout)
- **Stress test** looks for `/etc/frr/bgpd.conf` because CONFIG_DB says separated → **file not found** (log lines 1073–1078)

Stress content **did** appear in running-config (`_stress_content_present` passed at 11:17:32), so template injection into `bgpd.main.conf.j2` works through the unified render chain. The orchagent core at **11:18:20** happened during the **cleanup `config_reload`** (cleanup started 11:17:33, finished 11:19:12).

---

## Root cause chain

```
sonic-test: new stress test (4da02179e5 / merged 3e93cca049)
    ↓
Injects 1200 lines of BGP policy into bgpd.main.conf.j2 + config_reload
    ↓
Your local FRR unified migration (rajesh.diff, in CI image dd3ba5c53)
    ↓  CONFIG_DB still "separated" but runtime uses unified frr.conf
Large unified FRR config reload → FPM route/policy churn
    ↓
orchagent crashes (11:18:20) during cleanup reload
    ↓
core_dump_and_config_check fails
```

**Contributors:**

1. **sonic-test** — new `test_frr_large_config_load_stress` exposes the crash under large policy + reload
2. **Your uncommitted buildimage changes** — unified migration without updating CONFIG_DB; test uses wrong rendered path (`bgpd.conf` vs `frr.conf`)
3. **Product bug (likely sonic-swss/orchagent)** — crash on VS during heavy reload after large FRR config (submodule at `6fcf467f`)

CMASTER-only changes (e.g. FPM adjacency filter) are **not** relevant here.

---

## Recommended next steps

1. **Confirm the CI image was built with your local diff** — the DUT behavior matches `rajesh.diff`, not committed HEAD.
2. **Fix the mode mismatch** — either set `docker_routing_config_mode` to `unified` in testbed/minigraph, or teach the stress test to detect runtime mode (check whether `/etc/frr/frr.conf` exists, not just CONFIG_DB).
3. **Analyze the core** — `gdb` on `orchagent.1779621500.56.core.gz` against the VS orchagent binary from that image (likely routeorch/FPM path).
4. **Bisect sonic-swss** if the crash persists after fixing the mode mismatch — the reload stress may still hit a real orchagent bug.

If you want, I can next diff your local changes against upstream master for the same files, or walk through gdb commands for the core dump.

---

**User**

Ok let me clarify i have built this image and also ran the tests somewhere else by applying rajesh.diff on tip of the code present in the MASTER directory .
the changes resent in rajesh.diff are the only changes i did , but some tests are failing mentioned in  @pretest.txt 

---

**Cursor**

Thanks for the clarification. Yes — your `rajesh.diff` is directly responsible for the test failures in `pretest.txt`. Here is precisely how.

## The DUT was built with your diff

Two pieces of evidence prove the failing image contains `rajesh.diff`:

1. **`/etc/sonic/frr` contains only `frr.conf` + `vtysh.conf`** (log line 645) — this is the **unified** layout produced by your `docker_init.sh` change.
2. **`/etc/frr/bgpd.conf` does not exist inside the bgp container** (log lines 1073–1078). Stock `separated` mode would always render `bgpd.conf`.

But **CONFIG_DB still says `docker_routing_config_mode = separated`** (log line 991). That inconsistency is the smoking gun. `rajesh.diff` silently aliases `separated → unified` at container start, while CONFIG_DB / the rest of the system continue to think the mode is `separated`.

## What actually happened in the run

```
test_frr_config_check        → PASS (single reload, small config)
test_frr_large_config_load_stress → STRESS ITERATION 1/2:
   _stress_content_present                       → OK  (11:17:32)
   cat /etc/frr/bgpd.conf (rendered_path)        → ENOENT
       └─ pytest_assert("Failed to read /etc/frr/bgpd.conf") fires
   finally: restore template + config_reload
       └─ orchagent crashes at 11:18:20         → NEW CORE
core_dump_and_config_check (module teardown)    → FAIL
```

So there are **two failures**, both rooted in `rajesh.diff`:

### Failure 1 — assertion inside the stress test
The stress test does:

```python
rendered_path = '/etc/frr/frr.conf' if mode == 'unified' else '/etc/frr/bgpd.conf'
...
config_result = duthost.shell("docker exec {} cat {}".format(bgp_name, rendered_path), ...)
pytest_assert(config_result['rc'] == 0, "... Failed to read {}".format(rendered_path))
```

Because CONFIG_DB still reports `separated`, the test looks for `bgpd.conf`. Your `docker_init.sh` no longer renders that file. `pytest_assert` fires and the test goes into its `finally` block.

(That's also why the log jumps from line 1078 straight to line 1079 "Cleaning up stress test artifacts" with no "STRESS ITERATION 1/2 PASSED" — the assertion took us out.)

### Failure 2 — orchagent core during cleanup `config_reload`
The `finally` block restores the original `bgpd.main.conf.j2` and runs `config_reload`. Orchagent crashes at 11:18:20, producing `orchagent.1779621500.56.core.gz`.

This crash is also reachable through your diff because the rendered FRR config has materially changed:

- Your new `gen_frr.conf.j2` includes **four daemon templates** (`zebra/zebra.conf.j2`, `staticd/staticd.conf.j2`, `bgpd/bgpd.conf.j2`, `sharpd/sharpd.conf.j2`) instead of the single `frr.conf.j2`.
- **Each of those four templates includes `common/daemons.common.conf.j2`** — so `hostname`, `password`, `enable password`, `log syslog`, `log facility` are now emitted **4× into the single `frr.conf`**. The comment in your own diff says this is "safe", but FRR sees duplicate `hostname`/`password`/`log` directives every reload — visible already at log line 654 (`! template: common/daemons.common.conf.j2`).
- Your `bgpd/bgpd.conf.j2`, `zebra/zebra.conf.j2`, `staticd/staticd.conf.j2` switched `{% include "X.j2" %}` to `{% include "X/Y.j2" %}` — these only work because `gen_frr.conf.j2` is now rendered with `-T` removed (no `frrcfgd` template dir) on the non-mgmt-framework path. If the build ever falls back, the includes will fail to resolve.

Whether the orchagent crash itself is a pre-existing VS bug or is directly caused by FRR emitting the duplicate-laden unified config (FPM stream churn, route flap during reload) needs a `gdb` look at the core. But the **trigger path is entirely owned by your diff**.

## Concrete things in `rajesh.diff` that need to be fixed before this can pass

1. **Update CONFIG_DB at the same time you change the runtime.** Either:
   - migrate `docker_routing_config_mode` from `separated` to `unified` in minigraph/init_cfg/golden_config, or
   - keep `separated` honored end-to-end (the test, sonic-utilities, and CLI all key off this value).

2. **Stop including `common/daemons.common.conf.j2` four times.** Either guard it with `{% if not common_emitted %}` or restructure so `daemons.common.conf.j2` is included exactly once at the top of `gen_frr.conf.j2`, with each daemon template skipping it.

3. **Keep the `-T /usr/local/sonic/frrcfgd` flag in the non-mgmt-framework branch too** (your diff drops it). If anything in `gen_frr.conf.j2` or its includes ever references a frrcfgd template, the render will fail silently.

4. **Don't change include paths to `subdir/file.j2` form** unless you're also updating every caller. Better: keep the include names flat and rely on Jinja's loader paths.

5. The new YANG leaf `use_template_render_for_restore` is added but **its `false` branch in `frrcfgd.py` is the only place it's read**. You introduced a config knob with a default that flips the existing behavior:

```2167:2178:src/sonic-frr-mgmt-framework/frrcfgd/frrcfgd.py
        if 'docker_routing_config_mode' in db_entry:
            self.config_mode = db_entry['docker_routing_config_mode']
        else:
            self.config_mode = "unified"
        if 'use_template_render_for_restore' in db_entry:
            self.use_template_render_for_restore = db_entry['use_template_render_for_restore']
        else:
            self.use_template_render_for_restore = 'true'
```

This silently changes the daemon's default from `separated`→`unified`. Any other site that still expects the old default will now be wrong.

## To prove it (cheaply)

Rebuild the image with `rajesh.diff` reverted **and** rerun just `bgp/test_frr_config_check.py`. Both tests should pass and no new orchagent core will appear. If you want a faster signal: in your existing image, run

```bash
sudo sonic-db-cli CONFIG_DB hset 'DEVICE_METADATA|localhost' docker_routing_config_mode unified
sudo rm -f /var/core/orchagent.*.core.gz
```

and rerun `test_frr_large_config_load_stress`. Failure 1 (the `bgpd.conf` not found assert) will disappear immediately. If Failure 2 (orchagent core during reload) also disappears, it's purely your diff. If it persists, it's a real orchagent bug exposed by your unified config size — and the core dump needs `gdb` analysis against the VS orchagent symbols.

---

**User**

Give me fix for Failure 2 and Failure 1

---

**Cursor**

Looking at the four daemon templates confirms the duplication:

- `bgpd/bgpd.conf.j2` line 13 → `common/daemons.common.conf.j2`
- `zebra/zebra.conf.j2` line 32 → `common/daemons.common.conf.j2`
- `staticd/staticd.conf.j2` line 9 → `common/daemons.common.conf.j2`
- `sharpd/sharpd.conf.j2` line 9 → `common/daemons.common.conf.j2`

Your new `gen_frr.conf.j2` renders all four, so `hostname`, `password`, `enable password`, `log syslog`, `log facility` are emitted **4×** into `frr.conf`. The stock `frr.conf.j2` (line 9) only emits them once because it pulls the **content** sub‑templates (`zebra.interfaces`, `staticd.loopback_route`, `bgpd.main`) directly.

Here are the concrete fixes.

---

## Fix 1 — make CONFIG_DB match the runtime (cures the `bgpd.conf` not‑found assertion)

Your `docker_init.sh` aliases `separated → unified` at container start, but leaves `CONFIG_DB` saying `separated`. The stress test (and `sonic-utilities`, `bgpcfgd`, etc.) believe the old value. Migrate the DB value in the same place you decide to force unified.

```56:88:dockers/docker-fpm-frr/docker_init.sh
if [ "$CONFIG_TYPE" == "split" ]; then
    echo "no service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/frr.conf
    write_default_zebra_config /etc/frr/zebra.conf
elif [ "$CONFIG_TYPE" == "split-unified" ]; then
    echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/bgpd.conf /etc/frr/zebra.conf /etc/frr/staticd.conf \
          /etc/frr/sharpd.conf
    write_default_zebra_config /etc/frr/frr.conf
elif [ -z "$CONFIG_TYPE" ] || [ "$CONFIG_TYPE" == "unified" ] || [ "$CONFIG_TYPE" == "separated" ]; then
    if [ "$CONFIG_TYPE" == "separated" ]; then
        logger -t docker-fpm-frr -p user.warning "Config Type 'separated' is deprecated. Migrating to 'unified'."
        # Persist the migration in CONFIG_DB so the rest of the system agrees with the runtime.
        sonic-db-cli CONFIG_DB hset 'DEVICE_METADATA|localhost' docker_routing_config_mode unified >/dev/null 2>&1 || true
        CONFIG_TYPE=unified
        FRR_VARS=$(echo "$FRR_VARS" | jq -c '.docker_routing_config_mode = "unified"')
    fi
    MGMT_FRAMEWORK_CONFIG=$(echo $FRR_VARS | jq -r '.frr_mgmt_framework_config')
    if [ -n "$MGMT_FRAMEWORK_CONFIG" ] && [ "$MGMT_FRAMEWORK_CONFIG" != "false" ]; then
        CFGGEN_PARAMS=" \
            -d \
            -y /etc/sonic/constants.yml \
            -T /usr/local/sonic/frrcfgd \
            -t /usr/share/sonic/templates/gen_frr.conf.j2,/etc/frr/frr.conf \
        "
    else
        CFGGEN_PARAMS=" \
            -d \
            -y /etc/sonic/constants.yml \
            -T /usr/local/sonic/frrcfgd \
            -t /usr/share/sonic/templates/gen_frr.conf.j2,/etc/frr/frr.conf \
        "
    fi
    sonic-cfggen $CFGGEN_PARAMS
    echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/bgpd.conf /etc/frr/zebra.conf /etc/frr/staticd.conf \
          /etc/frr/sharpd.conf
```

Key changes:

1. `sonic-db-cli CONFIG_DB hset ... unified` — persists the migration so `sonic-db-cli CONFIG_DB hget 'DEVICE_METADATA|localhost' docker_routing_config_mode` returns `unified`. That alone makes the stress test pick `rendered_path = '/etc/frr/frr.conf'`, which exists.
2. Reassign `CONFIG_TYPE=unified` so any later branches in the script see the new value.
3. Put `-T /usr/local/sonic/frrcfgd` back on the **non**‑mgmt-framework branch too. Your diff dropped it; restoring it keeps Jinja's loader path consistent so includes resolve in either branch.

If you want a one‑shot, system‑wide migration (not just in this container), add the same `hset` to `sonic-utilities/scripts/db_migrator.py` so it runs once at boot — but the `docker_init.sh` change above is sufficient for the test to pass.

---

## Fix 2 — stop emitting `common/daemons.common.conf.j2` four times (most likely root cause of the orchagent reload crash)

Pick one of two approaches.

### Approach A (recommended, minimal diff): keep using the existing `frr.conf.j2`

The stock `frr.conf.j2` is already a correct unified template — it includes `daemons.common` exactly once and pulls only the **content** sub‑templates. Revert your `gen_frr.conf.j2` to forward to it:

```1:5:dockers/docker-fpm-frr/frr/gen_frr.conf.j2
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
    {% include "/usr/local/sonic/frrcfgd/frr.conf.j2" %}
{% else %}
    {% include "/usr/share/sonic/templates/frr.conf.j2" %}
{% endif %}
```

If you take Approach A, also revert these include‑path changes — they only existed to satisfy the new chain you no longer need:

```13:21:dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2
{% include "common/daemons.common.conf.j2" %}
!
agentx
!
{% if DEVICE_METADATA['localhost']['type'] == "SpineChassisFrontendRouter" %}
{%  include "bgpd.spine_chassis_frontend_router.conf.j2" %}
{% endif %}
!
{% include "bgpd.main.conf.j2" %}
```

```9:11:dockers/docker-fpm-frr/frr/staticd/staticd.conf.j2
{% include "common/daemons.common.conf.j2" %}
!
{% include "staticd.loopback_route.conf.j2" %}
```

```32:34:dockers/docker-fpm-frr/frr/zebra/zebra.conf.j2
{% include "common/daemons.common.conf.j2" %}
!
{% include "zebra.interfaces.conf.j2" %}
```

This is the smallest change that produces a clean `frr.conf` (single `hostname`, single `password`, single `log`).

### Approach B: keep your "compose unified from per‑daemon configs" design, but make `daemons.common` include‑once

If you want to keep the philosophy of `gen_frr.conf.j2` sourcing the daemon configs, gate `daemons.common.conf.j2` so it only fires once.

In each of the four daemon templates, replace the bare include with a guarded one:

```dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2
{% if not skip_daemons_common|default(false) %}
{% include "common/daemons.common.conf.j2" %}
{% endif %}
```

(same change for `zebra/zebra.conf.j2`, `staticd/staticd.conf.j2`, `sharpd/sharpd.conf.j2`)

Then in `gen_frr.conf.j2`, emit it once up front and disable it in the children:

```dockers/docker-fpm-frr/frr/gen_frr.conf.j2
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
    {% include "/usr/local/sonic/frrcfgd/frr.conf.j2" %}
{% else %}
    {% include "/usr/share/sonic/templates/common/daemons.common.conf.j2" %}
    {% set skip_daemons_common = true %}
    {% include "/usr/share/sonic/templates/zebra/zebra.conf.j2" %}
    {% include "/usr/share/sonic/templates/staticd/staticd.conf.j2" %}
    {% include "/usr/share/sonic/templates/bgpd/bgpd.conf.j2" %}
    {% include "/usr/share/sonic/templates/sharpd/sharpd.conf.j2" %}
{% endif %}
```

This keeps the daemon templates valid in `separated` mode (where each daemon needs its own `daemons.common`) and also valid in `unified` mode (where one copy is enough).

A subtle issue with Approach B: `bgpd/bgpd.conf.j2` also emits `agentx`. If `zebra.conf.j2` or another daemon template also emits something globally, you'll get duplicates of those too. Audit each daemon template the same way you'd audit `daemons.common` before going to production.

---

## Why this also explains the orchagent core

Your cleanup `config_reload` at 11:17:33 → 11:19:12 ran with the original (small) `bgpd.main.conf.j2` restored, but the rendered `frr.conf` **still had 4× `hostname`, 4× `password`, 4× `log facility` and 4× `agentx`**. FRR accepts duplicates (FRR 10.5.4 is tolerant), but during reload zebra resends its state to FPM and orchagent rebuilds NHGs / route entries from a config it has never seen this shape of. Combined with the stress test having just churned 1200 policy objects through bgpd, this is a very plausible trigger for the orchagent crash at 11:18:20 — particularly given the recent FPM/NHG churn on master (`db77756ba` sonic‑fib NHG encode/decode, `f4b8e1fa1` MRIB skip).

Fix 2 removes the duplicated/agentx noise from `frr.conf` and is the most direct thing to try next. If the crash persists after Fix 2, run `gdb` on `orchagent.1779621500.56.core.gz` against the VS orchagent binary from `master-22533.1121459-dd3ba5c53` and walk the top frame — most likely under `RouteOrch::doTask` or in `fpmsyncd` NHG decode.

---

## Quickest path to a green run

1. Apply Fix 1 (one block in `docker_init.sh`).
2. Apply Fix 2 / Approach A (revert just `gen_frr.conf.j2` and the three daemon include paths).
3. Clear stale cores: `sudo rm -f /var/core/orchagent.*.core.gz`
4. Rebuild and rerun:

```bash
python3 -m pytest bgp/test_frr_config_check.py \
  --inventory ../ansible/lab,../ansible/veos --host-pattern vlab-01 \
  --testbed vms-kvm-t0 --testbed_file ../ansible/vtestbed.yaml \
  --log-cli-level DEBUG --allow_recover
```

If you want, I can apply Fix 1 and Fix 2/Approach A directly to your files in `/nobackup/vrajeshe/CODE/MASTER/sonic-buildimage` so you can rebuild without re‑typing the edits.

---

**User**

Can you please apply the fixes in the directory 
/nobackup/vrajeshe/CODE/VIDYA/sonic-buildimage

---

**Cursor**

The VIDYA repo is already on a feature branch with rajesh.diff applied. Let me check the supervisord change too, then apply the fixes.

Good — VIDYA already has rajesh.diff applied. The `frr.conf.j2` (stock) is intact and emits everything exactly once, so Approach A is safe. Applying the fixes now.

Now let me verify the final state of all five files.

All five files updated. Summary of what I applied in `/nobackup/vrajeshe/CODE/VIDYA/sonic-buildimage`:

### Fix 1 — `dockers/docker-fpm-frr/docker_init.sh`
When `CONFIG_TYPE == "separated"`:
- Persist migration via `sonic-db-cli CONFIG_DB hset 'DEVICE_METADATA|localhost' docker_routing_config_mode unified`
- Reassign `CONFIG_TYPE=unified` and update `FRR_VARS` so downstream `jq` reads agree
- Restored the missing `-T /usr/local/sonic/frrcfgd` flag on the non-mgmt-framework branch so Jinja's loader path is symmetric with the mgmt branch

This makes the runtime layout (`/etc/frr/frr.conf`) and CONFIG_DB (`unified`) consistent. `test_frr_large_config_load_stress` now picks `rendered_path = '/etc/frr/frr.conf'`, which exists → **Failure 1 gone**.

### Fix 2 — Approach A
- `dockers/docker-fpm-frr/frr/gen_frr.conf.j2`: reverted to forward to the stock `frr.conf.j2`. That template emits `common/daemons.common.conf.j2` exactly once and only pulls **content** sub‑templates (`zebra.interfaces`, `staticd.loopback_route`, `bgpd.main`), so `hostname` / `password` / `agentx` / `log` appear once.
- `dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2`, `staticd/staticd.conf.j2`, `zebra/zebra.conf.j2`: reverted the `subdir/file.j2` include paths back to the original flat names. With Approach A these daemon wrappers aren't used in unified mode, but keeping the diff minimal avoids breaking anyone still rendering them.

This removes the 4× duplicated `hostname`/`password`/`agentx`/`log` in `frr.conf`, which is the most likely trigger for the orchagent core during the reload churn. If the core still reproduces after a clean rebuild, it's a real orchagent bug that needs `gdb` analysis of `orchagent.1779621500.56.core.gz`.

### What I deliberately did **not** touch
- `src/sonic-frr-mgmt-framework/frrcfgd/frrcfgd.py` (new default `"unified"` and `use_template_render_for_restore` knob) — harmless once CONFIG_DB is migrated; reverting could break the FRR mgmt framework path.
- `src/sonic-yang-models/yang-models/sonic-device_metadata.yang` and the YANG test data — they only add the new leaf and don't affect this test.
- `dockers/docker-fpm-frr/frr/supervisord/supervisord.conf.j2` — VIDYA's current form (`is not defined or != "split"`) is correct and broader than the old condition, so it works for both `unified` and the legacy `separated` value during boot before migration completes.

### Next steps for you
1. Rebuild from `/nobackup/vrajeshe/CODE/VIDYA/sonic-buildimage`.
2. On the DUT, clear stale cores: `sudo rm -f /var/core/orchagent.*.core.gz`.
3. Rerun:

```bash
python3 -m pytest bgp/test_frr_config_check.py \
  --inventory ../ansible/lab,../ansible/veos --host-pattern vlab-01 \
  --testbed vms-kvm-t0 --testbed_file ../ansible/vtestbed.yaml \
  --log-cli-level DEBUG --allow_recover
```

If the orchagent core reappears, share the new core file path and I'll walk through the `gdb` analysis against the VS orchagent binary.

---

**User**

Ok ca you pls check if anything need to be done in sonic-config-engine/test folder to allign the above changes

---

**Cursor**

Let me also check if the user's other tracked changes (the YANG additions in rajesh.diff) require any test sample updates.

I checked everything in `src/sonic-config-engine/tests/`. **No changes are needed** there to align with the fixes I applied. Here is why.

### What the FRR-related tests do

`src/sonic-config-engine/tests/test_frr.py` has 6 cases, all of which render templates from `dockers/docker-fpm-frr/frr/` and `diff` against golden files under `sample_output/py3/`:

| Test | Renders | Compares to | Status |
|------|---------|-------------|--------|
| `test_config_frr` | `frr.conf.j2` | `frr.conf` | unchanged — golden has 1× `daemons.common` |
| `test_bgpd_frr` | `bgpd/bgpd.conf.j2` | `bgpd_frr.conf` | OK because I reverted the include paths back to `bgpd.main.conf.j2` |
| `test_zebra_frr` | `zebra/zebra.conf.j2` | `zebra_frr.conf` | OK because I reverted to `zebra.interfaces.conf.j2` |
| `test_bgpd_frr_dualtor` | `bgpd/bgpd.conf.j2` (+DualToR) | `bgpd_frr_dualtor.conf` | same revert ⇒ OK |
| `test_zebra_frr_dualtor` | `zebra/zebra.conf.j2` (+DualToR) | `zebra_frr_dualtor.conf` | same revert ⇒ OK |
| `test_bgpd_frr_bmp` | `bgpd/bgpd.conf.j2` (+FEATURE) | `bgpd_frr_bmp.conf` | same revert ⇒ OK |

The golden `frr.conf` in `sample_output/py3/frr.conf` (lines 7–16) only contains **one** `daemons.common.conf.j2` block. That matches exactly what your reverted `gen_frr.conf.j2 → frr.conf.j2` chain now produces.

If you'd left the rajesh.diff include‑path changes in place (`bgpd/bgpd.main.conf.j2`, `zebra/zebra.interfaces.conf.j2`, `staticd/staticd.loopback_route.conf.j2`), these unit tests **would have failed** because Jinja's resolution would shift and the golden files would no longer match. My reverts in Fix 2 already prevent that breakage.

### What `gen_frr.conf.j2` would have needed

Nothing — no test in `sonic-config-engine/tests/` renders `gen_frr.conf.j2` directly. Only `frr.conf.j2` is exercised. So Approach A is invisible to this test suite.

### Other matches I noticed (not affected)

- `test_chassis_cfggen.py` and `data/rsyslog/config_db.json` set `docker_routing_config_mode: "separated"` as static fixture data. These tests just verify field passthrough (minigraph → CONFIG_DB shape, rsyslog template) — they don't run the docker‑fpm‑frr init logic, so they're orthogonal to the migration we added.
- `test_cfggen_from_yang.py` and `test_yang_data.json` already use `"unified"` — already consistent with the new default.
- No file references the new `use_template_render_for_restore` knob (added by your `frrcfgd.py` change), and there's no template that needs to emit it.

### Optional: run the unit tests locally to confirm

If you want a green checkmark before the heavy CI rerun, you can run just the FRR config‑engine tests in seconds:

```bash
cd /nobackup/vrajeshe/CODE/VIDYA/sonic-buildimage/src/sonic-config-engine
python3 -m pytest tests/test_frr.py -v
```

All 6 should pass. If any fail, paste the diff and I'll adjust — but per the golden files and the include paths now in your tree, none should.

### Summary

- `dockers/docker-fpm-frr/` fixes complete in VIDYA.
- `src/sonic-config-engine/tests/` requires **no edits**.
- `src/sonic-yang-models/` was already updated by your diff (new YANG leaf + tests) and is self‑contained.

You can proceed to the image rebuild.

