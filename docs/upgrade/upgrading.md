### Upgrading

To upgrade Ascender, it is recommended to upgrade the awx-operator to the version that maps to the desired version of Ascender. To find the version of Ascender that will be installed by the awx-operator by default, check the version specified in the `DEFAULT_AWX_VERSION` variable for that particular release. You can do so by running the following command

```shell
AWX_OPERATOR_VERSION=2.8.0
docker run --entrypoint="" quay.io/ansible/awx-operator:$AWX_OPERATOR_VERSION bash -c "env | grep DEFAULT_AWX_VERSION"
```

Apply the awx-operator.yml for that release to upgrade the operator, and in turn also upgrade your Ascender deployment.

#### Backup

The first part of any upgrade should be a backup. Note, there are secrets in the pod which work in conjunction with the database. Having just a database backup without the required secrets will not be sufficient for recovering from an issue when upgrading to a new version. See the [backup role documentation](https://github.com/ansible/awx-operator/tree/devel/roles/backup) for information on how to backup your database and secrets.

In the event you need to recover the backup see the [restore role documentation](https://github.com/ansible/awx-operator/tree/devel/roles/restore). _Before Restoring from a backup_, be sure to:

- delete the old existing AWX CR
- delete the persistent volume claim (PVC) for the database from the old deployment, which has a name like `postgres-18-<deployment-name>-postgres-18-0`

**Note**: Do not delete the namespace/project, as that will delete the backup and the backup's PVC as well.

#### PostgreSQL Upgrade Considerations

If there is a PostgreSQL major version upgrade, after the data directory on the PVC is migrated to the new version, the old PVC is kept by default.
This provides the ability to roll back if needed, but can take up extra storage space in your cluster unnecessarily. You can configure it to be deleted automatically after a successful upgrade by setting the following variable on the AWX spec.

```yaml
spec:
  postgres_keep_pvc_after_upgrade: False
```

##### Upgrading the managed database to PostgreSQL 18

The managed database now runs PostgreSQL 18 (`quay.io/sclorg/postgresql-18-c9s`). When the operator reconciles an existing deployment whose managed database pod is still running an older major version (13 or 15), it upgrades it automatically:

1. The Ascender deployment is scaled down.
2. A new StatefulSet and Service named `<deployment-name>-postgres-18` are created with a new PVC named `postgres-18-<deployment-name>-postgres-18-0`, and the operator-managed postgres configuration secret is recreated with the new host name.
3. Data is streamed from the old database into the new one with `pg_dump | pg_restore`, using the PostgreSQL 18 client tools in the new pod. The time this takes is proportional to the size of the database; the operator logs a progress line every minute.
4. The old StatefulSet and Service are removed. The old PVC (for example `postgres-15-<deployment-name>-postgres-15-0`) is kept so the pre-upgrade data can be recovered if needed.
5. `status.upgradedPostgresVersion` on the AWX resource is set to `18` and the Ascender deployment is scaled back up.

Things to know about this upgrade:

- Take a backup with an `AWXBackup` before upgrading the operator, as with any upgrade.
- The migration uses dump and restore rather than `pg_upgrade`, so the jump from 15 to 18 happens in one step and the data checksum mismatch that `pg_upgrade` would otherwise hit does not apply. The new cluster is initialized with data checksums enabled, which is the PostgreSQL 18 `initdb` default.
- The sclorg image's built-in `POSTGRESQL_UPGRADE` mode (in-place `pg_upgrade`) is not used; it only supports upgrading from the image's immediately preceding version (16).
- The image writes the `md5` method into `pg_hba.conf`, but user passwords are stored as SCRAM-SHA-256 verifiers (the server default since PostgreSQL 14), so clients authenticate with SCRAM-SHA-256 and no MD5 authentication takes place. The PostgreSQL 18 MD5 deprecation warning is only emitted when an MD5-hashed password is set.
- External (unmanaged) databases are not touched. The backup and restore management pods now use PostgreSQL 18 client tools, which work against older external servers.
- Settings new in PostgreSQL 16 through 18 can be configured with `postgres_extra_settings`; see the [database configuration guide](../user-guide/database-configuration.md#settings-introduced-in-postgresql-16-17-and-18). In particular, do not set `io_method` to `io_uring`.

#### v0.14.0

##### Cluster-scope to Namespace-scope considerations

Starting with awx-operator 0.14.0, Ascender can only be deployed in the namespace that the operator exists in. This is called a namespace-scoped operator. If you are upgrading from an earlier version, you will want to
delete your existing `awx-operator` service account, role and role binding.

##### Project is now based on v1.x of the operator-sdk project

Starting with awx-operator 0.14.0, the project is now based on operator-sdk 1.x. You may need to manually delete your old operator Deployment to avoid issues.

##### Steps to upgrade

Delete your old Ascender Operator and existing `awx-operator` service account, role and role binding in `default` namespace first:

```
$ kubectl -n default delete deployment awx-operator
$ kubectl -n default delete serviceaccount awx-operator
$ kubectl -n default delete clusterrolebinding awx-operator
$ kubectl -n default delete clusterrole awx-operator
```

Then install the new Ascender Operator by following the instructions in [Basic Install](../installation/basic-install.md). The `NAMESPACE` environment variable have to be the name of the namespace in which your old Ascender instance resides.

Once the new Ascender Operator is up and running, your Ascender deployment will also be upgraded.
