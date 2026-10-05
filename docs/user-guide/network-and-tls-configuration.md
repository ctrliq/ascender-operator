### Network and TLS Configuration

#### Service Type

If the `service_type` is not specified, the `ClusterIP` service will be used for your Ascender service.

The `service_type` supported options are: `ClusterIP`, `LoadBalancer` and `NodePort`.

The following variables are customizable for any `service_type`

| Name                | Description             | Default      |
| ------------------- | ----------------------- | ------------ |
| service_labels      | Add custom labels       | Empty string |
| service_annotations | Add service annotations | Empty string |

```yaml
---
spec:
  ...
  service_type: ClusterIP
  service_annotations: |
    environment: testing
  service_labels: |
    environment: testing
```

  * LoadBalancer

The following variables are customizable only when `service_type=LoadBalancer`

| Name                  | Description                              | Default |
| --------------------- | ---------------------------------------- | ------- |
| loadbalancer_protocol | Protocol to use for Loadbalancer ingress | http    |
| loadbalancer_port     | Port used for Loadbalancer ingress       | 80      |
| loadbalancer_ip       | Assign Loadbalancer IP                   | ''      |
| loadbalancer_class    | LoadBalancer class to use                | ''      |

```yaml
---
spec:
  ...
  service_type: LoadBalancer
  loadbalancer_ip: '192.168.10.25'
  loadbalancer_protocol: https
  loadbalancer_port: 443
  loadbalancer_class: service.k8s.aws/nlb
  service_annotations: |
    environment: testing
  service_labels: |
    environment: testing
```

When setting up a Load Balancer for HTTPS you will be required to set the `loadbalancer_port` to move the port away from `80`.

The HTTPS Load Balancer also uses SSL termination at the Load Balancer level and will offload traffic to Ascender over HTTP.

  * NodePort

The following variables are customizable only when `service_type=NodePort`

| Name          | Description            | Default |
| ------------- | ---------------------- | ------- |
| nodeport_port | Port used for NodePort | 30080   |

```yaml
---
spec:
  ...
  service_type: NodePort
  nodeport_port: 30080
```
#### Ingress Type

By default, the Ascender Operator is not opinionated and won't force a specific ingress type on you. So, when the `ingress_type` is not specified, it will default to `none` and nothing ingress-wise will be created.

The `ingress_type` supported options are: `none`, `ingress`, `route` and `httproute`. To toggle between these options, you can add the following to your Ascender CR. See [Changing ingress_type](#changing-ingress_type) for what happens to the old object when you switch.

  * None

```yaml
---
spec:
  ...
  ingress_type: none
```

  * Generic Ingress Controller

The following variables are customizable when `ingress_type=ingress`. The `ingress` type creates an Ingress resource as [documented](https://kubernetes.io/docs/concepts/services-networking/ingress/) which can be shared with many other Ingress Controllers as [listed](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/).

| Name                               | Description                                                                        | Default                     |
| ---------------------------------- | ---------------------------------------------------------------------------------- | --------------------------- |
| ingress_annotations                | Ingress annotations                                                                | Empty string                |
| ingress_tls_secret _(deprecated)_  | Secret that contains the TLS information                                           | Empty string                |
| ingress_class_name                 | Define the ingress class name                                                      | Cluster default             |
| hostname _(deprecated)_            | Define the FQDN                                                                    | {{ meta.name }}.example.com |
| ingress_hosts                      | Define one or multiple FQDN with optional Secret that contains the TLS information | Empty string                |
| ingress_path                       | Define the ingress path to the service                                             | /                           |
| ingress_path_type                  | Define the type of the path (for LBs)                                              | Prefix                      |
| ingress_api_version                | Define the Ingress resource apiVersion                                             | 'networking.k8s.io/v1'      |

```yaml
---
spec:
  ...
  ingress_type: ingress
  ingress_hosts:
    - hostname: ascender-demo.example.com
    - hostname: ascender-demo.sample.com
      tls_secret: sample-tls-secret
  ingress_annotations: |
    environment: testing
```

##### Specialized Ingress Controller configuration

Some Ingress Controllers need a special configuration to fully support Ascender, add the following value with the `ingress_controller` variable, if you are using one of these:

| Ingress Controller name               | value   |
| ------------------------------------- | ------- |
| [Contour](https://projectcontour.io/) | contour |

```yaml
---
spec:
  ...
  ingress_type: ingress
  ingress_hosts:
    - hostname: ascender-demo.example.com
    - hostname: ascender-demo.sample.com
      tls_secret: sample-tls-secret
  ingress_controller: contour
```

  * Gateway API (HTTPRoute)

The `httproute` type creates a [Gateway API](https://gateway-api.sigs.k8s.io/) `HTTPRoute` (`gateway.networking.k8s.io/v1`) named after the instance and attaches it to an existing Gateway. The operator does not create the Gateway, its listeners or their TLS certificates. It requires the Gateway API CRDs v1.0 or later and a Gateway API implementation.

| Name                | Description                                                                                                                                    | Default      |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| gateway_parent_refs | Required. The Gateways to attach to, each a Gateway API [ParentReference](https://gateway-api.sigs.k8s.io/reference/api-spec/#parentreference). `sectionName` picks a listener by its `name` | `[]`         |
| gateway_annotations | HTTPRoute annotations                                                                                                                          | Empty string |
| ingress_hosts       | The `hostname` of each entry becomes an HTTPRoute hostname. `tls_secret` is ignored: TLS is configured on the Gateway listener                 | Empty string |
| hostname            | The HTTPRoute hostname when `ingress_hosts` is empty. With neither set, the route answers for every hostname the listener accepts              | Empty string |
| ingress_path        | Path prefix the route matches                                                                                                                  | /            |

`ingress_class_name`, `ingress_controller`, `ingress_annotations` and `ingress_path_type` do not apply to an HTTPRoute. The route targets port 80 of the `<instance-name>-service` Service, which the default `ClusterIP` `service_type` provides.

```yaml
---
spec:
  ...
  ingress_type: httproute
  ingress_hosts:
    - hostname: ascender-demo.example.com
  gateway_parent_refs:
    - name: shared-gateway
      namespace: gateway-system
      sectionName: https
  gateway_annotations: |
    environment: testing
```

TLS is terminated on the Gateway listener. An example listener for the route above:

```yaml
listeners:
  - name: https                 # matches sectionName
    protocol: HTTPS
    port: 443
    hostname: ascender-demo.example.com
    tls:
      mode: Terminate
      certificateRefs:
        - name: ascender-demo-tls
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            kubernetes.io/metadata.name: <ascender namespace>
```

A listener admits routes only from its own namespace (`from: Same`) unless `allowedRoutes` says otherwise. The route's status shows whether each Gateway accepted it:

```
kubectl -n <namespace> get httproute <instance-name> -o jsonpath='{.status.parents[*].conditions}'
```

  * Route

The following variables are customizable when `ingress_type=route`

| Name                            | Description                                   | Default                                                 |
| ------------------------------- | --------------------------------------------- | ------------------------------------------------------- |
| route_host                      | Common name the route answers for             | `<instance-name>-<namespace>-<routerCanonicalHostname>` |
| route_tls_termination_mechanism | TLS Termination mechanism (Edge, Passthrough) | Edge                                                    |
| route_tls_secret                | Secret that contains the TLS information      | Empty string                                            |
| route_api_version               | Define the Route resource apiVersion          | 'route.openshift.io/v1'                                 |

```yaml
---
spec:
  ...
  ingress_type: route
  route_host: ascender-demo.example.com
  route_tls_termination_mechanism: Passthrough
  route_tls_secret: custom-route-tls-secret-name
```

##### Changing ingress_type

When `ingress_type` changes between `ingress`, `route` and `httproute`, the operator creates the new object and then deletes the object it created for the previous value.

- Only objects owned by this Ascender CR are deleted.
- The previous value is read from `status.ingressType`. If it is not set, nothing is deleted.
- Changing to or from `none` deletes nothing.
- When switching to `httproute`, the previous object is deleted only after every Gateway in `gateway_parent_refs` has accepted the route and resolved its backend. The operator waits up to two minutes at the end of the reconcile. If the route is not accepted, the reconcile fails, the previous object is kept, and the change is retried on the next reconcile. To back out, set `ingress_type` to its previous value and delete the HTTPRoute with `kubectl -n <namespace> delete httproute <instance-name>`.

To switch without downtime, create an HTTPRoute with a different name, for example `<instance-name>-cutover`, the same `parentRefs` and `hostnames`, and a backendRef to the `<instance-name>-service` Service on port 80. Point DNS at the Gateway, then change `ingress_type` and delete the cutover route.
