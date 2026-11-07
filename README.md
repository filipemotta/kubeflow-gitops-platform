# Kubeflow for platform engineers: from training run to served model, through GitOps

Companion repository of the article. A lab that installs the Kubeflow Community
Distribution 26.10.0 (trimmed to what the lab proves) in a local kind cluster with two
teams, and walks a model from a training pipeline to a served endpoint without anyone
copying a URI by hand:

```
train -> evaluate -> gate -> register in Kubeflow Hub -> pull request in the GitOps repo
      -> platform admin approves and merges -> Argo CD syncs -> KServe serves
      -> rollback = git revert, through another pull request
```

Every control is proved by being refused, next to a positive control: a bad model is
stopped by the gate, a team cannot see or call the other team's runs, registry or model,
the pipeline's Git bot cannot merge or push to `main`, admission accepts only a model that
one of the team's own pipeline runs produced and only Argo CD may write an InferenceService, Argo CD refuses to deploy one team's project into another team's namespace,
and a hand edit in the cluster is reverted.

## What runs, and what was left out

Installed from `kubeflow/manifests` at tag `26.10.0` (commit `7e4c522f`), stage by stage
(`platform/10..60`):

| Piece | Version | Why it is here |
|---|---|---|
| cert-manager, Istio (sidecar mode, `oauth2-proxy` overlay) | 1.21.2, 1.31.3 | mTLS, AuthorizationPolicy per Profile, ingress |
| oauth2-proxy (`m2m-dex-and-kind`) + Dex | 7.15.5, 2.46.1 | login (two static users) and ServiceAccount JWTs |
| Kubeflow roles, Istio resources, Profile controller + KFAM (from the Dashboard component) | 2.0.1 | the two teams (`team-a` = alice, `team-b` = bob) |
| Kubeflow Pipelines, multi-user, definitions in MySQL, artifacts in SeaweedFS | 2.18.0 | the pipeline and its gate |
| Kubeflow Hub (Model Registry), one per team, PostgreSQL | 0.3.18 | versions and their URIs |
| KServe, `Standard` deployment mode (no UI) | 0.21.0 | serving |
| Argo CD (application controller, repo server, Redis) | v3.6.1 | delivery from Git |
| Gitea (SQLite, ephemeral) | 28.3.0 | the GitOps repository, inside the cluster |

Left out of the run, to fit a 5 CPU / ~7.7 GiB Docker VM. Each one is a commented line in
the stage's `kustomization.yaml`, so a bigger machine can turn it back on:

- **Katib**: deprecated in Kubeflow 26.10 in favor of the Trainer's OptimizationJob APIs.
- **Workspaces (Notebooks v2), Trainer + JobSet, Spark Operator**: not on the path from
  pipeline to served model; the lab's model trains inside a pipeline step.
- **Knative Serving (and Eventing)**: the distribution runs KServe in `Knative` mode; the lab
  runs it in `Standard` mode (a Deployment and a Service per model). On this machine Knative
  plus pipelines and serving at the same time pushed the VM into swap, and with Knative the
  activator forwards requests to the model without mTLS, so no Istio policy on the model can
  tell which team is calling (see below).
- **Central Dashboard UI (0 replicas), KServe Models UI, Hub Model Catalog, Argo CD API
  server/UI, Dex and notifications**: user interfaces and optional pieces; the lab talks to
  APIs and manages Argo CD through its CRs. The Profile controller and KFAM keep running.
- **GPU and Karpenter**: `karpenter/gpu-nodepool.yaml` is validated against the Karpenter
  v1.15.1 CRDs with a server-side dry run, not applied.

Other changes to the upstream manifests, all for memory, all listed in the stage files:
one replica of everything, no HorizontalPodAutoscalers, lower CPU/memory requests (limits
kept), MySQL without `performance_schema` and with a 64M buffer pool, Argo CD watching only
InferenceServices (`resource.inclusions`), and `GOMEMLIMIT` on the kind API server.

### Changes the flow needs (and why)

- **Kubeflow Hub per team, without the ingress route.** Upstream routes
  `/api/model_registry/` on the `kubeflow-gateway` to one namespace, so two teams cannot
  both have it. Each team's registry is reached in-cluster, and an extra
  AuthorizationPolicy (`tenants/<team>/hub-team-access.yaml`) admits only the team's own
  namespace.
- **The `register` step joins the mesh.** KFP runs pipeline pods with
  `sidecar.istio.io/inject: "false"`, so they have no workload identity and a
  namespace-based AuthorizationPolicy refuses them. The step that calls the Hub gets
  `sidecar.istio.io/inject: "true"` (`kfp.kubernetes.add_pod_annotation`); Istio runs the
  proxy as a native sidecar, so the pod still completes.
- **No extra policy for the model.** In `Standard` mode the caller's sidecar talks mTLS to
  the model's sidecar, and the AuthorizationPolicy the Profile already creates (only the
  team's namespace, or its owner through the ingress gateway) refuses another team's
  workloads and the team's own pods that run without a sidecar. With Knative in the path that
  does not hold: upstream's KServe test (`tests/kserve_sklearn_test.py` in kubeflow/manifests)
  puts an allow-all policy on the predictor and relies on the gateway's JWT check, which admits
  any authenticated identity from any team.

### Two things that will bite you

- With Kubeflow and Argo CD in the same cluster, `kubectl get application` resolves to
  Kubeflow's `applications.app.k8s.io`, not to Argo CD's Application. Use
  `applications.argoproj.io`.
- In Standard mode an InferenceService turns `Ready` on a new `storageUri` while its
  Deployment is still rolling and the old pod is still answering. `assert_served` in
  `scripts/lib.sh` waits until every predictor pod runs the new URI before it calls the model.

## Requirements

- Docker (tested: Docker Desktop on an Apple M2 Pro, VM with 5 CPUs and 7.7 GiB), about
  15 GiB of free disk, internet access to pull images.
- `curl`, `git`, `jq`, `python3` (3.10+). Everything else (kind v0.33.0, kubectl v1.35.10,
  kustomize v5.8.1, crane v0.22.1, the KFP SDK 2.18.0) is downloaded into `bin/` and `.venv/`
  by `tools/install-cli.sh`, checked against the published SHA-256.
- Optional for `validate.sh`: `shellcheck`, `kubeconform`.

The lab never touches your `~/.kube/config`: it writes its own kubeconfig to `.kube/` and
refuses to run against any context that is not a kind cluster on `127.0.0.1`. It also uses
an empty Docker config (`.cache/docker-anon`), since all images are public.

### On arm64 (Apple Silicon, Graviton)

Two images KFP 2.18 runs are published for `linux/amd64` only: the ML Metadata server
(`ml_metadata_store_server:1.14.0`) and `kfp-metadata-writer:2.18.0`. The first is a
single-platform image and containerd runs it under the Docker VM's emulation. The second
is a multi-platform index without arm64, which containerd refuses ("no match for platform
in manifest"); step 02 pulls its amd64 entry by digest into the node and tags it with the
original name. Step 00 lists every image without your node's platform in
`out/arch-report.txt`.

## Run it

```
bash scripts/test-all.sh
```

It creates the cluster, runs every step, prints one line per step and the number of
assertions, and deletes the cluster at the end, also on failure. On the machine above the
whole run takes 20 to 30 minutes (between 1132 s and 1755 s in the last clean runs, 132 assertions).

The steps, in order (each script can also be run alone, in this order):

| Script | What it proves |
|---|---|
| `00-preflight.sh` | machine, pinned tools, every stage renders, image platforms |
| `01-cluster.sh` | one-node kind cluster, inotify limits, pipeline image loaded |
| `02-platform.sh` | the distribution stage by stage, the two Profiles, one Hub per team |
| `03-gitops.sh` | Argo CD, Gitea with a protected `main`, a bot per team, AppProjects, the admission policy |
| `04-isolation.sh` | no session no API; alice and bob each see only their own runs and registry; a pod without a sidecar is refused too; RBAC across teams |
| `05-gate.sh` | a run on bad data fails at the gate; nothing registered, no branch, no pull request |
| `06-promote.sh v1` / `v2` | run, Hub version on the run's own URI, pull request by the bot, bot cannot merge or push, approval and merge, Argo CD sync, KServe serving that URI |
| `09-rollback.sh` | `git revert` of the v2 merge through a pull request; v1 served again |
| `10-guardrails.sh` | admission accepts only the team's own run artifacts (refuses `latest/`, `:latest`, `current/`, another team's run, a transformer or explainer, custom containers, initContainers, a swapped image or runtime on the model) only Argo CD writes InferenceServices, and no other KServe resource in team namespaces; AppProject refuses cross-team deploys; self-heal reverts a hand edit; another team's workload, or a pod without a sidecar, gets no prediction |
| `11-static.sh` | GPU NodePool and EC2NodeClass accepted by the Karpenter v1.15.1 CRDs (dry run) |
| `99-teardown.sh` | the cluster is gone |

Credentials are lab-only: Dex users `alice@example.com` and `bob@example.com`, Gitea users
`platform-admin`, `team-a-bot`, `team-b-bot`, `oncall` and `argocd-reader`, all with the
password `kubeflow-lab`.

## Layout

```
kind/          cluster config (one node, API server flags of the upstream CI)
platform/      the install stages: 10 cert-manager, 20 Istio, 30 auth, 40 Kubeflow, 50 KServe, 60 GitOps
tenants/       the two Profiles and one Kubeflow Hub per team
policies/      ValidatingAdmissionPolicies: only Argo CD writes InferenceServices; only artifacts of the team's own runs; no other KServe resources in team namespaces
gitops/        AppProject + Application per team
pipeline/      the pipeline (train_and_promote.py, compiled .yaml), its image, the submit helper
probes/        a pod per team used to try calls from inside the mesh, and one without a sidecar
karpenter/     GPU NodePool + EC2NodeClass (validated, not applied)
scripts/       the steps, test-all.sh, teardown
tools/         pinned CLI installer, manifests fetcher, image lister
```

## Clean up

`test-all.sh` deletes the cluster on exit. If you ran steps by hand:

```
bash scripts/99-teardown.sh
```

Downloaded tools and caches stay in `bin/`, `.venv/` and `.cache/` (all gitignored); delete
them to reclaim the space.

## License

MIT, see [LICENSE](LICENSE).
