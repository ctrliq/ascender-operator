#### Deploying a specific version of Ascender

There are a few variables that are customizable for awx the image management.

| Name                          | Description               | Default                                    |
| ----------------------------- | ------------------------- | ------------------------------------------ |
| image                         | Path of the image to pull | ghcr.io/ctrliq/ascender                    |
| image_version                 | Image version to pull     | value of DEFAULT_AWX_VERSION or latest     |
| image_pull_policy             | The pull policy to adopt  | IfNotPresent                               |
| image_pull_secrets            | The pull secrets to use   | None                                       |
| ee_images                     | A list of EEs to register | ghcr.io/ctrliq/ascender-ee:latest          |
| redis_image                   | Path of the image to pull | ghcr.io/valkey-io/valkey                   |
| redis_image_version           | Image version to pull     | latest                                     |
| control_plane_ee_image        | Image version to pull     | ghcr.io/ctrliq/ascender-ee:latest          |
| init_container_image          | Path of the image to pull | ghcr.io/ctrliq/ascender-ee                 |
| init_container_image_version  | Image version to pull     | latest                                     |
| init_projects_container_image | Image version to pull     | quay.io/centos/centos:stream9              |

Example of customization could be:

```yaml
---
spec:
  ...
  image: myorg/my-custom-awx
  image_version: latest
  image_pull_policy: Always
  image_pull_secrets:
    - pull_secret_name
  ee_images:
    - name: my-custom-awx-ee
      image: myorg/my-custom-awx-ee
  control_plane_ee_image: myorg/my-custom-awx-ee:latest
  init_container_image: myorg/my-custom-awx-ee
  init_container_image_version: latest
  init_projects_container_image: myorg/my-mirrored-centos:stream9
```

**Note**: The `image` and `image_version` are intended for local mirroring scenarios. `DEFAULT_AWX_VERSION` controls the main Ascender image tag and we are now changing the execution environment default to the same pinned release for `ghcr.io/ctrliq/ascender-ee` unless you override them explicitly. For the current defaults, check [roles/installer/defaults/main.yml](https://github.com/ctrliq/ascender-operator/blob/devel/roles/installer/defaults/main.yml).
