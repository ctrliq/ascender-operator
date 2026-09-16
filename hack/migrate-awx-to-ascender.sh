#!/bin/bash

# Move a deployment from the AWX kind to the Ascender kind, in place.
#
# The two kinds are different objects in different API groups, not aliases of
# one another, and Kubernetes cannot convert across groups. They also no longer
# name things the same way: deployment_type follows the kind, so an Ascender
# calls its database ascender, labels its objects ascender-operator, and mounts
# an <name>-ascender-configmap, where an AWX says awx in all three.
#
# That last part is what makes this more than a relabelling. deployment_type
# appears in spec.selector.matchLabels on the two Deployments and the postgres
# StatefulSet, and a selector cannot be changed after creation, so those three
# have to be recreated rather than patched. The database has to be renamed as
# well, which no client may be connected to while it happens.
#
# So this is a migration with a window of downtime, not a swap. What it does not
# touch is the data: the volume claim comes from volumeClaimTemplates and
# carries no owner reference, the secrets outlive the resource because
# garbage_collect_secrets defaults to false, and the database is renamed rather
# than dumped and reloaded.
#
# Usage:
#   ./hack/migrate-awx-to-ascender.sh -n <namespace> <name>            # shows the plan
#   ./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --apply    # performs it
#   ./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --rollback --state-dir <dir> --apply
#
# It prints the plan and changes nothing unless --apply is given.

set -euo pipefail

NAMESPACE=""
NAME=""
APPLY=false
ROLLBACK=false
FORCE=false
RESUME=false
NO_WAIT=false
STATE_DIR=""
WAIT_TIMEOUT=600

# Every kind the installer role creates. An object belongs to the deployment if
# it carries an owner reference to the custom resource, so the set is discovered
# rather than assumed, and this list only bounds where to look.
KINDS="deployment,statefulset,service,ingress,configmap,secret,serviceaccount,role,rolebinding,cronjob,job,persistentvolumeclaim"

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
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
        --no-wait)      NO_WAIT=true; shift ;;
        --state-dir)    STATE_DIR="$2"; shift 2 ;;
        --timeout)      WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        -*)             die "unknown option $1" ;;
        *)              [ -z "$NAME" ] || die "give one name, got '$NAME' and '$1'"; NAME="$1"; shift ;;
    esac
done

[ -n "$NAME" ] || usage 1
[ -n "$NAMESPACE" ] || die "a namespace is required, pass -n"
command -v kubectl >/dev/null || die "kubectl is not on PATH"

KC="kubectl -n $NAMESPACE"

# resource.group, kubectl's fully qualified form. It reads as a stutter only
# because each group is named after its product: the resource awx in the group
# awx.ansible.com, the resource ascender in ascender.ansible.com.
SRC_KIND=AWX;       SRC_TYPE=awx
DST_KIND=Ascender;  DST_TYPE=ascender
SRC_RES=awx.awx.ansible.com
DST_RES=ascender.ascender.ansible.com
DST_API=ascender.ansible.com/v1beta1

if $ROLLBACK; then
    SRC_KIND=Ascender;  SRC_TYPE=ascender
    DST_KIND=AWX;       DST_TYPE=awx
    SRC_RES=ascender.ascender.ansible.com
    DST_RES=awx.awx.ansible.com
    DST_API=awx.ansible.com/v1beta1
fi

[ -n "$STATE_DIR" ] || STATE_DIR="migrate-${NAMESPACE}-${NAME}-$(date +%Y%m%d%H%M%S)"

PG_SECRET="${NAME}-postgres-configuration"
PG_POD=""


# ---------------------------------------------------------------- preflight --

step "Preflight"

$KC get "$DST_RES" >/dev/null 2>&1 \
    || die "the $DST_KIND CRD is not installed in this cluster, so there is nothing to migrate to"

if $RESUME; then
    [ -n "$STATE_DIR" ] || die "--resume needs the --state-dir of the run that stopped"
    [ -f "$STATE_DIR/source.json" ] || die "$STATE_DIR/source.json is missing, so there is nothing to resume from"
    [ -f "$STATE_DIR/inventory.txt" ] || die "$STATE_DIR/inventory.txt is missing, so there is nothing to resume from"
    log "  resuming from $STATE_DIR"
else
    $KC get "$SRC_RES" "$NAME" >/dev/null 2>&1 \
        || die "no $SRC_KIND named $NAME in namespace $NAMESPACE. If a previous run stopped part way, re-run with --resume --state-dir <dir>."
    $KC get "$DST_RES" "$NAME" >/dev/null 2>&1 \
        && die "$DST_KIND/$NAME already exists in $NAMESPACE. Both kinds name their Deployments, Services, StatefulSet and Secrets after the resource, so remove one before migrating."
    log "  $SRC_KIND/$NAME found, no $DST_KIND/$NAME in the way"
fi

# Migrating an unhealthy deployment turns one problem into two.
UNREADY=$($KC get deployment,statefulset -o json | python3 -c '
import json, sys
bad = []
for item in json.load(sys.stdin)["items"]:
    want = item.get("spec", {}).get("replicas", 1)
    got = item.get("status", {}).get("readyReplicas", 0)
    if want and got != want:
        bad.append("%s/%s %s/%s" % (item["kind"], item["metadata"]["name"], got, want))
print(", ".join(bad))
')
if [ -n "$UNREADY" ] && ! $RESUME; then
    if $FORCE; then
        log "  WARNING: not all replicas are ready ($UNREADY), continuing because --force was given"
    else
        die "not all replicas are ready ($UNREADY). Fix the deployment first, or pass --force."
    fi
else
    log "  every deployment and statefulset in the namespace is ready"
fi

# The database is renamed in place, which means reaching into a postgres this
# operator manages. A database someone else runs is theirs to rename.
$KC get secret "$PG_SECRET" >/dev/null 2>&1 \
    || die "no secret $PG_SECRET in $NAMESPACE, so the database cannot be read"

read -r PG_TYPE PG_DB PG_USER <<EOF
$($KC get secret "$PG_SECRET" -o json | python3 -c '
import base64, json, sys
data = json.load(sys.stdin)["data"]
get = lambda k: base64.b64decode(data.get(k, "")).decode() or "-"
print(get("type"), get("database"), get("username"))
')
EOF

log "  database $PG_DB, user $PG_USER, type $PG_TYPE"

if [ "$PG_TYPE" != "managed" ]; then
    die "$PG_SECRET says type '$PG_TYPE'. This renames the database and its role in place, which it will only do to a postgres the operator manages. Rename '$PG_DB' and '$PG_USER' to '$DST_TYPE' yourself, update $PG_SECRET, and re-run with --resume."
fi

PG_POD="${NAME}-postgres-$($KC get statefulset -o name | sed -n "s|.*${NAME}-postgres-||p" | head -1)"
$KC get pod "${PG_POD}-0" >/dev/null 2>&1 \
    || die "could not find the postgres pod (looked for ${PG_POD}-0)"
PG_POD="${PG_POD}-0"
log "  postgres pod $PG_POD"

psql_super() { $KC exec "$PG_POD" -- psql -U postgres -v ON_ERROR_STOP=1 "$@"; }


# ---------------------------------------------------------------- inventory --

step "Inventory"

if $RESUME; then
    INVENTORY=$(cat "$STATE_DIR/inventory.txt")
    PODS=$(cat "$STATE_DIR/pods.txt" 2>/dev/null || true)
    COUNT=$(printf '%s\n' "$INVENTORY" | sed '/^$/d' | wc -l | tr -d ' ')
    log "  $COUNT objects recorded by the run being resumed"
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

PODS=$($KC get pods -o json | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    meta = pod["metadata"]
    print("%s %s" % (meta["name"], meta["uid"]))
' | sort)

fi

# The three whose selector carries deployment_type, which cannot be changed.
RECREATE="deployment/${NAME}-web deployment/${NAME}-task statefulset/${PG_POD%-0}"

if ! $APPLY; then
    step "Plan"
    cat <<PLAN
  1. save $SRC_KIND/$NAME, the inventory and the pod uids to $STATE_DIR
  2. scale ${NAME}-web and ${NAME}-task to zero, and wait for their pods to go
       the deployment stops serving here, and starts again at step 7
  3. rename the database $PG_DB to $DST_TYPE and the role $PG_USER to $DST_TYPE,
     then write both into $PG_SECRET
  4. kubectl delete $SRC_RES $NAME --cascade=orphan
  5. delete the objects whose selector names the old deployment_type, which
     Kubernetes will not let anyone change in place:
$(printf '%s' "$RECREATE" | tr ' ' '\n' | sed 's/^/       /')
       the volume claim is not one of them and stays where it is
  6. create $DST_KIND/$NAME from the saved spec, and copy its status across
  7. wait for the operator to rebuild what step 5 removed, with $DST_TYPE names
  8. repoint owner references, drop the leftover ${NAME}-${SRC_TYPE}-* configmaps
  9. verify nothing is left carrying $SRC_TYPE, and that the claim is the same one

  The data is never copied: the claim is kept and the database is renamed.
  Re-run with --apply.
PLAN
    exit 0
fi


# --------------------------------------------------------------------- save --

if $RESUME; then
    step "Reusing the state in $STATE_DIR"
else
    step "Saving state to $STATE_DIR"
    mkdir -p "$STATE_DIR"
    $KC get "$SRC_RES" "$NAME" -o json > "$STATE_DIR/source.json"
    $KC get secret "$PG_SECRET" -o json > "$STATE_DIR/postgres-configuration.json"
    printf '%s\n' "$INVENTORY" > "$STATE_DIR/inventory.txt"
    printf '%s\n' "$PODS" > "$STATE_DIR/pods.txt"
    log "  wrote source.json, postgres-configuration.json, inventory.txt, pods.txt"
fi


# ------------------------------------------------------------ stop the apps --

step "Stopping the web and task deployments"

for dep in "${NAME}-web" "${NAME}-task"; do
    if $KC get deployment "$dep" >/dev/null 2>&1; then
        $KC scale deployment "$dep" --replicas=0 >/dev/null
        log "  scaled $dep to zero"
    fi
done

log "  waiting for their pods to go"
for _ in $(seq 1 60); do
    left=$($KC get pods -l "app.kubernetes.io/name in (${NAME}-web,${NAME}-task)" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$left" = "0" ] && break
    sleep 5
done

SESSIONS=$(psql_super -tAc "select count(*) from pg_stat_activity where datname='${PG_DB}'" | tr -d '[:space:]')
if [ "${SESSIONS:-0}" != "0" ]; then
    if $FORCE; then
        log "  WARNING: $SESSIONS session(s) still on '$PG_DB', terminating them because --force was given"
        psql_super -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='${PG_DB}' and pid <> pg_backend_pid()" >/dev/null
    else
        die "$SESSIONS session(s) are still connected to '$PG_DB', and a database cannot be renamed while anything is using it. Stop whatever is connected, or pass --force to terminate them."
    fi
else
    log "  nothing is connected to '$PG_DB'"
fi


# ----------------------------------------------------------- rename the db --

step "Renaming the database and its role"

if [ "$PG_DB" = "$DST_TYPE" ] && [ "$PG_USER" = "$DST_TYPE" ]; then
    log "  already named $DST_TYPE, nothing to rename"
else
    [ "$PG_DB" = "$DST_TYPE" ] || { psql_super -c "ALTER DATABASE \"${PG_DB}\" RENAME TO \"${DST_TYPE}\";" >/dev/null; log "  database $PG_DB -> $DST_TYPE"; }
    [ "$PG_USER" = "$DST_TYPE" ] || { psql_super -c "ALTER ROLE \"${PG_USER}\" RENAME TO \"${DST_TYPE}\";" >/dev/null; log "  role $PG_USER -> $DST_TYPE"; }

    # A role rename clears an md5 password, because the role name is its salt.
    # scram-sha-256, which is the default here, is unaffected, so the password
    # is only rewritten when it has to be.
    ENC=$(psql_super -tAc "select case when rolpassword like 'md5%' then 'md5' else 'other' end from pg_authid where rolname='${DST_TYPE}'" | tr -d '[:space:]')
    if [ "$ENC" = "md5" ] || [ -z "$ENC" ]; then
        PW=$($KC get secret "$PG_SECRET" -o jsonpath='{.data.password}' | base64 -d)
        psql_super -c "ALTER ROLE \"${DST_TYPE}\" WITH PASSWORD '${PW}';" >/dev/null
        log "  password rewritten, the old one was md5 salted with the old role name"
    fi
fi

$KC patch secret "$PG_SECRET" --type=merge -p "$(python3 -c '
import base64, json, sys
name = sys.argv[1]
enc = lambda v: base64.b64encode(v.encode()).decode()
print(json.dumps({"data": {"database": enc(name), "username": enc(name)}}))
' "$DST_TYPE")" >/dev/null
log "  $PG_SECRET now says database $DST_TYPE, user $DST_TYPE"


# --------------------------------------------------------- swap the resource --

if $RESUME && ! $KC get "$SRC_RES" "$NAME" >/dev/null 2>&1; then
    step "Skipping the delete, $SRC_KIND/$NAME is already gone"
else
    step "Orphaning the children and removing $SRC_KIND/$NAME"
    $KC delete "$SRC_RES" "$NAME" --cascade=orphan --wait=true
    log "  $SRC_KIND/$NAME deleted, children orphaned"
fi

step "Removing what cannot be relabelled in place"

for ref in $RECREATE; do
    if $KC get "$ref" >/dev/null 2>&1; then
        $KC delete "$ref" --wait=true >/dev/null
        log "  deleted $ref"
    fi
done
log "  the volume claim was not touched: $($KC get pvc -o name | tr '\n' ' ')"

step "Creating $DST_KIND/$NAME"

python3 - "$STATE_DIR/source.json" "$DST_API" "$DST_KIND" > "$STATE_DIR/target.json" <<'PY'
import json, sys

source = json.load(open(sys.argv[1]))
meta = source["metadata"]
target = {
    "apiVersion": sys.argv[2],
    "kind": sys.argv[3],
    "metadata": {"name": meta["name"], "namespace": meta["namespace"]},
    "spec": source.get("spec", {}),
}
for field in ("labels", "annotations"):
    kept = {k: v for k, v in (meta.get(field) or {}).items()
            if k != "kubectl.kubernetes.io/last-applied-configuration"}
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

STATUS=$(python3 -c '
import json, sys
status = json.load(open(sys.argv[1])).get("status") or {}
status.pop("conditions", None)
print(json.dumps({"status": status}))
' "$STATE_DIR/source.json")

if [ "$STATUS" != '{"status": {}}' ]; then
    $KC patch "$DST_RES" "$NAME" --subresource=status --type=merge -p "$STATUS" >/dev/null
    log "  status copied across"
fi


# ------------------------------------------------------------- re-own, tidy --

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
    case " $RECREATE " in *" $ref "*) continue ;; esac   # the operator makes these anew
    $KC get "$ref" >/dev/null 2>&1 || continue
    $KC patch "$ref" --type=merge -p "$PATCH" >/dev/null
    log "  $ref"
done < "$STATE_DIR/inventory.txt"

step "Dropping the configmaps named after the old deployment_type"

for cm in "${NAME}-${SRC_TYPE}-configmap" "${NAME}-${SRC_TYPE}-pre-stop-scripts"; do
    if $KC get configmap "$cm" >/dev/null 2>&1; then
        $KC delete configmap "$cm" >/dev/null
        log "  deleted configmap $cm"
    fi
done


# ------------------------------------------------------------------- verify --

if $NO_WAIT; then
    step "Not waiting for the rebuild, --no-wait was given"
else
    step "Waiting for the operator to rebuild the workloads"
    log "  this needs the operator running, and takes as long as a normal reconcile"
    if $KC wait --for=condition=Available "deployment/${NAME}-web" "deployment/${NAME}-task" \
        --timeout="${WAIT_TIMEOUT}s" >/dev/null 2>&1; then
        log "  web and task are Available again"
    else
        log "  WARNING: they did not come back within ${WAIT_TIMEOUT}s."
        log "  Check the operator's logs. Nothing here needs undoing: the resource, the"
        log "  database and the claim are all in their new state, and the operator will"
        log "  keep reconciling. --resume re-runs the tail of this safely."
    fi
fi

step "Verifying"

LEFTOVER=$($KC get "$KINDS" -o json 2>/dev/null | python3 -c '
import json, sys
old = sys.argv[1]
for item in json.load(sys.stdin)["items"]:
    meta = item["metadata"]
    labels = meta.get("labels") or {}
    if labels.get("app.kubernetes.io/component") == old \
       or labels.get("app.kubernetes.io/managed-by") == old + "-operator" \
       or ("-" + old + "-") in meta["name"]:
        print("%s/%s" % (item["kind"].lower(), meta["name"]))
' "$SRC_TYPE" || true)

if [ -n "$LEFTOVER" ]; then
    log "  still carrying $SRC_TYPE:"
    printf '%s\n' "$LEFTOVER" | sed 's/^/    /'
    log "  those are objects the operator has not rebuilt yet, or ones it does not manage."
else
    log "  nothing in $NAMESPACE is named or labelled $SRC_TYPE any more"
fi

# The postgres pod went with its statefulset and only comes back when the
# operator rebuilds it, so the database is checked if it is there and reported
# as pending if it is not. Either way it is not a reason to fail: the rename
# happened before anything was deleted.
if $KC get pod "$PG_POD" >/dev/null 2>&1; then
    FOUND=$(psql_super -tAc "select datname from pg_database where datname='${DST_TYPE}'" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$FOUND" = "$DST_TYPE" ]; then
        log "  database $DST_TYPE is there"
    else
        log "  WARNING: no database named $DST_TYPE was found"
    fi
else
    log "  postgres is not running yet, so the database was not re-checked here."
    log "  It was renamed to $DST_TYPE before anything was deleted, and $PG_SECRET says so."
fi

log "  volume claims: $($KC get pvc -o name | tr '\n' ' ')"

step "Done"
log "  $NAME is now kind $DST_KIND with $DST_TYPE naming. State kept in $STATE_DIR."
log "  To reverse: $0 -n $NAMESPACE $NAME --rollback --state-dir $STATE_DIR --apply"
