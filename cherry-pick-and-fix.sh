#!/usr/bin/env bash
# cherry-pick-and-fix.sh
#
# Cherry-pick a list of upstream patches into an Ubuntu kernel tree, run the
# same static build-break sniff test as cherry-pick-patches.sh, and then
# automatically apply SAUCE fix-up commits for the issues found:
#
#   1. Missing system headers in new C/H files  ->  substitute with the v6.8
#      equivalents (linux/unaligned.h -> asm/unaligned.h, linux/device/devres.h
#      -> linux/device.h).
#   2. Unannotated CONFIG_* symbols introduced by new Kconfig files  ->  add
#      policy<...> lines to debian.master/config/annotations.
#   3. dpll_device_ops fields used by new code but missing from the in-tree
#      header  ->  graft the missing field declarations onto struct
#      dpll_device_ops in include/linux/dpll.h, and add the missing UAPI
#      enums (dpll_lock_status_error, dpll_feature_state) to include/uapi/
#      linux/dpll.h.
#
# Each auto-fix is committed as a distinct "UBUNTU: SAUCE:" commit with the
# requested BugLink/backport-trailer format.
#
# This script intentionally does NOT auto-fix everything. The header
# substitution table and the DPLL-shim are hardcoded for the zl3073x case
# that has been validated. Other issue classes (e.g. UAPI constants the
# heuristic UAPI check flags) are reported but not auto-fixed -- the script
# tells you what's left for a human.
#
# Usage:
#   cherry-pick-and-fix.sh \
#       --patches /path/to/patches.txt \
#       --bug 2133147 \
#       [--repo /path/to/kernel/tree] \
#       [--signoff "Name <email>"] \
#       [--no-sign] [--reverse|--no-reverse] [--no-sniff] [--no-autofix]
#       [--dry-run]

set -uo pipefail

# ---------- defaults ----------
PATCHES_FILE=""
BUG=""
REPO="${PWD}"
SIGNOFF=""
NO_SIGN=0
REVERSE=1
RUN_SNIFF=1
RUN_AUTOFIX=1
DRY_RUN=0

usage() {
  sed -n '2,/^$/p' "$0" | sed -e 's/^# \{0,1\}//'
  exit "${1:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --patches)    PATCHES_FILE="$2"; shift 2 ;;
    --bug)        BUG="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --signoff)    SIGNOFF="$2"; shift 2 ;;
    --no-sign)    NO_SIGN=1; shift ;;
    --reverse)    REVERSE=1; shift ;;
    --no-reverse) REVERSE=0; shift ;;
    --no-sniff)   RUN_SNIFF=0; shift ;;
    --no-autofix) RUN_AUTOFIX=0; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "$PATCHES_FILE" ] || { echo "ERROR: --patches is required" >&2; usage 1; }
[ -n "$BUG" ]          || { echo "ERROR: --bug is required" >&2; usage 1; }
[ -f "$PATCHES_FILE" ] || { echo "ERROR: patches file not found: $PATCHES_FILE" >&2; exit 1; }
[ -d "$REPO/.git" ]    || { echo "ERROR: $REPO is not a git repository" >&2; exit 1; }

if [ -z "$SIGNOFF" ]; then
  _name="$(git -C "$REPO" config user.name || true)"
  _mail="$(git -C "$REPO" config user.email || true)"
  if [ -n "$_name" ] && [ -n "$_mail" ]; then
    SIGNOFF="$_name <$_mail>"
  else
    echo "ERROR: no --signoff and git user.name/user.email not configured" >&2
    exit 1
  fi
fi

SIGNOFF_EMAIL="$(printf '%s' "$SIGNOFF" | sed -nE 's/.*<([^>]+)>.*/\1/p')"
[ -n "$SIGNOFF_EMAIL" ] || { echo "ERROR: --signoff must be 'Name <email>': $SIGNOFF" >&2; exit 1; }

BUGLINK="BugLink: https://bugs.launchpad.net/bugs/${BUG}"
GIT_SIGN_FLAGS=()
[ "$NO_SIGN" -eq 1 ] && GIT_SIGN_FLAGS=(-c commit.gpgsign=false)

echo "==> Repo:     $REPO"
echo "==> Patches:  $PATCHES_FILE"
echo "==> Bug:      $BUG"
echo "==> Signoff:  $SIGNOFF"
echo "==> Signing:  $([ $NO_SIGN -eq 1 ] && echo 'disabled (--no-sign)' || echo 'per git config')"
echo "==> Reverse:  $([ $REVERSE -eq 1 ] && echo 'yes (oldest first)' || echo 'no')"
echo "==> Sniff:    $([ $RUN_SNIFF -eq 1 ] && echo 'enabled' || echo 'disabled')"
echo "==> Autofix:  $([ $RUN_AUTOFIX -eq 1 ] && echo 'enabled' || echo 'disabled')"
echo "==> Dry-run:  $([ $DRY_RUN -eq 1 ] && echo 'yes' || echo 'no')"
echo

WORK="$(mktemp -d -t cherry-pick-and-fix.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------- editor that injects BugLink + strips 3rd-party signoffs ----------
EDITOR_SCRIPT="$WORK/buglink-editor.sh"
cat > "$EDITOR_SCRIPT" <<EDITOR
#!/usr/bin/env bash
set -e
f="\$1"
buglink="$BUGLINK"
my_email_re='$(printf '%s' "$SIGNOFF_EMAIL" | sed -e 's/[].\\\$*+?[^|(){}]/\\\\&/g')'

awk -v bl="\$buglink" -v myre="\$my_email_re" '
  BEGIN { subject_done = 0 }
  /^[Ss]igned-off-by:/ {
    if (\$0 ~ myre) { print; next } else { next }
  }
  /^#/ { print; next }
  {
    print
    if (!subject_done) {
      subject_done = 1
      if ((getline nxt) > 0) {
        if (nxt == "") { print ""; print bl; print "" }
        else           { print ""; print bl; print ""; print nxt }
      } else {
        print ""; print bl
      }
    }
  }
' "\$f" > "\$f.tmp"
mv "\$f.tmp" "\$f"
EDITOR
chmod +x "$EDITOR_SCRIPT"

# ---------- order SHAs ----------
SHAS_RAW="$WORK/shas.raw"
SHAS_ORDERED="$WORK/shas.ordered"
awk 'NF && $1 !~ /^#/ {print $1}' "$PATCHES_FILE" > "$SHAS_RAW"
if [ $REVERSE -eq 1 ]; then tac "$SHAS_RAW" > "$SHAS_ORDERED"
else cp "$SHAS_RAW" "$SHAS_ORDERED"; fi

TOTAL=$(wc -l < "$SHAS_ORDERED" | tr -d ' ')
[ "$TOTAL" -gt 0 ] || { echo "ERROR: no SHAs in $PATCHES_FILE" >&2; exit 1; }
echo "==> $TOTAL patches to apply"

# ---------- preflight ----------
echo "==> Verifying all SHAs resolve..."
MISSING=0
while read -r sha; do
  git -C "$REPO" cat-file -t "$sha" >/dev/null 2>&1 || {
    echo "    MISSING: $sha"; MISSING=$((MISSING+1))
  }
done < "$SHAS_ORDERED"
[ "$MISSING" -eq 0 ] || { echo "ERROR: $MISSING SHA(s) not reachable" >&2; exit 1; }
echo "    all $TOTAL SHAs reachable."

[ -z "$(git -C "$REPO" status --porcelain)" ] || {
  echo "ERROR: working tree is not clean" >&2; exit 1;
}

if [ $DRY_RUN -eq 1 ]; then
  echo "==> Dry run; would apply:"
  awk '{printf "    [%d] %s\n", NR, $0}' "$SHAS_ORDERED"
  exit 0
fi

BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
echo "==> Base before cherry-pick stack: $BASE_SHA"
echo

# ---------- cherry-pick loop ----------
LOG="$WORK/picked.log"
: > "$LOG"
COUNT=0
while read -r sha; do
  COUNT=$((COUNT+1))
  printf "[%2d/%d] picking %s ... " "$COUNT" "$TOTAL" "$sha"
  if GIT_EDITOR="$EDITOR_SCRIPT" GIT_SEQUENCE_EDITOR="$EDITOR_SCRIPT" \
       git -C "$REPO" "${GIT_SIGN_FLAGS[@]}" cherry-pick -x -e -s "$sha" \
       >>"$LOG" 2>&1; then
    echo "OK"
  else
    echo "FAILED"
    echo
    echo "==> Conflict on $sha. Resolve, then git cherry-pick --continue (or --abort)."
    tail -30 "$LOG" | sed 's/^/    /'
    exit 2
  fi
done < "$SHAS_ORDERED"

echo
echo "==> All $TOTAL patches applied."

# ---------- trailer hygiene ----------
echo "==> Verifying commit-message trailers..."
BAD=0
RANGE="${BASE_SHA}..HEAD"
while read -r h s; do
  l3="$(git -C "$REPO" log -1 --format=%B "$h" | sed -n '3p')"
  [ "$l3" = "$BUGLINK" ] || { echo "    BUGLINK NOT ON LINE 3: $h $s"; BAD=$((BAD+1)); }
done < <(git -C "$REPO" log --format="%H %s" "$RANGE")
while read -r h s; do
  ct=$(git -C "$REPO" log -1 --format=%B "$h" | grep -ci '^signed-off-by:' || true)
  cm=$(git -C "$REPO" log -1 --format=%B "$h" | grep -ci "signed-off-by:.*<${SIGNOFF_EMAIL}>" || true)
  [ "$ct" -ge 1 ] && [ "$cm" -ge 1 ] || { echo "    SIGNOFF MISSING: $h $s"; BAD=$((BAD+1)); }
  [ "$ct" = "$cm" ] || { echo "    LEFTOVER 3RD-PARTY SIGNOFF: $h $s"; BAD=$((BAD+1)); }
done < <(git -C "$REPO" log --format="%H %s" "$RANGE")
[ "$BAD" -eq 0 ] && echo "    OK: all $TOTAL commits have correct trailers" \
                || echo "    WARN: $BAD trailer issue(s)"
echo

# ---------- sniff test ----------
SNIFF_HEADERS_MISSING="$WORK/issues.headers"   # one "header\tuser-file" per line
SNIFF_KCONFIG_MISSING="$WORK/issues.kconfig"   # one CONFIG_* per line
SNIFF_DPLL_FIELDS="$WORK/issues.dpllops"       # one .field per line
SNIFF_UAPI_MISSING="$WORK/issues.uapi"         # one SYMBOL per line
: > "$SNIFF_HEADERS_MISSING"
: > "$SNIFF_KCONFIG_MISSING"
: > "$SNIFF_DPLL_FIELDS"
: > "$SNIFF_UAPI_MISSING"

if [ $RUN_SNIFF -eq 1 ]; then
  echo "==> Static build-sniff test"
  CHANGED_NEW="$WORK/changed.new"
  git -C "$REPO" diff --name-status "$RANGE" | awk '$1=="A"{print $2}' > "$CHANGED_NEW"
  NEW_C_H=$(grep -E '\.(c|h)$' "$CHANGED_NEW" || true)

  # (a) missing system headers
  if [ -n "$NEW_C_H" ]; then
    echo "  -- header presence check on new C/H files --"
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      grep -oE '^[[:space:]]*#include[[:space:]]+<[^>]+>' "$REPO/$f" 2>/dev/null \
        | sed -E 's@.*<([^>]+)>.*@\1@' || true
    done <<< "$NEW_C_H" | sort -u > "$WORK/headers.uniq"
    while IFS= read -r h; do
      [ -z "$h" ] && continue
      case "$h" in asm/*|asm-generic/*) continue ;; esac
      if [ ! -e "$REPO/include/$h" ]; then
        echo "    HEADER MISSING IN TREE: $h"
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          if grep -qE "^[[:space:]]*#include[[:space:]]+<${h//./\\.}>" "$REPO/$f" 2>/dev/null; then
            echo "        used by: $f"
            printf '%s\t%s\n' "$h" "$f" >> "$SNIFF_HEADERS_MISSING"
          fi
        done <<< "$NEW_C_H"
      fi
    done < "$WORK/headers.uniq"
  fi

  # (b) unannotated Kconfig symbols
  if [ -f "$REPO/debian.master/config/annotations" ]; then
    NEW_KCONFIG=$(grep -E '/Kconfig$|/Kconfig\.[A-Za-z0-9_-]+$' "$CHANGED_NEW" || true)
    if [ -n "$NEW_KCONFIG" ]; then
      echo "  -- annotations vs new Kconfig --"
      while IFS= read -r kf; do
        [ -z "$kf" ] && continue
        SYMS=$(grep -E '^[[:space:]]*(config|menuconfig)[[:space:]]+[A-Z0-9_]+' "$REPO/$kf" 2>/dev/null \
                 | awk '{print "CONFIG_" $2}' | sort -u)
        while IFS= read -r sym; do
          [ -z "$sym" ] && continue
          if ! grep -q "^${sym}[[:space:]]" "$REPO/debian.master/config/annotations"; then
            echo "    UNANNOTATED KCONFIG SYMBOL: $sym (declared in $kf)"
            echo "$sym" >> "$SNIFF_KCONFIG_MISSING"
          fi
        done <<< "$SYMS"
      done <<< "$NEW_KCONFIG"
    fi
  fi

  # (c) dpll ops fields missing from in-tree header
  if [ -f "$REPO/include/linux/dpll.h" ] && [ -n "$NEW_C_H" ]; then
    NEW_DPLL_USERS=$(grep -lE 'struct dpll_(device|pin)_ops [a-zA-Z_0-9]+ *=' \
                       $(printf '%s\n' "$NEW_C_H" | sed "s|^|$REPO/|") 2>/dev/null || true)
    if [ -n "$NEW_DPLL_USERS" ]; then
      echo "  -- dpll ops fields vs in-tree dpll.h --"
      DPLL_HDR_TXT="$WORK/dpll.h.txt"
      cat "$REPO/include/linux/dpll.h" "$REPO/include/uapi/linux/dpll.h" > "$DPLL_HDR_TXT"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        grep -nE '^\s*\.[a-zA-Z_]+\s*=' "$f" 2>/dev/null | while read -r ln; do
          member=$(printf '%s' "$ln" | sed -nE 's@^[^.]*\.([a-zA-Z_][a-zA-Z_0-9]*)\s*=.*@\1@p')
          [ -z "$member" ] && continue
          case "$member" in
            board_label|panel_label|package_label|type|capabilities|freq_supported|freq_supported_num|phase_range) continue ;;
          esac
          if ! grep -qE "\(\*${member}\)\s*\(" "$DPLL_HDR_TXT"; then
            echo "    DPLL OPS FIELD NOT IN HEADER: .$member  ($f: ${ln%%:*})"
            echo "$member" >> "$SNIFF_DPLL_FIELDS"
          fi
        done
      done <<< "$NEW_DPLL_USERS"
      sort -u -o "$SNIFF_DPLL_FIELDS" "$SNIFF_DPLL_FIELDS"
    fi
  fi

  # (d) heuristic UAPI constants used but not defined under include/
  if [ -n "$NEW_C_H" ]; then
    echo "  -- UAPI constant usage (heuristic) --"
    : > "$WORK/suspect.const"
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      grep -ohE '\b(DPLL|NL80211|ETHTOOL|BPF|TC|XDP)_[A-Z0-9_]+' "$REPO/$f" 2>/dev/null || true
    done <<< "$NEW_C_H" | sort -u > "$WORK/suspect.const"
    while IFS= read -r sym; do
      [ -z "$sym" ] && continue
      if ! grep -qrE "\b${sym}\b" "$REPO/include/" 2>/dev/null; then
        echo "    UAPI/INCLUDE CONSTANT NOT FOUND: $sym"
        echo "$sym" >> "$SNIFF_UAPI_MISSING"
      fi
    done < "$WORK/suspect.const"
  fi
  echo
fi

TOTAL_ISSUES=$(( $(wc -l < "$SNIFF_HEADERS_MISSING") \
              + $(wc -l < "$SNIFF_KCONFIG_MISSING") \
              + $(wc -l < "$SNIFF_DPLL_FIELDS") \
              + $(wc -l < "$SNIFF_UAPI_MISSING") ))

if [ $RUN_SNIFF -eq 1 ]; then
  if [ "$TOTAL_ISSUES" -eq 0 ]; then
    echo "==> Sniff test: clean."
    exit 0
  fi
  echo "==> Sniff test: $TOTAL_ISSUES potential build-break issue(s) flagged above."
fi

if [ $RUN_AUTOFIX -eq 0 ] || [ "$TOTAL_ISSUES" -eq 0 ]; then
  exit 3
fi

echo
echo "================================================================"
echo "==> Auto-fix phase"
echo "================================================================"
echo

# Helper: commit current index as a SAUCE patch with the required trailer
sauce_commit() {
  local subject="$1"
  local body="$2"
  local note="$3"

  if [ -z "$(git -C "$REPO" diff --cached --name-only)" ]; then
    echo "    nothing staged for: $subject  (skipping commit)"
    return 0
  fi

  git -C "$REPO" "${GIT_SIGN_FLAGS[@]}" commit -m "$(cat <<EOF
$subject

$BUGLINK

$body

[$(printf '%s' "$SIGNOFF" | sed -E 's/ *<[^>]+>//'): $note]
Signed-off-by: $SIGNOFF
EOF
)" >/dev/null
  echo "    committed: $subject"
}

# ---------- autofix #1: header substitutions ----------
if [ -s "$SNIFF_HEADERS_MISSING" ]; then
  echo "==> Autofix: substitute missing system headers"

  declare -A HEADER_SUB
  HEADER_SUB[linux/unaligned.h]='asm/unaligned.h'
  HEADER_SUB[linux/device/devres.h]='linux/device.h'

  while IFS=$'\t' read -r h f; do
    sub="${HEADER_SUB[$h]:-}"
    if [ -z "$sub" ]; then
      echo "    NO RULE for $h in $f (skipping; add to HEADER_SUB table)"
      continue
    fi
    if grep -q "<${sub}>" "$REPO/$f"; then
      # Already includes the substitute -> just drop the offending include.
      sed -i -E "/^[[:space:]]*#include[[:space:]]+<${h//./\\.}>/d" "$REPO/$f"
      echo "    $f: dropped <$h> (already includes <$sub>)"
    else
      sed -i -E "s@^([[:space:]]*)#include[[:space:]]+<${h//./\\.}>@\\1#include <${sub}>@" "$REPO/$f"
      echo "    $f: <$h> -> <$sub>"
    fi
    git -C "$REPO" add "$f"
  done < <(sort -u "$SNIFF_HEADERS_MISSING")

  sauce_commit \
    "UBUNTU: SAUCE: dpll: zl3073x: fix v6.8 header includes" \
"The cherry-picked driver uses post-v6.10 headers that do not exist on
the v6.8 base. Substitute the v6.8-era equivalents so the driver
builds:

  linux/unaligned.h      -> asm/unaligned.h
  linux/device/devres.h  -> linux/device.h

No functional change." \
    "backport - header substitutions for v6.8; no upstream commit (pure compatibility shim)"
fi

# ---------- autofix #2: dpll ops + UAPI enums ----------
NEED_DPLL_SHIM=0
[ -s "$SNIFF_DPLL_FIELDS" ] && NEED_DPLL_SHIM=1
# UAPI enums we know how to add (and only these):
NEED_DPLL_FEATURE_STATE=0
NEED_LOCK_STATUS_ERROR=0
if grep -q '^DPLL_FEATURE_STATE_' "$SNIFF_UAPI_MISSING"; then
  NEED_DPLL_FEATURE_STATE=1
  NEED_DPLL_SHIM=1
fi
# .lock_status_error in dpll_device_ops requires the enum too -- detect it
# either from the ops-field check or from a textual scan of the new code.
if grep -q 'dpll_lock_status_error' "$REPO"/drivers/dpll/zl3073x/*.[ch] 2>/dev/null; then
  NEED_LOCK_STATUS_ERROR=1
  NEED_DPLL_SHIM=1
fi

if [ $NEED_DPLL_SHIM -eq 1 ]; then
  echo "==> Autofix: extend include/linux/dpll.h and UAPI for new ops/enums"

  # --- UAPI enums ---
  UAPI="$REPO/include/uapi/linux/dpll.h"
  if [ $NEED_LOCK_STATUS_ERROR -eq 1 ] && ! grep -q 'enum dpll_lock_status_error' "$UAPI"; then
    # Insert after enum dpll_lock_status block (ends with the matching };)
    awk '
      /^enum dpll_lock_status \{/ { in_block=1 }
      { print }
      in_block && /^\};/ {
        in_block=0
        print ""
        print "enum dpll_lock_status_error {"
        print "\tDPLL_LOCK_STATUS_ERROR_NONE = 1,"
        print "\tDPLL_LOCK_STATUS_ERROR_UNDEFINED,"
        print "\tDPLL_LOCK_STATUS_ERROR_MEDIA_DOWN,"
        print "\tDPLL_LOCK_STATUS_ERROR_FRACTIONAL_FREQUENCY_OFFSET_TOO_HIGH,"
        print ""
        print "\t/* private: */"
        print "\t__DPLL_LOCK_STATUS_ERROR_MAX,"
        print "\tDPLL_LOCK_STATUS_ERROR_MAX = (__DPLL_LOCK_STATUS_ERROR_MAX - 1)"
        print "};"
      }
    ' "$UAPI" > "$UAPI.tmp" && mv "$UAPI.tmp" "$UAPI"
    echo "    UAPI: added enum dpll_lock_status_error"
  fi
  if [ $NEED_DPLL_FEATURE_STATE -eq 1 ] && ! grep -q 'enum dpll_feature_state' "$UAPI"; then
    awk '
      done==1 { print; next }
      /^enum dpll_lock_status_error \{/ { in_block=1 }
      { print }
      in_block && /^\};/ && done==0 {
        in_block=0; done=1
        print ""
        print "enum dpll_feature_state {"
        print "\tDPLL_FEATURE_STATE_DISABLE,"
        print "\tDPLL_FEATURE_STATE_ENABLE,"
        print "};"
      }
    ' "$UAPI" > "$UAPI.tmp" && mv "$UAPI.tmp" "$UAPI"
    echo "    UAPI: added enum dpll_feature_state"
  fi
  git -C "$REPO" add "$UAPI"

  # --- struct dpll_device_ops ---
  HDR="$REPO/include/linux/dpll.h"
  # Update lock_status_get signature only if status_error parameter is used.
  if [ $NEED_LOCK_STATUS_ERROR -eq 1 ] && ! grep -q 'status_error' "$HDR"; then
    sed -i -E '/int \(\*lock_status_get\)/,/struct netlink_ext_ack \*extack\);/ {
      s@(enum dpll_lock_status \*status,)@\1\n\t\t\t       enum dpll_lock_status_error *status_error,@
    }' "$HDR"
    echo "    dpll.h: lock_status_get gained status_error parameter"
  fi
  # Inject any missing ops fields right before the closing }; of dpll_device_ops.
  while IFS= read -r member; do
    [ -z "$member" ] && continue
    grep -qE "\(\*${member}\)\s*\(" "$HDR" && continue
    case "$member" in
      phase_offset_monitor_set)
        snippet='\tint (*phase_offset_monitor_set)(const struct dpll_device *dpll,\n\t\t\t\t\tvoid *dpll_priv,\n\t\t\t\t\tenum dpll_feature_state state,\n\t\t\t\t\tstruct netlink_ext_ack *extack);'
        ;;
      phase_offset_monitor_get)
        snippet='\tint (*phase_offset_monitor_get)(const struct dpll_device *dpll,\n\t\t\t\t\tvoid *dpll_priv,\n\t\t\t\t\tenum dpll_feature_state *state,\n\t\t\t\t\tstruct netlink_ext_ack *extack);'
        ;;
      phase_offset_avg_factor_set)
        snippet='\tint (*phase_offset_avg_factor_set)(const struct dpll_device *dpll,\n\t\t\t\t\t   void *dpll_priv, u32 factor,\n\t\t\t\t\t   struct netlink_ext_ack *extack);'
        ;;
      phase_offset_avg_factor_get)
        snippet='\tint (*phase_offset_avg_factor_get)(const struct dpll_device *dpll,\n\t\t\t\t\t   void *dpll_priv, u32 *factor,\n\t\t\t\t\t   struct netlink_ext_ack *extack);'
        ;;
      *)
        echo "    NO TEMPLATE for ops field .$member -- add a snippet to the script"
        continue
        ;;
    esac
    awk -v snippet="$snippet" '
      in_block && /^\};/ && !injected {
        # Print snippet with literal \n -> newlines, \t -> tabs.
        gsub(/\\n/, "\n", snippet)
        gsub(/\\t/, "\t", snippet)
        print snippet
        injected=1
      }
      /^struct dpll_device_ops \{/ { in_block=1 }
      /^\};/ && in_block { in_block=0 }
      { print }
    ' "$HDR" > "$HDR.tmp" && mv "$HDR.tmp" "$HDR"
    echo "    dpll.h: added .$member to struct dpll_device_ops"
  done < "$SNIFF_DPLL_FIELDS"
  git -C "$REPO" add "$HDR"

  sauce_commit \
    "UBUNTU: SAUCE: dpll: backport phase_offset_{monitor,avg_factor} ops and lock_status_error" \
"The cherry-picked zl3073x driver assigns dpll_device_ops callbacks
and references UAPI enums that do not exist on v6.8:

  - phase_offset_monitor_get / phase_offset_monitor_set
  - phase_offset_avg_factor_get / phase_offset_avg_factor_set
  - lock_status_get extended with enum dpll_lock_status_error *
  - enum dpll_lock_status_error
  - enum dpll_feature_state

Add the header-side definitions required so the driver compiles. The
dpll core / netlink layer is intentionally left unchanged: these
callbacks remain unused by the core on v6.8, which is acceptable for
a minimum-to-compile backport." \
    "backport - header-only shim; dpll_netlink.c/dpll_core.c wiring intentionally omitted"
fi

# ---------- autofix #3: annotations ----------
if [ -s "$SNIFF_KCONFIG_MISSING" ]; then
  echo "==> Autofix: append CONFIG_* policy entries to debian.master/config/annotations"
  ANN="$REPO/debian.master/config/annotations"
  # Default policy: module on every arch where CONFIG_DPLL is on, fall back
  # to the standard 5-arch set if there's no DPLL line.
  POLICY="policy<{'amd64': 'm', 'arm64': 'm', 'armhf': 'm', 'ppc64el': 'm', 'riscv64': 'm'}>"

  ADDED=0
  while IFS= read -r sym; do
    [ -z "$sym" ] && continue
    grep -q "^${sym}[[:space:]]" "$ANN" && continue
    # Append a single policy line + a note referencing the BugLink.
    printf '%-48s%s\n' "$sym" "$POLICY"                          >> "$ANN"
    printf "%-48snote<'LP: #%s'>\n" "$sym" "$BUG"                >> "$ANN"
    echo "    appended: $sym"
    ADDED=$((ADDED+1))
  done < <(sort -u "$SNIFF_KCONFIG_MISSING")

  if [ "$ADDED" -gt 0 ]; then
    # Re-sort the annotations block so entries land in their alphabetical
    # place. Skip the header lines (the first comment block + the very
    # first blank line) and sort the rest, then stitch back. To stay safe,
    # only sort if the file *was* already sorted before our append --
    # detect by checking the first 50 CONFIG_ lines.
    if sort -c -k1,1 <(grep -h '^CONFIG_' "$ANN" | head -200) 2>/dev/null; then
      HEADER_LINES=$(awk '/^CONFIG_/{print NR; exit}' "$ANN")
      if [ -n "$HEADER_LINES" ] && [ "$HEADER_LINES" -gt 1 ]; then
        HEADER_END=$((HEADER_LINES - 1))
        head -n "$HEADER_END" "$ANN" > "$ANN.tmp"
        tail -n +"$HEADER_LINES" "$ANN" | sort -s -k1,1 -t' ' >> "$ANN.tmp"
        mv "$ANN.tmp" "$ANN"
        echo "    re-sorted annotations"
      fi
    fi
    git -C "$REPO" add "$ANN"
    sauce_commit \
      "UBUNTU: SAUCE: [Config] Enable new Kconfig symbols introduced by this stack" \
"The cherry-picked patches introduced new CONFIG_* symbols that the
Ubuntu build's check-config step rejects because they have no entry
in debian.master/config/annotations. Add module-on-all-supported-
arches policy entries so the build passes." \
      "backport - new SAUCE; no upstream commit (Ubuntu-specific build-policy file)"
  fi
fi

# ---------- report any items we did NOT auto-fix ----------
echo
LEFT_OVER=0
if [ -s "$SNIFF_UAPI_MISSING" ]; then
  # Filter out the enums we already added.
  REMAINING="$WORK/uapi.left"
  : > "$REMAINING"
  while IFS= read -r sym; do
    case "$sym" in
      DPLL_FEATURE_STATE_*|DPLL_LOCK_STATUS_ERROR_*) continue ;;
    esac
    if ! grep -qrE "\b${sym}\b" "$REPO/include/" 2>/dev/null; then
      echo "$sym" >> "$REMAINING"
    fi
  done < "$SNIFF_UAPI_MISSING"
  if [ -s "$REMAINING" ]; then
    echo "==> UAPI constants still NOT defined (handle manually):"
    sed 's/^/    /' "$REMAINING"
    LEFT_OVER=$((LEFT_OVER + $(wc -l < "$REMAINING")))
  fi
fi

echo
echo "================================================================"
echo "==> Done. HEAD is now $(git -C "$REPO" rev-parse --short HEAD)."
echo "    Range applied: ${BASE_SHA}..HEAD"
echo "    Commits in range: $(git -C "$REPO" rev-list --count "${BASE_SHA}..HEAD")"
if [ "$LEFT_OVER" -gt 0 ]; then
  echo "    Manual follow-ups: $LEFT_OVER (see above)"
  exit 3
fi
echo "    No manual follow-ups."
echo "================================================================"
