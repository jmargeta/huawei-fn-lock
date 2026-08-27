# huawei-fn-lock — Omarchy bar widget + boot default for the WMI Fn-lock

Shows and controls the Fn-lock state on Huawei laptops whose keyboard is
driven by the `huawei-wmi` kernel driver (mainline since Linux 5.5, see
https://github.com/aymanbagabas/Huawei-WMI).

## What it does

- **Bar widget** (`fn-lock`, right section of the omarchy bar):
  - `F` (accent color)  = F-keys mode: F1–F12 direct, Fn+key = volume/brightness/etc.
  - `FN` (normal color) = multimedia mode: top row = volume/brightness/etc., Fn+key = F-keys
  - clicking flips the mode for the session, **no password prompt** (scoped
    NOPASSWD sudoers entry for one single-purpose root script)
- **Boot default**: a udev rule runs `/usr/local/sbin/huawei-fn-mode` at
  driver-bind time, forcing F-keys mode (1) before the desktop starts —
  the "locking" is effectively disabled in favor of your preferred mode.

## Why this is needed on this model

Tested on the MateBook X Pro 2019 (MACH-WX9): the physical Fn+Esc key is
handled entirely by the keyboard controller/EC — it produces no input
event, no WMI notification, no kernel log line, and does not change the
state reported by the driver. The ACPI/WMI method (`\GFRS`/`\SFRS`,
exposed as `/sys/devices/platform/huawei-wmi/fn_lock_state`) is the only
control the OS has, and the readback only reflects values written via the
WMI method. Hence: software-forced default + clickable indicator.

**Other models may behave differently** (the physical key *is* visible on
some). The installer probes the sysfs attribute and aborts if the driver
is absent; after installing on a different machine, click the widget and
verify the top-row behavior actually changes.

## Install / uninstall

```sh
./install.sh              # idempotent; one privilege prompt (sudo in a terminal,
                          # pkexec otherwise); safe to re-run after editing sources
./install.sh --uninstall  # removes everything managed below
```

## Files managed by the installer

| File | Purpose |
|---|---|
| `bar-fn-lock-status` (this dir) | polled by the bar every 3 s (Waybar-style JSON); run **in place** from the repo, editable live |
| `bar-fn-lock-toggle` (this dir) | click handler: `sudo -n`, pkexec fallback; run **in place** from the repo |
| `~/.config/omarchy/shell.json` | the `fn-lock` module in the right bar section, pointing at the scripts in this dir (created from omarchy defaults if absent) |
| `/usr/local/sbin/huawei-fn-mode` | **root-owned copy**: force preferred mode (1) at driver bind |
| `/usr/local/sbin/huawei-fn-toggle` | **root-owned copy**: flip 0 <-> 1; no arguments accepted |
| `/etc/udev/rules.d/99-huawei-fn-mode.rules` | root-owned; triggers the mode script at driver bind |
| `/etc/sudoers.d/huawei-fn-toggle` | root-owned 0440; `NOPASSWD` for the installing user, scoped to the toggle script only (validated with `visudo` before install) |

The repo is the single source of truth; `install.sh` is a one-way build
step. The user-space scripts are referenced in place, while the privileged
files are *copied* into root-owned locations (see security notes). Re-run
`./install.sh` after editing the privileged sources or after moving this
directory (it re-points the `shell.json` entry at the new path). Note:
paths containing spaces are not supported (the bar runs the scripts as a
plain command line).

## Security notes

- The only privilege granted is `NOPASSWD: /usr/local/sbin/huawei-fn-toggle`
  for the user who ran the installer. That script takes no arguments and
  can only write the literals `0` or `1` to the one sysfs register.
- The privileged files are **copies**, not symlinks into this directory.
  This directory is user-writable, and any user-writable file — or file in
  a user-writable directory, since the directory owner can replace it at
  any time — that root executes or reads as policy (sudo's NOPASSWD
  target, udev rules, `/etc/sudoers.d` entries) is a local privilege
  escalation: edit it, and it runs as root next boot or next click. Root
  additionally refuses `/etc/sudoers.d` files that are not `root:root 0440`.
  Root-owned locations in `/etc` and `/usr/local/sbin` are the only
  places that survive that; the udev rule also needs the root filesystem
  because driver bind can happen before an encrypted/NFS home is mounted.
- Nothing in `/usr/share/omarchy/` is touched.
- The kernel `huawei-wmi` driver itself is not modified or removed by
  the uninstall (on most distro kernels it is built in).
