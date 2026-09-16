#!/bin/bash

# Move a deployment from the AWX kind to the Ascender kind, in place.
#
# The two kinds are different objects in different API groups, not aliases of
# one another, and Kubernetes cannot convert across groups. What makes a swap
# possible is that every managed object is named from the custom resource's own
# name and from deployment_type, which stays awx on both sides. An Ascender
# named foo therefore wants exactly the objects an AWX named foo already has.
#
# So nothing is deleted here except the custom resource itself. The pods keep
# running throughout, the database and its volume are never touched, and the
# secrets outlive the resource because garbage_collect_secrets defaults to
# false. The work is: orphan the children, create the Ascender, hand it the
# status, and point the owner references at it.
#
# Usage:
#   ./hack/migrate-awx-to-ascender.sh -n <namespace> <name>            # shows the plan
#   ./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --apply    # performs it
#   ./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --rollback --state-dir <dir>
#
# It prints the plan and changes nothing unless --apply is given.

set -euo pipefail

NAMESPACE=""
NAME=""
APPLY=false
ROLLBACK=false
FORCE=false
RESUME=false
STATE_DIR=""

# Every kind the installer role creates. An object is part of the deployment if
# it carries an owner reference to the custom resource, so the set is discovered
# rather than assumed, and this list only bounds where to look.
KINDS="deployment,statefulset,service,ingress,configmap,secret,serviceaccount,role,rolebinding,cronjob,job,persistentvolumeclaim"

usage() {
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

log()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        --apply)        APPLY=true; shift ;;
        --rollback)     ROLLBACK=true; shift ;;
        --resume)       RESUME=true; shift ;;
        --force)        FORCE=true; shift ;;
        --state-dir)    STATE_DIR="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        -*)             die "unknown option $1" ;;
        *)              [ -z "$NAME" ] || die "give one name, got '$NAME' and '$1'"; NAME="$1"; shift ;;
    esac
done

[ -n "$NAME" ] || usage 1
[ -n "$NAMESPACE" ] || die "a namespace is required, pass -n"
command -v kubectl >/dev/null || die "kubectl is not on PATH"

KC="kubectl -n $NAMESPACE"

# The name of every object is derived from the custom resource name, so an
# Ascender of the same name inherits them unchanged. Migrating to a different
# name is a different operation and this script does not attempt it.
SRC_KIND=AWX
DST_KIND=Ascender
SRC_RES=awx.awx.ansible.com
DST_RES=ascender.ascender.ansible.com
DST_API=ascender.ansible.com/v1beta1

if $ROLLBACK; then
    SRC_KIND=Ascender; DST_KIND=AWX
    SRC_RES=ascender.ascender.ansible.com; DST_RES=awx.awx.ansible.com
    DST_API=awx.ansible.com/v1beta1
fi

if [ -z "$STATE_DIR" ]; then
    STATE_DIR="migrate-${NAMESPACE}-${NAME}-$(date +%Y%m%d%H%M%S)"
fi


# ---------------------------------------------------------------- preflight --
# Everything that could make this stop half way is checked before anything is
# touched, because the one genuinely awkward moment is between the delete and
# the create.

step "Preflight"

$KC get "$DST_RES" >/dev/null 2>&1 \
    || die "the $DST_KIND CRD is not installed in this cluster, so there is nothing to migrate to"

if $RESUME; then
    # Picking up a run that stopped after the custom resource was already
    # removed. The saved state is the only record of what it looked like.
    [ -n "$STATE_DIR" ] || die "--resume needs the --state-dir of the run that stopped"
    [ -f "$STATE_DIR/source.json" ] || die "$STATE_DIR/source.json is missing, so there is nothing to resume from"
    [ -f "$STATE_DIR/inventory.txt" ] || die "$STATE_DIR/inventory.txt is missing, so there is nothing to resume from"
    log "  resuming from $STATE_DIR"
else
    $KC get "$SRC_RES" "$NAME" >/dev/null 2>&1 \
        || die "no $SRC_KIND named $NAME in namespace $NAMESPACE. If a previous run stopped after removing it, re-run with --resume --state-dir <dir>."

    if $KC get "$DST_RES" "$NAME" >/dev/null 2>&1; then
        die "$DST_KIND/$NAME already exists in $NAMESPACE. Both kinds manage objects of the same name, so remove one before migrating."
    fi

    log "  $SRC_KIND/$NAME found, no $DST_KIND/$NAME in the way"
fi

# Migrating an unhealthy deployment turns one problem into two.
UNREADY=$($KC get deployment,statefulset -o json | python3 -c '
import json, sys
bad = []
for item in json.load(sys.stdin)["items"]:
    want = item.get("spec", {}).get("replicas", 1)
    got = item.get("status", {}).get("readyReplicas", 0)
    if got != want:
        kind = item["kind"]
        name = item["metadata"]["name"]
        bad.append("%s/%s %s/%s" % (kind, name, got, want))
print(", ".join(bad))
')
if [ -n "$UNREADY" ]; then
    if $FORCE; then
        log "  WARNING: not all replicas are ready ($UNREADY), continuing because --force was given"
    else
        die "not all replicas are ready ($UNREADY). Fix the deployment first, or pass --force."
    fi
else
    log "  every deployment and statefulset in the namespace is fully ready"
fi


# ---------------------------------------------------------------- inventory --
# The objects to carry over are the ones pointing at this custom resource, so
# they are discovered from the cluster rather than reconstructed from templates.

step "Inventory"

if $RESUME; then
    INVENTORY=$(cat "$STATE_DIR/inventory.txt")
    PODS=$(cat "$STATE_DIR/pods.txt" 2>/dev/null || true)
    COUNT=$(printf '%s\n' "$INVENTORY" | sed '/^$/d' | wc -l | tr -d ' ')
    log "  $COUNT objects recorded by the run being resumed:"
    printf '%s\n' "$INVENTORY" | sed 's/^/    /'
else

SRC_UID=$($KC get "$SRC_RES" "$NAME" -o jsonpath='{.metadata.uid}')
log "  $SRC_KIND/$NAME uid $SRC_UID"

INVENTORY=$($KC get "$KINDS" -o json 2>/dev/null | python3 -c '
import json, sys
uid = sys.argv[1]
for item in json.load(sys.stdin)["items"]:
    meta = item["metadata"]
    for owner in meta.get("ownerReferences") or []:
        if owner.get("uid") == uid:
            print("%s/%s" % (item["kind"].lower(), meta["name"]))
' "$SRC_UID")

[ -n "$INVENTORY" ] || die "nothing in $NAMESPACE is owned by $SRC_KIND/$NAME, which is not what a running deployment looks like"

COUNT=$(printf '%s\n' "$INVENTORY" | wc -l | tr -d ' ')
log "  $COUNT objects carry its owner reference:"
printf '%s\n' "$INVENTORY" | sed 's/^/    /'

# Pod uids are the evidence that nothing restarted. They are not owned by the
# custom resource directly, so they are recorded separately.
PODS=$($KC get pods -o json | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    meta = pod["metadata"]
    print("%s %s" % (meta["name"], meta["uid"]))
' | sort)

fi

if ! $APPLY; then
    step "Plan"
    cat <<PLAN
  1. save $SRC_KIND/$NAME, the inventory and the pod uids to $STATE_DIR
  2. kubectl delete $SRC_RES $NAME --cascade=orphan
       the $COUNT objects above keep running, the custom resource goes
  3. create $DST_KIND/$NAME from the saved spec
  4. copy the saved status onto it, so the secret names and
     upgradedPostgresVersion are not derived a second time
  5. repoint the owner reference on all $COUNT objects at $DST_KIND/$NAME
  6. verify the inventory is unchanged and no pod restarted

  Nothing is deleted but the custom resource itself. Re-run with --apply.
PLAN
    exit 0
fi


# --------------------------------------------------------------------- save --

if $RESUME; then
    step "Reusing the state in $STATE_DIR"
    log "  source.json, inventory.txt and pods.txt already written"
else
    step "Saving state to $STATE_DIR"

    mkdir -p "$STATE_DIR"
    $KC get "$SRC_RES" "$NAME" -o json > "$STATE_DIR/source.json"
    printf '%s\n' "$INVENTORY" > "$STATE_DIR/inventory.txt"
    printf '%s\n' "$PODS" > "$STATE_DIR/pods.txt"
    log "  wrote source.json, inventory.txt, pods.txt"
fi


# --------------------------------------------------------------------- swap --
# From here to the end of the re-own step the deployment is running but
# unmanaged. It is not an outage: no workload is touched. If it stops in that
# window the custom resource is already gone, so an ordinary re-run would find
# nothing to migrate: --resume --state-dir <dir> carries on from the saved
# state, and every step from here is written to tolerate being run twice.

if $RESUME; then
    step "Skipping the delete, $SRC_KIND/$NAME is already gone"
else
    step "Orphaning the children and removing $SRC_KIND/$NAME"

    $KC delete "$SRC_RES" "$NAME" --cascade=orphan --wait=true
    log "  $SRC_KIND/$NAME deleted, children orphaned"
fi

MISSING=$(while read -r ref; do
    [ -n "$ref" ] || continue
    $KC get "$ref" >/dev/null 2>&1 || printf '%s ' "$ref"
done < "$STATE_DIR/inventory.txt")
[ -z "$MISSING" ] || die "these objects went away with the custom resource, which should not happen with --cascade=orphan: $MISSING"
log "  all $COUNT objects still present"

step "Creating $DST_KIND/$NAME"

python3 - "$STATE_DIR/source.json" "$DST_API" "$DST_KIND" > "$STATE_DIR/target.json" <<'PY'
import json, sys

source = json.load(open(sys.argv[1]))
meta = source["metadata"]
target = {
    "apiVersion": sys.argv[2],
    "kind": sys.argv[3],
    "metadata": {
        "name": meta["name"],
        "namespace": meta["namespace"],
    },
    "spec": source.get("spec", {}),
}
# Labels and annotations travel, minus the ones that belong to the old object's
# identity or to kubectl's own bookkeeping.
for field in ("labels", "annotations"):
    kept = {
        key: value
        for key, value in (meta.get(field) or {}).items()
        if key != "kubectl.kubernetes.io/last-applied-configuration"
    }
    if kept:
        target["metadata"][field] = kept
json.dump(target, sys.stdout, indent=2)
PY

if $KC get "$DST_RES" "$NAME" >/dev/null 2>&1; then
    log "  $DST_KIND/$NAME already exists, leaving its spec alone"
else
    $KC create -f "$STATE_DIR/target.json" >/dev/null
    log "  $DST_KIND/$NAME created"
fi
DST_UID=$($KC get "$DST_RES" "$NAME" -o jsonpath='{.metadata.uid}')
log "  uid $DST_UID"

step "Carrying the status across"

# The operator would otherwise derive these again. upgradedPostgresVersion is
# the one that matters most: without it the upgrade path can be re-evaluated
# against a database that has already moved.
STATUS=$(python3 -c '
import json, sys
status = json.load(open(sys.argv[1])).get("status") or {}
status.pop("conditions", None)
print(json.dumps({"status": status}))
' "$STATE_DIR/source.json")

if [ "$STATUS" != '{"status": {}}' ]; then
    $KC patch "$DST_RES" "$NAME" --subresource=status --type=merge -p "$STATUS" >/dev/null
    log "  copied: $(printf '%s' "$STATUS" | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)["status"].keys()))')"
else
    log "  the source carried no status, nothing to copy"
fi


# ------------------------------------------------------------------- re-own --
# Set explicitly rather than left to the operator. The operator's proxy adds
# owner references to objects it creates, and these already exist, so relying on
# it would leave the question open until the first time someone deletes the
# custom resource and finds the objects outliving it.

step "Repointing owner references at $DST_KIND/$NAME"

PATCH=$(python3 -c '
import json, sys
print(json.dumps({"metadata": {"ownerReferences": [{
    "apiVersion": sys.argv[1], "kind": sys.argv[2], "name": sys.argv[3],
    "uid": sys.argv[4], "controller": True, "blockOwnerDeletion": True,
}]}}))
' "$DST_API" "$DST_KIND" "$NAME" "$DST_UID")

while read -r ref; do
    [ -n "$ref" ] || continue
    $KC patch "$ref" --type=merge -p "$PATCH" >/dev/null
    log "  $ref"
done < "$STATE_DIR/inventory.txt"


# ------------------------------------------------------------------- verify --

step "Verifying"

NOW=$($KC get "$KINDS" -o json 2>/dev/null | python3 -c '
import json, sys
uid = sys.argv[1]
for item in json.load(sys.stdin)["items"]:
    meta = item["metadata"]
    for owner in meta.get("ownerReferences") or []:
        if owner.get("uid") == uid:
            print("%s/%s" % (item["kind"].lower(), meta["name"]))
' "$DST_UID" | sort)

if [ "$(printf '%s\n' "$NOW")" = "$(sort "$STATE_DIR/inventory.txt")" ]; then
    log "  all $COUNT objects now belong to $DST_KIND/$NAME"
else
    die "the object set changed. Expected:\n$(sort "$STATE_DIR/inventory.txt")\ngot:\n$NOW"
fi

PODS_NOW=$($KC get pods -o json | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    meta = pod["metadata"]
    print("%s %s" % (meta["name"], meta["uid"]))
' | sort)

if [ "$PODS_NOW" = "$(cat "$STATE_DIR/pods.txt")" ]; then
    log "  every pod is the same pod, by uid: nothing restarted"
else
    log "  WARNING: the pod set changed during the migration."
    log "  before:"; printf '%s\n' "$(cat "$STATE_DIR/pods.txt")" | sed 's/^/    /'
    log "  after:";  printf '%s\n' "$PODS_NOW" | sed 's/^/    /'
fi


# ------------------------------------------------------------- loose ends ----
# Backups and restores name the deployment and default to deployment_kind AWX,
# so the ones written against the old kind now point at a resource that is gone.

step "Backups and restores that still name the old kind"

# Asking for all four at once fails outright when one CRD is absent, and a
# swallowed error there would read as "none found", which is the wrong answer
# to give about backups. Each is asked for separately.
STALE=""
SKIPPED=""
for RES in awxbackup awxrestore ascenderbackup ascenderrestore; do
    if ! $KC get "$RES" >/dev/null 2>&1; then
        SKIPPED="$SKIPPED $RES"
        continue
    fi
    FOUND=$($KC get "$RES" -o json | python3 -c '
import json, sys
name, wanted = sys.argv[1], sys.argv[2]
for item in json.load(sys.stdin)["items"]:
    spec = item.get("spec") or {}
    if spec.get("deployment_name") == name and not item["kind"].startswith(wanted):
        print("%s/%s" % (item["kind"].lower(), item["metadata"]["name"]))
' "$NAME" "$DST_KIND")
    [ -z "$FOUND" ] || STALE="${STALE}${FOUND}
"
done
STALE=$(printf '%s' "$STALE" | sed '/^$/d')

[ -z "$SKIPPED" ] || log "  not installed in this cluster, so not checked:$SKIPPED"

if [ -n "$STALE" ]; then
    log "  these name $NAME but are of the other group, and will not find it:"
    printf '%s\n' "$STALE" | sed 's/^/    /'
    log "  recreate them as ${DST_KIND}Backup and ${DST_KIND}Restore."
else
    log "  none found"
fi

step "Done"
log "  $NAME is now kind $DST_KIND. State kept in $STATE_DIR."
log "  To reverse: $0 -n $NAMESPACE $NAME --rollback --state-dir $STATE_DIR --apply"
