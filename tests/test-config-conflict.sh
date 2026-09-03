#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp "$REPO_DIR/set-sriov-all.sh" "$TMP/"
cat >"$TMP/set-sriov.sh" <<'MOCK'
#!/usr/bin/env bash
echo called >"$(dirname "$0")/called"
echo "${SRIOV_COORDINATED_SF_RESTORE:-}" >"$(dirname "$0")/coordinated"
MOCK
cat >"$TMP/manage-sf.sh" <<'MOCK'
#!/usr/bin/env bash
echo called >"$(dirname "$0")/called"
MOCK
chmod +x "$TMP"/*.sh

cat >"$TMP/sriov-nic.conf.pf0" <<'EOF'
MODE=sriov
PF_PCI=0000:c1:00.0
TOTAL_VFS=6
EOF
cat >"$TMP/sf-nic.conf.sf0" <<'EOF'
PF_PCI=0000:c1:00.0
SF_NUM=0
EOF

if "$TMP/set-sriov-all.sh" >"$TMP/out" 2>"$TMP/err"; then
    echo "conflicting PF/SF configs were incorrectly accepted" >&2
    exit 1
fi
grep -q 'requires switchdev' "$TMP/err"
[[ ! -e "$TMP/called" ]] || {
    echo "a device apply helper ran before the conflict was rejected" >&2
    exit 1
}

sed -i 's/MODE=sriov/MODE=switchdev/' "$TMP/sriov-nic.conf.pf0"
"$TMP/set-sriov-all.sh" >"$TMP/out" 2>"$TMP/err"
[[ -e "$TMP/called" ]] || {
    echo "compatible switchdev PF/SF configs were not applied" >&2
    exit 1
}
[[ "$(<"$TMP/coordinated")" == true ]] || {
    echo "PF phase was not marked as a coordinated SF restore" >&2
    exit 1
}

echo "config conflict test: OK"
