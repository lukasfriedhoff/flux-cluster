# Runbook: quiescing / scaling a Flux-managed workload

**Why this exists:** during the media→NAS volume migration (2026-09-18) the stack was
"stopped" with `flux suspend kustomization media-app` + `kubectl scale deploy --all
--replicas=0`. Minutes later `qbittorrent` was running again — the **helm-controller**
had reconciled its HelmRelease and reverted the scale. Suspending the *Kustomization*
does **not** pause an app that a *HelmRelease* deploys. This runbook is the correct way.

## Mental model — who reverts your `kubectl` command

```
GitRepository (source-controller)
  └─ Kustomization (kustomize-controller)   ← applies the HelmRelease CR + raw manifests
       └─ HelmRelease (helm-controller)       ← renders chart, owns Deployment/CronJob/Job
            └─ Deployment / CronJob / Job      ← what you scale/patch with kubectl
```

The controller that **owns** an object reconciles it back to its declared spec on its
`interval`. In this cluster the media apps are **one HelmRelease per app** (`app-template`),
so the helm-controller owns their Deployments and CronJobs. Any `kubectl scale`,
`kubectl edit`, or `kubectl patch cronjob … suspend=true` on them is **drift** and is
undone within minutes. Suspending only the `media-app` Kustomization is insufficient —
it just stops re-applying the HelmRelease CRs; the HRs themselves keep reconciling.

## Quiesce a whole HelmRelease-based stack (e.g. media)

```bash
NS=media
# 1. Suspend every per-app HelmRelease (this is the layer that reverts you)
for hr in $(kubectl -n $NS get helmrelease -o name | sed 's,.*/,,'); do
  flux -n $NS suspend helmrelease "$hr"
done

# 2. NOW scale to 0 and suspend cronjobs — these finally stick
kubectl -n $NS scale deploy --all --replicas=0
kubectl -n $NS scale statefulset --all --replicas=0 2>/dev/null || true
for cj in $(kubectl -n $NS get cronjob -o name); do
  kubectl -n $NS patch "$cj" -p '{"spec":{"suspend":true}}'
done

# 3. Kill any Job pods the HRs already spawned (won't be recreated while HR suspended)
#    (skip your own maintenance Jobs)
```

Confirm nothing comes back after a few minutes:
`kubectl -n $NS get pods` should stay empty of app pods.

## Resume (bring the stack back on its declared/updated state)

```bash
NS=media
for hr in $(kubectl -n $NS get helmrelease -o name | sed 's,.*/,,'); do
  flux -n $NS resume helmrelease "$hr"
done
flux -n flux-system resume kustomization media-app     # if it was suspended too
flux -n flux-system reconcile kustomization media-app --with-source
```

`resume` reconciles to the **git-declared** state — restores replicas, re-enables
CronJobs. If you committed a change (e.g. a volume `existingClaim` flip), resume applies
that git value. It does **not** honor any imperative replica count you set by hand.

## Rules of thumb

- Before any `kubectl scale/edit/patch` on a cluster app, ask **"what Flux resource owns
  this?"** (`flux get helmreleases -A`, `flux tree kustomization <name> -n flux-system`)
  and suspend **that** first — otherwise the change is a no-op on a timer.
- Suspending a **Kustomization** only pauses apps that the Kustomization applies
  *directly* as raw manifests (no HelmRelease in between).
- For anything lasting, prefer the GitOps-native path: change desired state in git
  (`spec.suspend: true`, replicas, values) and let Flux apply it. Imperative `kubectl`
  is only for a short window *after* the owning controller is suspended.
- A CronJob that keeps un-suspending itself = its HelmRelease is still active.
