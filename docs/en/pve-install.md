# Proxmox VE (PVE) Installation Guide

[Back to README](./README.md) | [中文](../zh/pve-install.md) | English

## When to Use This

This document covers only two things:

- importing a ready-made image into PVE
- importing an image you built yourself into PVE

If you have not built an image yet, start with the [Custom Build Guide](./custom-build.md).

---

## Pick a Path First

| Your situation | Go to |
|---|---|
| Using the repository Release directly | See “Recommended Path” below |
| You already have `.ova` | See “Method 1: Import OVA by URL” |
| You already have `.img` / `.img.gz` | See “Method 2: Manual `.img` / `.img.gz` import” |

## Recommended Path

1. If the repository Release image works for your case, install it directly first
2. If you need custom parameters, use the [Custom Build Guide](./custom-build.md)
3. For a first custom build, use `base_system=debian`, `include_docker=true`, `output_formats=img,ova`
4. In PVE, prefer `.ova` import; if that is inconvenient, use `.img` / `.img.gz`

## Recommended Build Choice

If this is your first time, use:

- `base_system=debian`
- `include_docker=true`
- `output_formats=img,ova`

Reasons:

- `base_system=debian`: default recommendation
- `include_docker=true`: avoids installing Docker later
- `output_formats=img,ova`: keeps both `.ova` import and `.img` manual import paths

> If you do not need custom parameters, prefer the prebuilt image from the repository Release.

---

## Before You Start

Please confirm:

- you have a working PVE node
- you already have the build output: recommended `.ova`, fallback `.img` / `.img.gz`
- you know which storage pool to import into
- you can log in to the PVE Web UI
- if you are using manual import, you can also log in to the PVE host over SSH

---

## With Multiple NICs, NIC Types Must Match

If the VM has multiple NICs, make sure they use the same model, for example all `E1000` or all `VirtIO`.

If NIC models are mixed, you may see:

- WAN / LAN order reversed
- `eth0` missing an IP address
- `eth0` / `eth1` order not matching your expectation

How to fix it:

1. Open the VM’s **Hardware** page in PVE
2. Check the model/type of all NICs
3. Change them to the same model
4. **Restart the VM**

---

## Method 1: Import OVA by URL

Prefer the official Release `.ova` download link from this repository.

If you are using `Custom Build`, the `.ova` download link is deterministic — see the formula in Step 3 — or copy it from the fenced "copy-ready latest links" block at the end of the workflow summary.

### Step 1: Confirm the storage pool allows import

In the **left sidebar**, find the target storage entry (for example `local`) and click it.

In the right panel, click **Edit** and make sure **Content** includes:

- `Import`
- `Disk image`

### Step 2: Open the import page

Click the same storage in the left sidebar; the right panel lists its sub-pages — pick **Content**.

Find the **Download from URL / Import** entry.

### Step 3: Paste the download link

- Official Release: copy the download link of the target `.ova`
- Custom Build: the link is deterministic — build it as `https://github.com/<your-username>/landscape-mini/releases/download/custom-build-latest/landscape-mini-x86-<base>[-docker][-lkit].ova` (the default build yields `landscape-mini-x86-debian-lkit.ova`); or open the workflow run page and copy a whole line from the fenced "copy-ready latest links" block at the end of the summary

Then paste the link into the PVE URL import field.

### Step 4: Run the import

Confirm the target storage, then start the import.

### Step 5: Check the imported VM configuration

Check at least:

- boot mode
- disk controller
- bridge binding
- CPU type
- NIC model

Notes:

- on older CPUs, you may want to set `CPU type=host` manually
- PVE does not reliably inherit `CPU type=host` from OVF/OVA metadata

---

## Method 2: Manual `.img` or `.img.gz` Import

If you do not want to use OVA, or OVA import is inconvenient, use raw image import.

### Step 1: Create the VM in PVE first

When creating the VM:

- fill in the VM name, ID, and other settings normally
- **do not add a disk**
- keep the other settings as defaults or adjust them as needed

### Step 2: Put `.img` or `.img.gz` on the PVE host

Common methods:

#### Method A: Download directly on the PVE host

If you are using the official Release, copy the `.img.gz` download link, then SSH into the PVE host and run:

```bash
wget -O landscape-mini.img.gz "<official Release download URL>"
```

If you are using `Custom Build`, copy the `.img` / `.img.gz` download link from your own workflow artifact page or fixed release page, then use the same download flow.

If the file is `.img.gz`, decompress it first:

```bash
gunzip -f landscape-mini.img.gz
```

#### Method B: Upload manually from your local machine

You can also upload it to the PVE host with `scp`, `rsync`, SFTP, or any other method you prefer.

For example:

```bash
scp landscape-mini.img root@<pve-host>:/root/
```

If you uploaded `.img.gz`, decompress it afterward:

```bash
gunzip -f /root/landscape-mini.img.gz
```

### Step 3: Import the disk into PVE

Log in to the PVE host and run:

```bash
qm importdisk <vmid> /path/to/landscape-mini.img <storage>
```

For example:

```bash
qm importdisk 101 /root/landscape-mini.img local-lvm
```

Where:

- `<vmid>`: VM ID
- `/path/to/landscape-mini.img`: image path
- `<storage>`: target storage pool name

### Step 4: Attach the imported disk in the VM hardware page

Go back to the PVE Web UI:

**VM -> Hardware**

Find the imported disk and attach it to the slot you want to use, for example `scsi0` or `sata0`.

Then set:

- boot order
- that disk as the boot disk

---

## First Boot Checks

After starting the VM, run:

```bash
ip a
```

Focus on:

- whether `eth0` got the expected IP address
- whether `eth1` matches the other NIC you intended
- whether WAN / LAN match your bridge wiring and configuration

If `eth0` has no IP, or the `eth0` / `eth1` order looks wrong, first check whether all NICs use the same model.

---

## Disk Expansion

Landscape Mini automatically expands the root partition to the current disk size at boot.

This means:

- on the **first boot**, it expands to the current disk size automatically
- if you enlarge the disk later in PVE, it expands again on the **next reboot**

### How to expand the disk in PVE

Go to:

**VM -> Hardware -> select disk -> Disk Action -> Resize**

For example, you can start by adding:

- **16G**

### Note

Hot expansion is **not applied immediately**.

After resizing the disk in PVE, you need to **restart the VM** before the expansion takes effect.

---

## FAQ

### Why does URL import fail?

First confirm the target storage has these content types enabled:

- `Import`
- `Disk image`

Path:

**left sidebar -> target storage (for example `local`) -> right panel: Edit -> Content**

### What should I do if I get this error?

```text
sata0: import working storage 'local' does not support 'images' content type or is not filebased
```

This usually means:

- the selected working storage does not have `Disk image` enabled
- or it is not a file-based storage suitable for this import flow

How to fix it:

1. In the left sidebar click **local**, then **Edit** in the right panel
2. Make sure **Content** includes `Import` and `Disk image`
3. If it still fails, switch to a directory-based storage that supports file-based import, or use manual `.img` import instead

### Chinese shows as little boxes in the PVE console

The PVE web console (noVNC) shows the VM's **kernel console** framebuffer. The Linux kernel console font can only load ~512 glyphs — far short of any CJK character set — so every Chinese character renders as a box. This is an inherent kernel-console limitation, not a noVNC or image defect.

For Chinese interaction (e.g. `lkit`'s Chinese TUI) use instead:

- SSH: rendered by your local terminal, full font coverage
- Landscape's web terminal: rendered by the browser

To get a proper Chinese-capable "console", add a serial port to the VM (rendering then happens browser-side as well):

- Web UI: VM → Hardware → Add → Serial Port
- or from the PVE host shell: `qm set <vmid> --serial0 socket`

The console dropdown then offers an **xterm.js** terminal — select it and Chinese renders correctly.

Note: the serial port **cannot** be embedded in the OVA — PVE's OVF importer does not create hardware for serial entries, and some importers (certain VMware paths included) even fail outright on OVF serial items; add the serial port once after import as above.

### Why does `eth0` not have an IP after boot?

Check these first:

- whether the VM has multiple NICs
- whether all NICs use the same model

If NIC models are mixed, you may get `eth0` / `eth1` order issues, or `eth0` may fail to get the expected IP address.

How to fix it:

1. Change all NICs to the same model
2. Restart the VM
3. Run `ip a` again

### What should I still check after OVA import?

Check at least:

- boot mode
- disk controller
- bridge binding
- CPU type
- whether NIC types are consistent

On older CPUs, it is usually worth setting `CPU type=host` manually.

### Why does the disk size not increase immediately after import?

Because expansion currently takes effect **at boot time**.

If you just resized the disk in PVE, restart the VM and the expansion will be applied on the next boot.
