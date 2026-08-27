#!/bin/bash
# Installer for the Huawei MateBook WMI Fn-mode Omarchy bar widget.
#
# Usage:
#   ./install.sh              install or refresh everything (idempotent)
#   ./install.sh --uninstall  remove everything this installer manages
#
# Privileged files installed (one password/polkit prompt):
#   /usr/local/sbin/huawei-fn-mode     root: force preferred mode at driver bind
#   /usr/local/sbin/huawei-fn-toggle   root: flip the mode (0 <-> 1)
#   /etc/udev/rules.d/99-huawei-fn-mode.rules
#   /etc/sudoers.d/huawei-fn-toggle    NOPASSWD, scoped to $USER only
#
# User-space (no prompt): the "fn-lock" module is added to the right section
# of ~/.config/omarchy/shell.json, pointing at the bar scripts in THIS
# directory. The bar scripts live in the repo itself (editable in place,
# live on the next 3-second poll) - no copies.
#
# The installer probes /sys/devices/platform/huawei-wmi/fn_lock_state and
# aborts if the driver is not loaded. Tested on: MateBook X Pro 2019
# (MACH-WX9), kernel 7.1.8. Behavior of the WMI method may differ on other
# models - check the bar widget after installing elsewhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL=0
[[ "${1:-}" == "--uninstall" ]] && UNINSTALL=1

USER="$(id -un)"
HOME_DIR="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"
SHELL_JSON="$HOME_DIR/.config/omarchy/shell.json"
BAR_SCRIPTS="$HOME_DIR/.config/omarchy/bar/scripts"
DEFAULT_SHELL_JSON="${OMARCHY_PATH:-/usr/share/omarchy}/config/omarchy/shell.json"
SUDOERS_FILE="/etc/sudoers.d/huawei-fn-toggle"
SUDOERS_OLD=("/etc/sudoers.d/$USER-fn-toggle" "/etc/sudoers.d/$USER-huawei-fn-toggle")  # legacy names from earlier versions
UDEV_RULE="/etc/udev/rules.d/99-huawei-fn-mode.rules"
SYSFS="/sys/devices/platform/huawei-wmi/fn_lock_state"

# ---- 1. driver probe -------------------------------------------------------
if [[ $UNINSTALL -eq 0 && ! -r "$SYSFS" ]]; then
  echo "error: $SYSFS not found." >&2
  echo "the huawei-wmi driver is not loaded; on kernels >= 5.5 it is built in." >&2
  echo "check: ls /sys/devices/platform/ | grep -i huawei" >&2
  exit 1
fi
[[ $UNINSTALL -eq 0 ]] && echo "driver OK: fn_lock_state = $(<"$SYSFS")"

# ---- 2. privilege escalation: real terminal -> sudo, otherwise -> pkexec ---
if [ -t 0 ]; then ESCALATE="sudo"; else ESCALATE="pkexec"; fi

# ---- 3. bar scripts: live in this repo directory, referenced in place -----
# The bar runs them directly from here; users can edit them in place and
# see the change on the next poll. Stale copies from earlier versions go.
chmod 755 "$SCRIPT_DIR/bar-fn-lock-status" "$SCRIPT_DIR/bar-fn-lock-toggle"
rm -f "$BAR_SCRIPTS/fn-lock-status" "$BAR_SCRIPTS/fn-lock-toggle"
echo "bar scripts live here: $SCRIPT_DIR/bar-fn-lock-{status,toggle}"

# ---- 4. shell.json: add/remove the fn-lock bar module ----------------------
SCRIPT_DIR="$SCRIPT_DIR" WANT_UNINSTALL=$UNINSTALL SHELL_JSON="$SHELL_JSON" DEFAULT_SHELL_JSON="$DEFAULT_SHELL_JSON" python3 - <<'PY'
import json, os, shutil, sys

path = os.environ["SHELL_JSON"]
install = os.environ.get("WANT_UNINSTALL") != "1"

if not os.path.exists(path):
    if install:
        default = os.path.expandvars(os.environ.get("DEFAULT_SHELL_JSON", ""))
        if default and os.path.exists(default):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            shutil.copy2(default, path)
            print(f"created {path} from omarchy defaults")
        else:
            print("warning: no shell.json and no omarchy default found; skipped bar layout")
            sys.exit(0)
    else:
        print("no user shell.json; nothing to remove")
        sys.exit(0)

with open(path) as f:
    cfg = json.load(f)
right = cfg.setdefault("bar", {}).setdefault("layout", {}).setdefault("right", [])

sd = os.environ["SCRIPT_DIR"]
entry = {
    "id": "fn-lock",
    "type": "command",
    "exec": sd + "/bar-fn-lock-status",
    "interval": 3,
    "onClick": sd + "/bar-fn-lock-toggle",
}

if install:
    if not any(isinstance(e, dict) and e.get("id") == "fn-lock" for e in right):
        right.append(entry)
        changed = True
    else:
        # keep in sync with current sources (e.g. after an upgrade)
        for i, e in enumerate(right):
            if isinstance(e, dict) and e.get("id") == "fn-lock":
                right[i] = entry
        changed = True
else:
    before = len(right)
    right[:] = [e for e in right if not (isinstance(e, dict) and e.get("id") == "fn-lock")]
    changed = len(right) != before

if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(f"updated:  {path} ({'added' if install else 'removed'} fn-lock module)")
else:
    print(f"unchanged: {path} (fn-lock module already in place)" if install else f"unchanged: {path}")
PY

# ---- 5. privileged step (single prompt) ------------------------------------
TMP_SCRIPT="$(mktemp /tmp/huawei-fn-install.XXXXXX)"
cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
if [[ 0 -eq $UNINSTALL ]]; then
  install -m 755 "$SCRIPT_DIR/huawei-fn-mode" /usr/local/sbin/huawei-fn-mode
  install -m 755 "$SCRIPT_DIR/huawei-fn-toggle" /usr/local/sbin/huawei-fn-toggle
  rm -f ${SUDOERS_OLD[@]}
  tmp_sudoers=\$(mktemp /tmp/sudoers.XXXXXX)
  printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/huawei-fn-toggle\n' "$USER" > "\$tmp_sudoers"
  chown root:root "\$tmp_sudoers"
  chmod 0440 "\$tmp_sudoers"
  if ! visudo -cf "\$tmp_sudoers" >/dev/null; then
    echo "error: generated sudoers file failed validation, not installed" >&2
    rm -f "\$tmp_sudoers"
    exit 1
  fi
  mv "\$tmp_sudoers" "$SUDOERS_FILE"
  cat > "$UDEV_RULE" <<'RULE'
# Force the Huawei WMI Fn-lock register to the preferred default mode
# (1 = F-keys direct, Fn+key for volume/brightness) at driver bind time.
# On models where the physical Fn+Esc key is EC-only, the WMI register is
# the sole control; managed by ~/.local/lib/huawei/fn-lock/install.sh.
SUBSYSTEM=="platform", KERNEL=="huawei-wmi", RUN+="/usr/local/sbin/huawei-fn-mode"
RULE
  chown root:root "$UDEV_RULE"
  chmod 644 "$UDEV_RULE"
  udevadm control --reload-rules
  # apply the preferred mode right away (no prompt: runs as root already)
  /usr/local/sbin/huawei-fn-mode
else
  rm -f /usr/local/sbin/huawei-fn-mode /usr/local/sbin/huawei-fn-toggle \\
        "$SUDOERS_FILE" ${SUDOERS_OLD[@]} "$UDEV_RULE"
  udevadm control --reload-rules
fi
EOF

if [[ $ESCALATE == "pkexec" ]]; then
  echo "one privilege prompt is coming up (last one needed ever)..."
  pkexec /bin/bash "$TMP_SCRIPT"
else
  sudo /bin/bash "$TMP_SCRIPT"
fi
rm -f "$TMP_SCRIPT"

# ---- 6. summary ------------------------------------------------------------
if [[ $UNINSTALL -eq 0 ]]; then
  echo
  echo "done. state = $(<"$SYSFS") (1 = F-keys direct, 0 = multimedia direct)."
  echo "the bar widget (F / FN) appears in the right section after the shell"
  echo "hot-reloads shell.json; if it does not appear, run:  omarchy-shell shell rescanPlugins"
  echo "bar scripts can be edited in place in $SCRIPT_DIR (live on the next poll)."
  echo "clicking it flips the mode silently (passwordless sudo, scoped to that one script)."
  echo "every boot the udev rule restores mode 1 (F-keys)."
else
  echo
  echo "uninstalled. the kernel driver itself is unaffected."
fi
