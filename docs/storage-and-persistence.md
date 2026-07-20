# Storage: Volumes, PersistentVolumes, PersistentVolumeClaims, StorageClass

Four layers, each solving a different problem. Grounded in two real examples already running on
this cluster: `full-stack-app`'s Postgres `StatefulSet`, and Kubeflow Pipelines' MySQL +
SeaweedFS (see `kubeflow-pipeline-sample/INSTALL-KUBEFLOW.md`).

## The four layers

1. **Volume** — storage attached to a Pod, sharing the Pod's lifecycle. An `emptyDir` (used by
   `full-stack-app`'s backup CronJob for scratch space) is created empty when the Pod starts and
   deleted when the Pod is removed — not persistence, just a shared disk between containers in
   one Pod or scratch space that survives a container restart (not a Pod restart).
2. **PersistentVolume (PV)** — a piece of real storage (a cloud disk, an NFS export, a hostPath
   directory) registered as a cluster object, independent of any Pod's lifecycle.
3. **PersistentVolumeClaim (PVC)** — a request for storage ("give me 20Gi, RWO") made by a
   workload. Kubernetes binds it to a matching PV. This is the object your Deployment/StatefulSet
   actually references — you almost never reference a PV directly.
4. **StorageClass** — tells Kubernetes *how* to dynamically create a PV when a PVC asks for one,
   instead of requiring PVs to be pre-provisioned by hand. `storageClassName` on a PVC picks
   which provisioner handles it.

```
PVC (I need 20Gi)  --binds to-->  PV (here's 20Gi)  --backed by-->  actual disk
       ^
       | dynamically created by, per StorageClass's provisioner, if no matching PV exists yet
```

## Static volumes (no PVC) — the CronJob example

```yaml
# full-stack-app/templates/backup-cronjob.yaml
volumeMounts:
  - name: backup
    mountPath: /backups
volumes:
  - name: backup
    emptyDir: {}
```

Deliberately not persistent — the chart's own comment flags it as illustrative, meant to be
pointed at a real PVC or object-store mount before relying on it. Good default to reach for
when you want "a directory the container(s) can use", not "data that outlives the Pod."

## PVC + StorageClass — the StatefulSet example

```yaml
# full-stack-app/charts/database/templates/statefulset.yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: {{ .Values.persistence.storageClassName | quote }}
      resources:
        requests:
          storage: {{ .Values.persistence.size }}
```

`volumeClaimTemplates` is StatefulSet-specific: instead of one shared PVC, each replica gets its
**own** PVC, named `data-<statefulset-name>-<ordinal>` — replica 0 always gets the same PV back
across restarts/rescheduling, never another replica's disk. This is the core reason Postgres is
a `StatefulSet` and not a `Deployment` (see [`workload-types.md`](./workload-types.md)).

## What's actually on this cluster (minikube)

```bash
$ kubectl get pvc -n kubeflow
NAME             STATUS   VOLUME                          CAPACITY   ACCESS MODES   STORAGECLASS
mysql-pv-claim   Bound    pvc-f5a59267-...                20Gi       RWO            standard
seaweedfs-pvc    Bound    pvc-bb8ee446-...                20Gi       RWO            standard

$ kubectl get storageclass
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   k8s.io/minikube-hostpath    Delete          Immediate
```

minikube's only StorageClass, `standard`, dynamically provisions PVs backed by directories on
the node's own filesystem (`hostpath-provisioner`) — e.g. Kubeflow's MySQL PVC resolves to
`/tmp/hostpath-provisioner/kubeflow/mysql-pv-claim` **inside the node's container**, as
documented in `INSTALL-KUBEFLOW.md`. That's why it survives `minikube stop`/`start` (the node
container's filesystem persists) but is gone if the node itself is deleted
(`minikube delete`) — there's no real disk or cloud volume backing it, just a directory.

**On EKS**, the equivalent StorageClass is typically `gp3`/`gp2` via the `ebs.csi.aws.com`
provisioner — a PVC there provisions a real EBS volume, which is why `ReclaimPolicy` matters a
lot more in production: `Delete` (default) destroys the EBS volume when the PVC is deleted,
`Retain` leaves it (and its data) around, orphaned, for manual cleanup or reattachment.

## Access modes

| Mode | Meaning |
|---|---|
| `ReadWriteOnce` (RWO) | One node can mount it read-write. Fine for one Pod; multiple Pods **on the same node** can technically share it, but don't rely on that. Most cloud block storage (EBS, GCE PD) is RWO-only. |
| `ReadOnlyMany` (ROX) | Many nodes, read-only. |
| `ReadWriteMany` (RWX) | Many nodes, read-write — needs a storage backend that supports concurrent multi-node writers (EFS, NFS, some CSI drivers). This is why `mysql`/`seaweedfs` above are RWO (each is a single Pod owning its own disk), not something you'd give 3 replicas simultaneous write access to. |

## Quick reference

```bash
kubectl get pv                          # cluster-scoped, not namespaced
kubectl get pvc -n <namespace>
kubectl describe pvc <name> -n <namespace>
kubectl get storageclass
```
