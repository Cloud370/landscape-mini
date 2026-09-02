# Custom Build Guide

[Back to README](./README.md) | [中文](../zh/custom-build.md) | English

## When to Use This

Use **Custom Build** if you want to change any of these:

- network parameters
- Linux login password
- Web UI username / password
- Landscape version
- output formats

If you just want to install directly, go to the [Release page](https://github.com/Cloud370/landscape-mini/releases/latest).
If you want to import the result into PVE afterward, continue with the [PVE Installation Guide](./pve-install.md).

---

## What to Choose for Your First Run

For a first run, choose:

- `base_system=debian`
- `include_docker=false`
- `output_formats=img`

If your goal is:

- want Docker: change to `include_docker=true`
- want PVE import: change to `output_formats=img,ova`
- want a lighter image: change to `base_system=alpine`

---

## Build in 3 Steps

### Step 1: Open Actions

In your own fork of the repository:

- click **Actions** in the top bar
- find **Custom Build** in the left sidebar
- click **Run workflow**

### Step 2: Fill in the parameters

The current model uses explicit tuple fields:

- `base_system`
- `include_docker`
- `output_formats`

Common inputs:

- network parameters: `lan_server_ip`, `lan_range_start`, `lan_range_end`, `lan_netmask`
- Linux password: `root_password`
- Web UI username / password: `api_username`, `api_password`
- Landscape version: `landscape_version`
- test selection: `run_test`

`run_test` values:

- empty / `none`
- `readiness`
- `readiness,dataplane`

Notes:

- when `include_docker=true`, requested `dataplane` is explicitly skipped
- current precedence: **direct inputs > secrets > defaults**

### Step 3: Run and retrieve outputs

Click **Run workflow**. A successful build produces:

- raw `.img`
- `build-metadata.txt`
- `effective-landscape_init.toml`
- if requested, `.vmdk` / `.ova`

You now get two retrieval paths:

| Entry point | Use case | Link format |
| --- | --- | --- |
| `custom-build-latest` | stable entry for the latest successful build | `https://github.com/<owner>/landscape-mini/releases/tag/custom-build-latest` |
| `custom-build-<artifact_id>` | immutable page for this exact build | `https://github.com/<owner>/landscape-mini/releases/tag/custom-build-<artifact_id>` |

Copy-ready direct download formats:

- latest: `https://github.com/<owner>/landscape-mini/releases/download/custom-build-latest/<asset>`
- history: `https://github.com/<owner>/landscape-mini/releases/download/custom-build-<artifact_id>/<asset>`

Asset names follow the build identity deterministically:

`landscape-mini-x86-<base_system>[-docker][-lkit].<img.gz|vmdk.gz|ova>`

For example the default build (Debian + lkit) produces `landscape-mini-x86-debian-lkit.ova`.

So as long as you keep the same build options, your latest direct URL is **stable long-term**, for example:

`https://github.com/<owner>/landscape-mini/releases/download/custom-build-latest/landscape-mini-x86-debian-lkit.ova`

Every successful rebuild repoints the same URL at the newest artifacts — you can hard-code it into tutorials, scripts, or PVE's URL import field instead of hunting through the page each time.

Notes:

- `<owner>` is your fork or repository owner name
- `custom-build-latest` moves to the newest successful build
- `custom-build-<artifact_id>` stays immutable and is not replaced by later runs
- the workflow summary renders the latest page, history page, and a per-asset direct-link table, ending with a fenced "copy-ready latest links" block — copy whole lines from there
- if you also want the original workflow artifact identity, keep `run_id` / `artifact_id`

---

## How to Choose for Common Goals

### I just want my first image

Choose:

- `base_system=debian`
- `include_docker=false`
- `output_formats=img`

### I want Docker

Change:

- `include_docker=true`

### I want PVE import

Change:

- `output_formats=img,ova`

Notes:

- the workflow input name is `ova`
- the final artifact is `.ova`
- keeping `img` is recommended for testing and manual import

### I want a lighter image

Change:

- `base_system=alpine`

---

## What Can I Do After the Build?

If you have already completed one successful Custom Build, you can also use:

- **Test Image**

It is useful for:

- rerunning validation on an existing artifact
- adding readiness / dataplane checks afterward
- retesting with different SSH / API credentials

Retest entry points:

- `run_id`
- `artifact_id`

---

## FAQ

### Does `ova` replace `.img`?

No.

Keep `img`, then add `ova` when needed.

### Why does dataplane sometimes not run?

The rule is:

- `run_test=` or `run_test=none` → no tests
- `run_test=readiness` → readiness only
- `run_test=readiness,dataplane` with `include_docker=false` → readiness + dataplane
- `run_test=readiness,dataplane` with `include_docker=true` → dataplane is explicitly skipped
