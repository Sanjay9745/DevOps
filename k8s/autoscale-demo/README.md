# Kubernetes Two-Layer Autoscaling & Cost Optimization Masterclass
**Project Location:** `E:\DevOps\k8s\autoscale-demo`

## 1. The Core Mental Model: Why HPA Alone Does NOT Save Cloud VM Costs!

A very common beginner misconception in Kubernetes is: *"If I configure an HPA (Horizontal Pod Autoscaler), Kubernetes will automatically add and remove cloud servers (EC2 / GCP VMs) to save money."*

**In reality, Kubernetes autoscaling is split into TWO completely separate layers that work together as a relay team:**

```text
                    [ TRAFFIC SPIKE (e.g., 8:00 PM Flash Sale) ]
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ LAYER 1: Horizontal Pod Autoscaler (HPA)  --> Scales PODS (Application Layer)   │
│  • Watches CPU/Memory via Metrics Server every 15 seconds.                      │
│  • Sees Pod CPU jump to 180% -> Increases Deployment replicas from 1 to 10.     │
│  • Problem: Existing worker nodes only have room for 4 pods!                    │
│  • Result: 6 Pods get stuck in "Pending" state (Reason: Insufficient cpu).      │
└─────────────────────────────────────────────────────────────────────────────────┘
                                         │
                        ("Pending" Pods trigger Layer 2!)
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ LAYER 2: Node Autoscaler (Cluster Autoscaler or Karpenter) --> Scales VMs       │
│  • Does NOT look at CPU usage %! It ONLY watches for "Pending" Pods!            │
│  • Calculates how much CPU/RAM the 6 Pending pods request (6 * 200m = 1.2 vCPU) │
│  • Calls AWS/GCP/Azure API to spin up a new Worker Node (VM).                   │
│  • Once the Node joins the cluster, the 6 Pending pods become "Running".        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### How It Saves Money When Traffic Drops (The Scale-In Relay)
When the flash sale ends at 10:00 PM:
1. **Layer 1 (HPA) acts first:** Sees CPU utilization drop to `5%`. After waiting `180s` (the stabilization window so it doesn't overreact to a brief dip), HPA terminates the extra Pods down to `minReplicas: 1`.
2. **Layer 2 (Node Autoscaler) acts second:** Notices that Worker Node #2 and Worker Node #3 now have `0` running pods (or are under `50%` requested capacity). After a 2-to-5 minute cooldown, it **cordons** the node (stops new pods from landing there), **drains** any remaining pods safely onto Node #1 (respecting your `PodDisruptionBudget`), and **terminates the cloud VM instance** so you stop paying for it hourly!

---

## 2. Project File Structure

```text
E:\DevOps\k8s\autoscale-demo\
├── 00-namespace.yaml                        # Isolated 'autoscale-demo' namespace
├── 01-app-deployment.yaml                   # Checkout API Deployment (with requests/limits) & Service
├── 02-hpa.yaml                              # HPA v2 (fast scale-up, safe scale-down) + PDB
├── 03-node-autoscaling/
│   ├── cluster-autoscaler.yaml              # Option A: Standard K8s Cluster Autoscaler (AWS ASG / GCP / Azure)
│   └── karpenter-nodepool.yaml              # Option B: Karpenter NodePool (Spot + On-Demand + Consolidation)
├── 04-load-generator.yaml                   # Busybox HTTP flood generator to simulate a Flash Sale
├── run-demo.sh                              # Helper script to deploy, trigger load, watch, and cool down
└── README.md                                # This complete guide
```

---

## 3. Deep Dive: The 4 Golden Rules of Cost-Saving Autoscaling

### Rule 1: `resources.requests` is the Bridge Between Pods and Cloud Billing
Look inside [`01-app-deployment.yaml`](./01-app-deployment.yaml):
```yaml
resources:
  requests:
    cpu: "200m"      # 0.2 vCPU guaranteed
    memory: "128Mi"
  limits:
    cpu: "500m"      # 0.5 vCPU max burst
    memory: "256Mi"
```
* **Why HPA needs `requests`:** HPA calculates utilization using:
  $$\text{CPU Utilization \%} = \frac{\text{Actual CPU Usage (from Metrics Server)}}{\text{Pod Requested CPU (\texttt{requests.cpu})}} \times 100$$
  If you omit `requests.cpu`, **HPA will refuse to work** (`missing request for cpu`).
* **Why Node Autoscaler needs `requests`:** Cluster Autoscaler and Karpenter **never look at actual CPU usage** when deciding to buy or terminate a VM. They only sum up `resources.requests` of the pods on a node.
  * *Real-world mistake:* If your pod uses `50m` CPU in reality, but you set `requests.cpu: 2000m` (2 full vCPUs), the Node Autoscaler will buy expensive VMs that sit 97% idle! **Right-sizing `requests` is the #1 way to save money in Kubernetes.**

### Rule 2: Asymmetric Scaling in HPA (`02-hpa.yaml`)
In [`02-hpa.yaml`](./02-hpa.yaml), we use the `autoscaling/v2` `behavior` block:
* **Scale Up Fast (`stabilizationWindowSeconds: 0`):** When customers flood your site, you cannot wait 5 minutes to scale pods. We allow doubling pods (`100%` or `4 pods`) every 15 seconds.
* **Scale Down Slowly (`stabilizationWindowSeconds: 180`):** Prevent **"thrashing / flapping"** (scaling up and down every minute). Also, cloud VMs take ~60-90 seconds to boot and many clouds bill a minimum of 1 minute, so keeping pods warm for 3 minutes after a spike protects both user latency and node churn.

### Rule 3: Always Pair Node Autoscaling with a `PodDisruptionBudget` (`02-hpa.yaml`)
When load decreases and the Node Autoscaler decides to delete an extra worker VM to save money, it evicts any pods still sitting on that node. Without a `PodDisruptionBudget` (PDB), it might evict all your running pods simultaneously, causing a brief outage! Our `checkout-api-pdb` guarantees at least 1 replica is always `Ready` before any node is drained.

### Rule 4: Cluster Autoscaler vs. Karpenter (`03-node-autoscaling/`)
| Feature | Cluster Autoscaler (`cluster-autoscaler.yaml`) | Karpenter (`karpenter-nodepool.yaml`) |
| :--- | :--- | :--- |
| **How it provisions VMs** | Adjusts cloud Auto Scaling Groups (ASGs) of fixed instance types (e.g., only `m5.large`). | Bypasses ASGs; directly calls EC2 Fleet API to pick the exact cheapest VM size (`t3`, `c6i`, `m6i`) for the Pending pods. |
| **Speed** | ~2 to 4 minutes to launch a node. | ~45 to 60 seconds to launch a node. |
| **Cost Optimization** | Scales down when node is `< 50%` utilized for 5-10 mins. | **Active Bin-Packing Consolidation**: Even swaps a large expensive node for a smaller cheaper node automatically! Easily mixes **Spot** (up to 80% cheaper) + **On-Demand**. |

---

## 4. Hands-On Walkthrough: Run the Lab Step-by-Step

### Step 1: Deploy the App, Metrics Server, and HPA
From your terminal (where `kubectl` is connected to your Kind, Minikube, or Cloud cluster):
```bash
cd /mnt/e/DevOps/k8s/autoscale-demo   # Or E:\DevOps\k8s\autoscale-demo in PowerShell
chmod +x run-demo.sh
./run-demo.sh deploy
```
*(Or run the `kubectl` commands directly:)*
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-app-deployment.yaml
kubectl apply -f 02-hpa.yaml
```

Check your initial baseline (1 Pod running, low cost):
```bash
kubectl get hpa,pods -n autoscale-demo
```
You will see:
```text
NAME                                           REFERENCE                 TARGETS                        MINPODS   MAXPODS   REPLICAS
horizontalpodautoscaler.autoscaling/checkout   Deployment/checkout-api   cpu: 1%/50%, memory: 12%/75%   1         10        1
```

### Step 2: Simulate a Flash-Sale Traffic Spike (Scale-Out)
Open a second terminal to watch the cluster live, or run:
```bash
kubectl apply -f 04-load-generator.yaml
kubectl get hpa -n autoscale-demo --watch
```

**What happens over the next 60 seconds:**
1. **T+15s:** `load-generator` floods `checkout-api-svc`. Pod CPU jumps from `1%` to `240%` (above our `50%` target).
2. **T+30s:** HPA calculates `ceil[1 * (240 / 50)] = 5` replicas (capped by our policy of +4 pods per 15s) and scales the Deployment to `5`, then `9`, then `10` pods!
3. **T+45s (Node Autoscaling Trigger):**
   * Run `kubectl get pods -n autoscale-demo`.
   * If your current worker node(s) run out of allocatable CPU (`10 pods * 200m = 2000m` CPU needed), the newest pods will show status **`Pending`**.
   * Run `kubectl describe pod <pending-pod-name> -n autoscale-demo` and look at the bottom `Events`:
     ```text
     Warning  FailedScheduling  default-scheduler  0/2 nodes are available: 2 Insufficient cpu.
     ```
   * **In AWS/GCP/Azure:** That exact `FailedScheduling (Insufficient cpu)` state is what wakes up **Cluster Autoscaler** or **Karpenter** (`03-node-autoscaling/`) to spin up a new VM instance!
   * *(Tip: If you are testing locally on Kind/Minikube where there is no cloud API to buy VMs, you can simulate a new cloud VM joining by running `kind scale` or observing the `Pending` trigger event!)*

### Step 3: Stop the Traffic and Watch Cost-Saving Scale-In
Now stop the flash sale:
```bash
kubectl delete -f 04-load-generator.yaml
```
Watch the scale-in:
```bash
kubectl get hpa -n autoscale-demo --watch
```
**What happens:**
1. **T+15s:** CPU usage immediately drops to `1%/50%`.
2. **T+15s to T+180s (Stabilization Window):** Notice that `REPLICAS` stays at `10` for 3 minutes! Why? Because of `stabilizationWindowSeconds: 180` in `02-hpa.yaml`. This protects your app in case the traffic drop was just a 10-second network blip.
3. **T+180s onwards:** HPA scales down gracefully by `1 pod per minute` (`periodSeconds: 60`) until it reaches `REPLICAS: 1`.
4. **T+300s (Node Termination / Cost Savings):** Once the extra pods are gone, Cluster Autoscaler (`--scale-down-unneeded-time=5m`) or Karpenter (`consolidateAfter: 2m`) sees the extra worker nodes are empty/underutilized and **terminates the cloud VMs**, bringing your infrastructure bill back down to minimum!
