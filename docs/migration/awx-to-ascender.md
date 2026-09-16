# Moving a deployment from the AWX kind to the Ascender kind

The operator serves two API groups for the same four resources: `awx.ansible.com` with
`AWX`, `AWXBackup`, `AWXRestore` and `AWXMeshIngress`, and `ascender.ansible.com` with
`Ascender`, `AscenderBackup`, `AscenderRestore` and `AscenderMeshIngress`.

Nothing has to move. An existing `AWX` keeps reconciling exactly as before, through the
same playbook and the same roles.

## What differs between the two

A CRD belongs to exactly one API group, and a conversion webhook converts between
versions within a group, never across groups. `AWX` and `Ascender` are therefore two
different objects with separate storage, and `kubectl get ascender` will not show an
existing AWX.

They also no longer name things the same way. `deployment_type` follows the kind, so a
deployment created as an `Ascender` calls its database `ascender`, gives its objects
`app.kubernetes.io/managed-by: ascender-operator`, and mounts an
`<name>-ascender-configmap`. A deployment created as an `AWX` says `awx` in all three.

That is what makes moving one across more than a relabelling. `deployment_type` appears
in `spec.selector.matchLabels` on the two Deployments and the postgres StatefulSet, and
Kubernetes does not allow a selector to change after creation, so those three have to be
recreated. The database has to be renamed too, and nothing may be connected to it while
that happens.

## So this is a migration with downtime

`hack/migrate-awx-to-ascender.sh` performs it.

```bash
./hack/migrate-awx-to-ascender.sh -n <namespace> <name>            # prints the plan, changes nothing
./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --apply    # performs it
```

In order, it:

- refuses unless the `Ascender` CRD is installed, the named `AWX` exists, no `Ascender`
  of that name is in the way, every deployment and statefulset is ready, and the postgres
  configuration secret says `type: managed`
- records every object carrying an owner reference to the resource, and the uid of every
  pod, to a state directory
- scales the web and task Deployments to zero and waits for their pods to go, which is
  where the deployment stops serving
- renames the database and its role to `ascender` inside the postgres pod, and writes both
  into the postgres configuration secret
- deletes the resource with `--cascade=orphan`, then deletes the two Deployments and the
  StatefulSet, whose selectors cannot be changed
- creates the `Ascender` from the saved spec, under the same name, and copies the status
  across so the secret names and `upgradedPostgresVersion` are not derived again
- repoints the owner references of everything that survived, and drops the leftover
  `<name>-awx-configmap` and `<name>-awx-pre-stop-scripts`
- waits for the operator to rebuild what it removed, which is where serving resumes

## What is never copied

The data. The PersistentVolumeClaim comes from `volumeClaimTemplates` and carries no
owner reference to the resource, so it is not deleted and the rebuilt StatefulSet binds
the same volume. The database is renamed in place rather than dumped and reloaded, and
the secrets outlive the resource because `garbage_collect_secrets` defaults to `false`.

## An external database

The script refuses when the postgres configuration secret says `type: unmanaged`. It will
only rename a database the operator manages. Rename the database and its role yourself,
update the secret, and re-run with `--resume`.

## Reversing it

The state directory is what makes the move reversible, database included:

```bash
./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --rollback --state-dir <dir> --apply
```

## If it stops part way

Carry on from the saved state rather than starting again:

```bash
./hack/migrate-awx-to-ascender.sh -n <namespace> <name> --apply --resume --state-dir <dir>
```

Every step is written to tolerate being run twice: a rename that has already happened is
skipped, and a resource that already exists is left alone.

## Afterwards

Recreate any backup or restore objects for this deployment as `AscenderBackup` and
`AscenderRestore`. They default to `deployment_kind: AWX` and will no longer find it.
