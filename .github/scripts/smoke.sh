#!/usr/bin/env bash
#
# Offline smoke tests for pacman-remove.
#
# Runs entirely in a throwaway sandbox with a synthetic pacman.conf that
# declares zero repositories, so no network access and no /etc/pacman.conf
# are needed.  Every test exits non-zero on failure (set -e + explicit
# greps).  Designed for CI (passwordless sudo + script(1) from util-linux).
#
# Usage:  smoke.sh /path/to/pacman-remove
set -euo pipefail

BIN="$(readlink -f "$1")"
test -x "$BIN" || { echo "binary not found: $BIN" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'sudo rm -rf "$WORK" 2>/dev/null || true' EXIT

# fresh dbpaths must pre-exist for upstream's resolve_path()
mkdir -p "$WORK"/{db,db3,db4,root,cache}

# minimal config: no repos, just enough for -R / gate logic
cat > "$WORK/pacman.conf" <<EOF
[options]
HoldPkg = pacman glibc
EOF

COMMON=(--config "$WORK/pacman.conf" --dbpath "$WORK/db" \
        --root "$WORK/root" --cachedir "$WORK/cache" --logfile "$WORK/log")

# feed a key after the prompt renders (pacman's flush_term_input discards
# pre-queued keystrokes, so we delay like a human would).
# printf '%b' interprets \n as a real newline; '%s' would not.
feed_keys() {
    local delay="$1" keys="$2"
    { sleep "$delay"; printf '%b' "$keys"; sleep 1; }
}

# wrap every invocation in a hard timeout so nothing can hang CI
run_timed() {
    timeout 30 "$@"
}

pass=0
check() { if "$@"; then pass=$((pass+1)); else echo "FAIL: $*" >&2; exit 1; fi; }
check_not() { if ! "$@"; then pass=$((pass+1)); else echo "FAIL (expected false): $*" >&2; exit 1; fi; }

#-----------------------------------------------------------------------------
echo ":: T1 — first use, <enter> at the dork prompt -> refused, no marker"
feed_keys 2 '\n' | \
    run_timed script -qec "sudo '$BIN' ${COMMON[*]} -R boguspkg" /dev/null > "$WORK/t1.out" 2>&1 || true
check grep -q "I am a dork, and I am using this because" "$WORK/t1.out"
check grep -q "Do you accept? \[y/N\]" "$WORK/t1.out"
check grep -q "Consent not given" "$WORK/t1.out"
check_not test -e "$WORK/db/.pacman-remove-consent"

#-----------------------------------------------------------------------------
echo ":: T2 — accept with 'y' -> consent recorded"
feed_keys 2 'y\n' | \
    run_timed script -qec "sudo '$BIN' ${COMMON[*]} -R boguspkg" /dev/null > "$WORK/t2.out" 2>&1 || true
check grep -q "dork acknowledged" "$WORK/db/.pacman-remove-consent"

#-----------------------------------------------------------------------------
echo ":: T3 — second run (consented) -> no lecture"
feed_keys 2 'n\n' | \
    run_timed script -qec "sudo '$BIN' ${COMMON[*]} -R boguspkg" /dev/null > "$WORK/t3.out" 2>&1 || true
check_not grep -q "I am a dork" "$WORK/t3.out"

#-----------------------------------------------------------------------------
echo ":: T4 — --noconfirm_IknowwhatIamdoing is silent (no tty, no lecture)"
run_timed sudo "$BIN" "${COMMON[@]}" -R boguspkg --noconfirm_IknowwhatIamdoing \
    > "$WORK/t4.out" 2>&1 || true
check_not grep -q "I am a dork" "$WORK/t4.out"

#-----------------------------------------------------------------------------
echo ":: T5 — piped 'y |' on a fresh db -> rejected (no terminal)"
echo y | run_timed sudo "$BIN" --config "$WORK/pacman.conf" --dbpath "$WORK/db3" \
    -R boguspkg > "$WORK/t5.out" 2>&1 || true
check grep -q "stdin is not a terminal" "$WORK/t5.out"
check grep -q "noconfirm_IknowwhatIamdoing" "$WORK/t5.out"

#-----------------------------------------------------------------------------
echo ":: T6 — plain --noconfirm on a fresh db -> refused with flag hint"
run_timed script -qec "sudo '$BIN' --config '$WORK/pacman.conf' --dbpath '$WORK/db4' \
    -R boguspkg --noconfirm" /dev/null < /dev/null > "$WORK/t6.out" 2>&1 || true
check grep -q "does not work in pacman-remove" "$WORK/t6.out"
check grep -q "noconfirm_IknowwhatIamdoing" "$WORK/t6.out"

#-----------------------------------------------------------------------------
echo ":: T7 — empty substitution '(true)' -> clean error"
run_timed sudo "$BIN" "${COMMON[@]}" -R '(true)' --noconfirm_IknowwhatIamdoing \
    > "$WORK/t7.out" 2>&1 || true
check grep -q "no package names were produced" "$WORK/t7.out"

#-----------------------------------------------------------------------------
echo ":: T8 — substitution '(printf somepkg)' -> target expanded to 'somepkg'"
run_timed sudo "$BIN" "${COMMON[@]}" -R '(printf somepkg)' --noconfirm_IknowwhatIamdoing \
    > "$WORK/t8.out" 2>&1 || true
check grep -q "target not found: somepkg" "$WORK/t8.out"

#-----------------------------------------------------------------------------
echo ":: T9 — \$(...) form also expands"
run_timed sudo "$BIN" "${COMMON[@]}" -R '$(printf otherpkg)' --noconfirm_IknowwhatIamdoing \
    > "$WORK/t9.out" 2>&1 || true
check grep -q "target not found: otherpkg" "$WORK/t9.out"

#-----------------------------------------------------------------------------
echo ":: T10 — read-only -Qq bypasses the gate (no consent needed, fresh db5)"
mkdir -p "$WORK/db5"
run_timed sudo "$BIN" --config "$WORK/pacman.conf" --dbpath "$WORK/db5" -Qq \
    > "$WORK/t10.out" 2>&1 || true
check_not grep -q "I am a dork" "$WORK/t10.out"

#-----------------------------------------------------------------------------
echo ""
echo "ALL $pass SMOKE TESTS PASSED"