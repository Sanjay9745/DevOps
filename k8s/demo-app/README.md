# Kind demo: Orders Console and Inventory Dashboard

Two independent responsive NGINX applications share one Traefik HTTP entry point. This project uses the existing `dev-cluster` Kind cluster and never creates, deletes, or recreates it.

```text
localhost:8080
  -> kubectl port-forward -> traefik-demo/demo-traefik Service:80
     -> Traefik web entry point:8000
        -> demo/demo-ingress (IngressClass: demo-traefik)
           /app1 -> demo/app1-service:80 -> app1 Pods:80 (2 replicas)
           /app2 -> demo/app2-service:80 -> app2 Pods:80 (2 replicas)
```

## Prerequisites

- Ubuntu Linux with Bash, `kubectl`, Helm 3.9+ (Helm 3 recommended), and `curl` installed.
- The existing Kind cluster has one control-plane and two workers, a working CNI, and Kubernetes 1.25+. All nodes should be Ready.
- Kubeconfig contains `kind-dev-cluster`, with permissions to manage namespaces, Deployments, Services, ConfigMaps, Ingresses, IngressClasses, and Helm's RBAC resources.
- Internet access for the Helm repository and container image pulls, and a free localhost TCP port 8080.
- `demo`, `traefik-demo`, and the `demo-traefik` release/IngressClass names are reserved for this project. Check for existing resources with these names before deploying into a shared cluster.

If needed, export kubeconfig from the existing cluster; this does not recreate it:

```bash
kind export kubeconfig --name dev-cluster
kubectl --context kind-dev-cluster get nodes -o wide
```

The chart is pinned to **41.6.0**, which supplies Traefik **v3.7.13** and requires Kubernetes 1.25+. Application images use the official `nginx:stable-alpine` maintenance tag. This tag can change; pin a tested digest in both manifests when identical image bytes across nodes/runs are required.

## Files

Application code lives in separate folders so the Kubernetes YAML stays focused on Deployments and Services:

```text
demo-app/
├── app1/
│   ├── index.html       # Orders Console page
│   ├── styles.css       # Orders Console styling
│   └── nginx.conf       # NGINX routing for /app1
├── app2/
│   ├── index.html       # Inventory Dashboard page
│   ├── styles.css       # Inventory Dashboard styling
│   └── nginx.conf       # NGINX routing for /app2
├── 00-namespace.yaml
├── 01-app1.yaml
├── 02-app2.yaml
├── 03-ingress.yaml
├── traefik-values.yaml
├── deploy.sh
└── README.md
```

| File | Contents |
| --- | --- |
| `00-namespace.yaml` | Namespace `demo` |
| `app1/` | Orders HTML, CSS, and NGINX configuration source files |
| `app2/` | Inventory HTML, CSS, and NGINX configuration source files |
| `01-app1.yaml` | Orders Deployment and ClusterIP Service; references `app1-content` ConfigMap |
| `02-app2.yaml` | Inventory Deployment and ClusterIP Service; references `app2-content` ConfigMap |
| `03-ingress.yaml` | Standard `networking.k8s.io/v1` Ingress with two Prefix paths |
| `traefik-values.yaml` | ClusterIP controller, dedicated IngressClass, resources, access logs |
| `deploy.sh` | Generates ConfigMaps from app folders, installs resources, waits, and starts port-forward |

## Deploy and open

Run inside this directory on Ubuntu. From WSL, the Windows folder is `/mnt/e/DevOps/k8s/demo-app`; the kubeconfig and cluster must be reachable from that Ubuntu environment.

```bash
cd /path/to/demo-app
chmod +x deploy.sh
./deploy.sh
```

The script explicitly targets `kind-dev-cluster` for every cluster operation without changing your current context. It creates the namespace, generates and applies both ConfigMaps from the app folders, installs/upgrades its dedicated Traefik release, applies the remaining resource manifests, restarts both apps to load ConfigMap changes, waits for all three Deployments, and displays resources. `traefik-values.yaml` is Helm input, not a Kubernetes resource; do not run `kubectl apply -f .`.

The script then stays in the foreground forwarding `127.0.0.1:8080` to Traefik. Keep the terminal open and visit:

- Orders: <http://localhost:8080/app1> or <http://localhost:8080/app1/>
- Inventory: <http://localhost:8080/app2> or <http://localhost:8080/app2/>

Ctrl+C stops forwarding; the applications remain deployed. To install without starting forwarding:

```bash
SKIP_PORT_FORWARD=1 ./deploy.sh

# Then start forwarding in its own terminal:
kubectl --context kind-dev-cluster -n traefik-demo port-forward \
  --address 127.0.0.1 service/demo-traefik 8080:80
```

No Kind port mappings, NodePort, LoadBalancer, hosts-file changes, or additional localhost ports are needed. A port-forward selects one controller Pod; restart it if that Pod is replaced. If a browser resolves localhost to IPv6 first, use `http://127.0.0.1:8080/app1/`.

## How source files become ConfigMaps

Kubernetes cannot read a local HTML file simply because a YAML file references it. We first package the source files in a ConfigMap, then the Deployment mounts that ConfigMap inside the NGINX container:

```text
app1/index.html  -> app1-content key index.html  -> /usr/share/nginx/html/app1/index.html
app1/styles.css  -> app1-content key styles.css  -> /usr/share/nginx/html/app1/styles.css
app1/nginx.conf  -> app1-content key default.conf -> /etc/nginx/conf.d/default.conf
```

App2 follows the same pattern with `app2-content` and `/usr/share/nginx/html/app2/`. The YAML volume `items` selects these keys and their filenames inside each mounted directory.

To practice creating the ConfigMaps manually, run from the project directory:

```bash
kubectl --context kind-dev-cluster apply -f 00-namespace.yaml

kubectl --context kind-dev-cluster -n demo create configmap app1-content \
  --from-file=index.html=app1/index.html \
  --from-file=styles.css=app1/styles.css \
  --from-file=default.conf=app1/nginx.conf \
  --dry-run=client -o yaml | kubectl --context kind-dev-cluster apply -f -

kubectl --context kind-dev-cluster -n demo create configmap app2-content \
  --from-file=index.html=app2/index.html \
  --from-file=styles.css=app2/styles.css \
  --from-file=default.conf=app2/nginx.conf \
  --dry-run=client -o yaml | kubectl --context kind-dev-cluster apply -f -

kubectl --context kind-dev-cluster apply -f 01-app1.yaml -f 02-app2.yaml
```

`--dry-run=client -o yaml` generates the ConfigMap YAML locally; piping it to `apply -f -` creates or updates that ConfigMap in the cluster. Remove the pipe to inspect the generated YAML for learning. Run these commands in Bash with `set -o pipefail` so a generation failure is reported. Traefik and the Ingress must also be installed for browser access; `deploy.sh` handles the complete setup.

## How paths and assets work

Traefik forwards the original URL path. Each Deployment mounts its ConfigMap's `index.html` and `styles.css` under its application's matching NGINX directory (`/usr/share/nginx/html/app1` or `/app2`). NGINX serves the bare prefix directly and uses `try_files` to return the application shell for nested routes. No external redirects are needed, so the forwarded localhost port is preserved.

Each HTML document has an absolute base URL (`/app1/` or `/app2/`). Relative stylesheets and links therefore resolve correctly from the bare path, trailing slash, and deep routes. The demo links `/app1/orders/recent` and `/app2/stock/overview` return their respective application shells; they are routing examples, not backend APIs. Missing static assets return 404 rather than HTML. Traefik's `strictPrefixMatching` prevents `/app10` from matching `/app1`.

The apps have separate selectors (`app: app1` and `app: app2`), port-80 ClusterIP Services, two replicas each, HTTP readiness/liveness probes, and per-container requests of 50m CPU/32Mi memory and limits of 250m CPU/64Mi memory. Default Kubernetes scheduling is used; a fixed placement or one Pod per worker is not required.

Traefik has its chart's built-in `/ping` readiness/liveness probes, resource requests/limits, a non-default IngressClass, and a namespace watch restricted to `demo`. The dashboard, CRD provider, Gateway provider, and ingress-nginx compatibility provider are disabled. `--skip-crds` avoids installing unused Traefik CRDs. NGINX here serves application content; Traefik is the only Ingress controller installed by this project.

## Verify resources

Run in a second terminal while forwarding remains active:

```bash
kubectl --context kind-dev-cluster -n demo get deployments
kubectl --context kind-dev-cluster -n demo get pods -o wide --show-labels
kubectl --context kind-dev-cluster -n demo get services -o wide
kubectl --context kind-dev-cluster -n demo get endpoints app1-service app2-service
kubectl --context kind-dev-cluster -n demo get endpointslices \
  -l kubernetes.io/service-name=app1-service -o wide
kubectl --context kind-dev-cluster -n demo get endpointslices \
  -l kubernetes.io/service-name=app2-service -o wide
kubectl --context kind-dev-cluster -n demo get ingress -o wide
kubectl --context kind-dev-cluster -n demo describe ingress demo-ingress
kubectl --context kind-dev-cluster get ingressclass demo-traefik -o yaml
kubectl --context kind-dev-cluster -n traefik-demo get deployments,pods,services
helm --kube-context kind-dev-cluster -n traefik-demo status demo-traefik
```

Expect four Ready application Pods, both application Deployments at `2/2`, two ready backend addresses per Service, and one Ready Traefik Pod. EndpointSlices are the preferred API; `Endpoints` is deprecated on newer Kubernetes versions and may show a warning. A blank Ingress `ADDRESS` is expected with a ClusterIP controller and port-forward; it does not indicate a routing failure.

## Verify real HTTP responses

```bash
# Headers and bodies: both must return their corresponding HTML pages.
curl --fail-with-body -i http://127.0.0.1:8080/app1
curl --fail-with-body -i http://127.0.0.1:8080/app2/

# Check bare paths, slashes, assets, and nested routes without following redirects.
for path in /app1 /app1/ /app1/styles.css /app1/orders/recent \
            /app1/orders/recent/ /app2 /app2/ /app2/styles.css \
            /app2/stock/overview /app2/stock/overview/; do
  curl --fail --silent --show-error --output /dev/null \
    --write-out "$path -> %{http_code} %{content_type}\n" \
    "http://127.0.0.1:8080$path" || break
done

# Confirm body identity and CSS MIME type, not just a success status.
curl -fsS http://127.0.0.1:8080/app1/orders/recent | grep '<title>Orders Console</title>'
curl -fsS http://127.0.0.1:8080/app2/stock/overview | grep '<title>Inventory Dashboard</title>'
curl -fsSI http://127.0.0.1:8080/app1/styles.css
curl -fsSI http://127.0.0.1:8080/app2/styles.css

# Each should return 404: unmatched route, segment boundary, missing assets.
for path in / /app10 /app20 /app1/missing.css /app2/missing.js; do
  curl -sS -o /dev/null -w "$path -> %{http_code}\n" "http://127.0.0.1:8080$path"
done
```

All positive paths should return 200. Stylesheets should report `text/css`; pages and nested routes should report `text/html`.

## Scale and update

```bash
kubectl --context kind-dev-cluster -n demo scale deployment/app1 --replicas=3
kubectl --context kind-dev-cluster -n demo scale deployment/app2 --replicas=3
kubectl --context kind-dev-cluster -n demo rollout status deployment/app1 --timeout=300s
kubectl --context kind-dev-cluster -n demo rollout status deployment/app2 --timeout=300s
kubectl --context kind-dev-cluster -n demo get pods,endpointslices -o wide

# Restore the demo defaults:
kubectl --context kind-dev-cluster -n demo scale deployment/app1 deployment/app2 --replicas=2
```

For persistent replica changes, edit `spec.replicas` in the manifests too; rerunning the script reapplies their declared counts. Edit application files in `app1/` and `app2/`. After changing HTML, CSS, or NGINX configuration, regenerate the ConfigMaps before restarting the Pods:

```bash
SKIP_PORT_FORWARD=1 ./deploy.sh
```

For a manual update, repeat the ConfigMap creation commands above, then run `kubectl --context kind-dev-cluster -n demo rollout restart deployment/app1 deployment/app2` and wait for both rollouts. Applying `01-app1.yaml` and `02-app2.yaml` alone does not upload edited application files.

## Troubleshoot routing failures

1. **Connection refused / port already in use:** confirm the forwarding terminal is running. Check `ss -ltnp 'sport = :8080'`, stop the conflicting process, and restart the documented port-forward. Ensure commands use the kubeconfig for the existing cluster.
2. **Traefik 404:** inspect the Ingress, the `demo-traefik` IngressClass, and the `web` entry point. `/` intentionally has no route. Check controller logs for rejected configuration.
3. **502/503:** check Ready Pods and EndpointSlices. Empty endpoints usually mean probes are failing or Service selectors do not match Pod labels.
4. **HTML works but CSS/deep links fail:** inspect the ConfigMap and mounted NGINX config; keep the HTML base URL and app prefixes aligned. Do not add prefix-stripping middleware to this configuration.
5. **Pending / ImagePullBackOff / CrashLoopBackOff:** inspect Pod events for insufficient resources, registry access, or NGINX configuration errors.

```bash
kubectl --context kind-dev-cluster -n demo describe deployment app1
kubectl --context kind-dev-cluster -n demo describe pods -l app=app1
kubectl --context kind-dev-cluster -n demo describe pods -l app=app2
kubectl --context kind-dev-cluster -n demo get events --sort-by=.lastTimestamp
kubectl --context kind-dev-cluster -n demo logs -l app=app1 --all-containers=true --tail=100
kubectl --context kind-dev-cluster -n demo logs -l app=app2 --all-containers=true --tail=100
kubectl --context kind-dev-cluster -n traefik-demo logs deployment/demo-traefik --tail=100
kubectl --context kind-dev-cluster -n demo exec deployment/app1 -- nginx -t
kubectl --context kind-dev-cluster -n demo exec deployment/app2 -- nginx -T
kubectl --context kind-dev-cluster -n demo get configmap app1-content -o yaml
kubectl --context kind-dev-cluster -n demo get service app1-service -o yaml
kubectl --context kind-dev-cluster -n demo get ingress demo-ingress -o yaml
helm --kube-context kind-dev-cluster -n traefik-demo get values demo-traefik

# Bypass Traefik and test the ClusterIP Service from inside an existing app Pod.
# The NGINX Alpine image includes BusyBox wget.
kubectl --context kind-dev-cluster -n demo exec deployment/app1 -- \
  wget -qO- http://app1-service/app1/
kubectl --context kind-dev-cluster -n demo exec deployment/app1 -- \
  wget -qO- http://app2-service/app2/styles.css

# Check the effective Kubernetes manifests against your API server:
kubectl --context kind-dev-cluster apply --dry-run=server \
  -f 00-namespace.yaml -f 01-app1.yaml -f 02-app2.yaml -f 03-ingress.yaml
```

The server dry-run assumes `demo` already exists. To debug previous container crashes, find a Pod name with `get pods` and run `kubectl --context kind-dev-cluster -n demo logs POD_NAME --previous`.

## Clean up, keeping the Kind cluster

Stop port-forwarding with Ctrl+C. Delete the demo's named resources and uninstall its dedicated controller:

```bash
kubectl --context kind-dev-cluster delete \
  -f 03-ingress.yaml -f 02-app2.yaml -f 01-app1.yaml --ignore-not-found
kubectl --context kind-dev-cluster -n demo delete configmap app1-content app2-content --ignore-not-found
helm --kube-context kind-dev-cluster uninstall demo-traefik -n traefik-demo --ignore-not-found

# If these namespaces contain only this demo, remove them too:
kubectl --context kind-dev-cluster delete namespace demo traefik-demo --ignore-not-found

# Verify the existing Kind cluster remains intact:
kubectl --context kind-dev-cluster get nodes
```

Helm removes this release's IngressClass and RBAC resources. This project installs no CRDs; no shared CRD deletion is needed. No cleanup step deletes the Kind cluster.

## References

- [Traefik chart 41.6.0 metadata and Kubernetes compatibility](https://github.com/traefik/traefik-helm-chart/blob/v41.6.0/traefik/Chart.yaml)
- [Traefik chart 41.6.0 values](https://github.com/traefik/traefik-helm-chart/blob/v41.6.0/traefik/values.yaml)
- [Traefik Kubernetes Ingress provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress/)
