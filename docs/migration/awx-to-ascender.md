# Moving a deployment from the AWX kind to the Ascender kind

The operator serves two API groups for the same four resources: `awx.ansible.com` with
`AWX`, `AWXBackup`, `AWXRestore` and `AWXMeshIngress`, and `ascender.ansible.com` with
`Ascender`, `AscenderBackup`, `AscenderRestore` and `AscenderMeshIngress`.

Nothing has to move. An existing `AWX` keeps reconciling exactly as before, through the
same playbook and the same roles.

## Why this is not an alias

A CRD belongs to exactly one API group, and a conversion webhook converts between
versions within a group, never across groups. `AWX` and `Ascender` are therefore two
different objects with separate storage, and `kubectl get ascender` will not show an
existing AWX.

What makes a move possible instead is that every managed object is named from the custom
resource's own name and from `deployment_type`, which stays `awx` for both kinds. An
`Ascender` named `prod` wants exactly the objects an `AWX` named `prod` already has: the
same `prod-awx-configmap`, the same `prod-postgres-15` StatefulSet, the same database and
the same secrets.

That has a consequence worth stating plainly: an `AWX` and an `Ascender` of the same name
in one namespace would manage the same objects. The operator refuses to reconcile when it
finds the other kind under that name, rather than letting the two fight.

## What the script does

`hack/migrate-awx-to-ascender.sh` performs the move as an ownership swap. Nothing is
deleted except the custom resource itself, so the pods keep running throughout and the
database and its volume are never touched.

```bash
./hack/migrate-awx-to-ascender.sh -n <namespace> <name>            # prints the plan, changes nothing
./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --apply    # performs it
```

In order, it:

- refuses unless the `Ascender` CRD is installed, the named `AWX` exists, no `Ascender`
  of that name is in the way, and every deployment and statefulset is fully ready
- records every object carrying an owner reference to the custom resource, and the uid of
  every pod, to a state directory
- deletes the custom resource with `--cascade=orphan`, which leaves those objects running
- creates the `Ascender` from the saved spec, under the same name
- copies the saved `status` across, so the secret names and `upgradedPostgresVersion` are
  not derived a second time
- repoints the owner reference of every recorded object at the new custom resource
- verifies the object set is unchanged and that no pod was replaced, by uid
- reports any `AWXBackup` or `AWXRestore` that names this deployment, since those default
  to `deployment_kind: AWX` and will no longer find it

The PersistentVolumeClaim never appears in that inventory. It is created by the
StatefulSet from `volumeClaimTemplates` and carries no owner reference to the custom
resource, which is exactly why the data is not at risk here.

## Reversing it

The state directory is what makes the move reversible:

```bash
./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --rollback --state-dir <dir> --apply
```

## If it stops part way

Between the delete and the create the deployment is running but unmanaged. That is not an
outage, since no workload is touched, but an ordinary re-run would find no `AWX` to
migrate. Carry on from the saved state instead:

```bash
./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --apply --resume --state-dir <dir>
```

Every step from the create onwards tolerates being run twice.

## Afterwards

Recreate any backup or restore objects for this deployment as `AscenderBackup` and
`AscenderRestore`. The script lists the ones it found.
