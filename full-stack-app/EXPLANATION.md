# EXPLANATION.md — full-stack-app, explained from zero

This file explains everything in simple words. It does not assume you
know Kubernetes or Helm already. Read it top to bottom, in order.

---

## 1. The big picture, in one paragraph

**Kubernetes** is a system that runs your apps inside containers, on one
or many computers. **Helm** is a tool that installs apps into Kubernetes.
A **Helm chart** is a folder of template files that describe an app. When
you run `helm install`, Helm fills in the templates and sends the result
to Kubernetes. Kubernetes then creates the real things (running
containers, network rules, storage, etc).

This project, `full-stack-app`, is one Helm chart. It describes a small
demo app with three parts:

```
you (browser / curl)
        |
        v
   [ frontend ]  <-- a web page (nginx)
        |
        v
   [ backend ]   <-- a small API (returns JSON text)
        |
        v
   [ database ]  <-- postgres, stores data
```

Each part runs as one or more containers inside Kubernetes.

---

## 2. Words you will see everywhere

Kubernetes and Helm use many short words. Here is what each one means.
Come back to this list any time you see a word you forgot.

| Word | Simple meaning |
|---|---|
| **Cluster** | A group of computers (or one computer, for local testing) that runs Kubernetes. |
| **Node** | One computer inside the cluster. |
| **Pod** | The smallest unit Kubernetes runs. Usually one Pod = one running copy of your app (one container, sometimes a few). |
| **Namespace** | A named folder inside the cluster, used to group related things together and keep them separate from other apps. This chart uses the namespace `fullstack`. |
| **Chart** | A folder of Helm templates. This whole `full-stack-app/` folder is a chart. |
| **Subchart** | A smaller chart living inside a bigger chart's `charts/` folder. This chart has three: `frontend`, `backend`, `database`. |
| **Release** | One installed copy of a chart, with a name you choose (e.g. `demo`). You could install the same chart twice under two release names. |
| **Revision** | Every `helm install` or `helm upgrade` creates a new numbered revision of a release, so you can undo changes later. |
| **Values** | The settings you pass into a chart (e.g. how many copies to run, what image to use). Stored in `values.yaml` files. |
| **Manifest** | A YAML file that describes one Kubernetes object (e.g. one Deployment). Helm generates manifests from templates + values. |
| **Template** | A YAML file with `{{ ... }}` placeholders. Helm replaces the placeholders with real values before sending it to Kubernetes. |

---

## 3. The folder structure, file by file

```
full-stack-app/
├── Chart.yaml              <- Name and version of this chart
├── values.yaml               <- Default settings for the whole app
├── values.schema.json        <- Rules that check your values.yaml is valid
├── README.md                 <- Commands to install, test, and clean up
├── EXPLANATION.md            <- This file
├── .helmignore               <- Files Helm should skip when packaging
│
├── templates/                <- Things that are NOT owned by one single part
│   │                              (frontend / backend / database), but tie
│   │                              them together
│   ├── namespace.yaml          <- (optional) creates the fullstack namespace
│   ├── ingress.yaml             <- routes web traffic to frontend/backend
│   ├── networkpolicy.yaml       <- firewall rules between the three parts
│   ├── resourcequota.yaml       <- a cap on total CPU/memory this release may use
│   ├── limitrange.yaml          <- default CPU/memory if a container doesn't set one
│   ├── migration-job.yaml       <- one-time task: prepare the database
│   ├── backup-cronjob.yaml      <- repeating task: back up the database
│   ├── tests/test-connection.yaml <- a check Helm can run after install
│   └── NOTES.txt                <- message printed after install/upgrade
│
└── charts/                   <- the three "subcharts" (one folder per app part)
    ├── frontend/                <- the web page (nginx)
    │   ├── Chart.yaml
    │   ├── values.yaml            <- settings just for frontend
    │   └── templates/
    │       ├── deployment.yaml     <- runs the frontend containers
    │       ├── service.yaml        <- gives frontend a stable network address
    │       ├── hpa.yaml            <- auto-scales frontend up/down
    │       ├── pdb.yaml            <- keeps at least 1 frontend Pod alive during maintenance
    │       ├── serviceaccount.yaml <- frontend's identity inside the cluster
    │       ├── configmap.yaml      <- the actual HTML page shown to the user
    │       └── _helpers.tpl        <- small reusable snippets used by the templates above
    │
    ├── backend/                 <- the API
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── deployment.yaml     <- runs the backend containers
    │       ├── service.yaml        <- stable network address for backend
    │       ├── hpa.yaml            <- auto-scales backend up/down
    │       ├── pdb.yaml            <- keeps at least 1 backend Pod alive
    │       ├── serviceaccount.yaml <- backend's identity
    │       ├── role.yaml           <- permissions: what backend is allowed to read
    │       ├── configmap.yaml      <- non-secret settings (e.g. database host name)
    │       ├── secret.yaml         <- a private API token
    │       └── _helpers.tpl
    │
    └── database/                <- postgres
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── statefulset.yaml    <- runs postgres + gives it its own storage
            ├── service.yaml        <- stable network address for the database
            ├── configmap.yaml      <- SQL that runs once, the first time postgres starts
            ├── secret.yaml         <- the database password
            └── _helpers.tpl
```

**Rule of thumb:** anything about *one* app part (frontend, backend, or
database) lives in that part's own folder under `charts/`. Anything that
connects the parts together, or applies to the whole release, lives in
the top-level `templates/` folder.

---

## 4. Kubernetes object kinds used here, explained simply

Every YAML file under `templates/` describes one or more "kinds" of
Kubernetes object. Here is what each kind does, in plain words.

- **Deployment** — "Keep N copies of this container running, and replace
  them if they crash." Used for frontend and backend, since they don't
  need to remember anything between restarts.

- **StatefulSet** — Like a Deployment, but each copy gets its own
  identity and its own storage that survives restarts. Used for the
  database, because losing your data on every restart would be bad.

- **Service** — A stable network name/address that always points at the
  right Pods, even as Pods are replaced. Think of it as a phone number
  that never changes, even if the person answering changes.
  - A normal Service (`ClusterIP`) load-balances between Pods.
  - A **headless** Service (used for the database) instead gives you the
    exact address of one specific Pod — useful when identity matters.

- **Ingress** — The "front door." It looks at the web address you asked
  for (e.g. `fullstack.local/api`) and forwards you to the right Service
  (backend for `/api`, frontend for everything else).

- **ConfigMap** — A place to store plain, non-secret settings or files
  (like an HTML page, or a database hostname), separate from the
  container image, so you can change them without rebuilding anything.

- **Secret** — Same idea as ConfigMap, but for sensitive values
  (passwords, tokens). Stored base64-encoded (not encrypted by default,
  but kept separate from ConfigMaps so it's handled more carefully).

- **ServiceAccount** — An identity that a Pod uses when it talks to the
  Kubernetes API itself (not your app's normal network traffic — this is
  about permissions inside the cluster).

- **Role + RoleBinding** — Together these say "this ServiceAccount is
  allowed to do X, Y, Z, and nothing else." Here, the backend's
  ServiceAccount is allowed to *read* ConfigMaps/Secrets, but cannot
  touch Pods or anything outside its own namespace. This is called
  least-privilege: only grant the access that's actually needed.

- **HorizontalPodAutoscaler (HPA)** — Watches CPU usage and automatically
  adds or removes Pod copies to keep up with load.

- **PodDisruptionBudget (PDB)** — Tells Kubernetes "never take down more
  than this many copies at once during voluntary maintenance" (like
  draining a node), so the app stays available.

- **NetworkPolicy** — A firewall rule for Pods. Here: frontend can be
  reached by anyone, backend can only be reached by frontend, and the
  database can only be reached by backend. Everything else is blocked.

- **ResourceQuota** — A cap on the *total* CPU/memory/Pod-count this
  whole release may use in its namespace, so it can't accidentally use
  up the whole machine.

- **LimitRange** — A default CPU/memory setting applied automatically if
  a container doesn't specify its own (a safety net; all containers here
  do set their own, so this mostly demonstrates the feature).

- **Job** — A task that runs once until it finishes, then stops. Used
  here for the database migration (creating a table, seeding one row).

- **CronJob** — A Job that repeats on a schedule (like a cron tab entry
  on Linux). Used here for a nightly database backup.

- **Pod (as a Helm test)** — A one-off Pod that Helm can run *after*
  install, purely to check things are working (`helm test`).

- **PersistentVolumeClaim (PVC)** — A request for real disk storage.
  You won't find this as its own file — it's generated automatically by
  the database's `volumeClaimTemplates` inside `statefulset.yaml`, one
  per StatefulSet Pod.

---

## 5. How `values.yaml` connects everything

Helm has one convenient rule: if the top of the umbrella chart's
`values.yaml` has a key matching a subchart's name, everything under that
key is passed down to that subchart automatically.

```yaml
# full-stack-app/values.yaml
frontend:            # <- matches charts/frontend/, so this section
  replicaCount: 2     #    overrides charts/frontend/values.yaml
backend:              # <- matches charts/backend/
  replicaCount: 2
database:              # <- matches charts/database/
  persistence:
    enabled: true
```

So there are two layers of settings for, say, the frontend:
1. `charts/frontend/values.yaml` — the frontend's own defaults.
2. `full-stack-app/values.yaml`, under the `frontend:` key — overrides
   used when installed as part of the whole app.

You only need to edit the top-level `full-stack-app/values.yaml` for
normal use. The subchart `values.yaml` files are there so each part could
also be installed completely on its own, if you ever wanted that.

---

## 6. Step-by-step: install and test this on your computer

You already have `minikube`, `docker`, `kubectl`, and `helm` installed.
Minikube creates a small one-computer Kubernetes cluster on your laptop,
just for testing.

### Step 1 — Start a cluster just for this chart

```bash
minikube start -p fullstack --cpus=2 --memory=3g
```
`-p fullstack` names this cluster "fullstack" so it never mixes with any
other cluster/profile you may already have.

### Step 2 — Turn on two optional cluster features

```bash
minikube -p fullstack addons enable ingress          # needed for the Ingress
minikube -p fullstack addons enable metrics-server    # needed for the HPA
```

### Step 3 — Check the chart for mistakes (does not touch the cluster)

```bash
cd full-stack-app
helm lint .                                # checks syntax
helm template demo . -n fullstack          # shows the generated YAML
```

### Step 4 — Install it

```bash
helm install demo . --namespace fullstack --create-namespace --wait --timeout 5m
```
- `demo` — the release name you're choosing (you can pick any name).
- `.` — install from the chart in the current folder.
- `--create-namespace` — creates the `fullstack` namespace if missing.
- `--wait` — don't return control until Pods report "ready."

### Step 5 — Look at what was created

```bash
kubectl get all -n fullstack
```
You should see Pods (`Running`), Deployments/StatefulSets (all "ready"),
Services, and more.

### Step 6 — Run the built-in test

```bash
helm test demo -n fullstack
```
This starts a small Pod that tries to reach the frontend and backend, and
tells you if it worked.

### Step 7 — Open the app in your browser

Easiest way (no extra setup):
```bash
kubectl port-forward -n fullstack svc/demo-frontend 8080:80
```
Now open `http://localhost:8080` in your browser. Leave this command
running; press Ctrl+C to stop it when done.

### Step 8 — Change something and upgrade

Edit `values.yaml` (e.g. change `replicaCount`), then:
```bash
helm upgrade demo . -n fullstack --wait
```
This applies your change without deleting the release. It creates a new
revision.

### Step 9 — Undo a change, if needed

```bash
helm history demo -n fullstack       # list all revisions
helm rollback demo 1 -n fullstack    # go back to revision 1
```

### Step 10 — Clean up when finished

```bash
helm uninstall demo -n fullstack     # removes everything this chart created
minikube delete -p fullstack          # removes the whole test cluster
```

---

## 7. If something goes wrong

```bash
kubectl get pods -n fullstack                  # is anything crashing?
kubectl describe pod <pod-name> -n fullstack   # why is it not starting?
kubectl logs <pod-name> -n fullstack           # what did the app print?
helm get values demo -n fullstack               # what settings were actually used?
helm get manifest demo -n fullstack             # what YAML was actually sent to Kubernetes?
```

Read the pod's **Events** section at the bottom of `kubectl describe pod`
output first — it almost always says exactly what's wrong, in plain
English (e.g. "Insufficient cpu", "ImagePullBackOff", "readiness probe
failed").

---

## 8. Where to read more

The `README.md` in this same folder has a full table of every manifest
kind used, plus commands to specifically test autoscaling, the
PodDisruptionBudget, NetworkPolicy, RBAC, the migration Job, and the
backup CronJob one at a time. Read this file first, then use `README.md`
as your hands-on reference.
