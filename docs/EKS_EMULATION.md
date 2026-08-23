# Emulating EKS locally

> Expenses can rack up pretty fast with EKS. Given my home LAN with a couple machines on it, how close can I get to a good EKS emulation, to minimize the distance it would take to get onto real EKS when I have a budget and rationale for that?

---

You can get closer than you might think — the workload API surface (Deployments, Services, RBAC, ConfigMaps, StatefulSets, NetworkPolicies) is byte-for-byte identical to real EKS, since that's just upstream Kubernetes. The gap is entirely in the infrastructure integration layer, and there are good stand-ins for most of it.

**Setup that gets you closest:**

- **kubeadm across 2-3 real machines** rather than kind/minikube. kind's Docker-in-Docker single-host model hides real node networking, drain/cordon, taints/tolerations, and node failure behavior. Actual separate machines on your LAN forces you to deal with real multi-node mechanics, which is most of what's operationally different about EKS vs. a laptop cluster anyway.
- **CNI: Calico or Cilium** — both are also officially supported as alternative CNIs on real EKS (not just the default VPC CNI), so this choice transfers directly rather than being a "fake" stand-in.
- **MetalLB** for `LoadBalancer`-type Services — gives you a real LAN IP pool behind the same Service spec that provisions an NLB on EKS. This is the single best trick for closing the gap, since "my Service silently stays Pending" is the #1 thing that trips people up moving from Compose/bare Docker to K8s.
- **ingress-nginx** for Ingress objects — same YAML shape as what you'd write against the AWS Load Balancer Controller; only the backing implementation differs.
- **local-path-provisioner or an NFS-backed StorageClass** to exercise PVCs/StorageClasses dynamically, even though it won't be EBS/EFS underneath. The point is learning the StorageClass/PVC/PV lifecycle, which is identical.
- **cert-manager** — works identically in both environments, good to practice now.

**What won't transfer, and what to do about it:**

- **IRSA / IAM-for-pods** — no real IAM locally, so you can't fully emulate this. But you can still practice the workload-side pattern (annotating a ServiceAccount with a role ARN, structuring apps to assume the injected credentials) so the concept isn't new when you add real IAM.
- **VPC CNI specifics** (pods getting real VPC IPs) — don't design around pod-IP-equals-network-identity assumptions; treat pod networking as an abstraction either way, and this won't bite you.
- **Cluster Autoscaler / Karpenter** — can't emulate scaling into a cloud you don't have. Worth reading about Karpenter's model even without hands-on time; consider KEDA locally for autoscaling-on-metrics as an adjacent, genuinely runnable skill.
- **Managed add-on upgrades** — EKS handles version skew for you; kubeadm makes you do it by hand, which is extra work now but arguably better training.

When you do move to real EKS, the delta becomes: swap CNI config (or keep Calico/Cilium), swap MetalLB/ingress-nginx for the AWS LB Controller if you want managed ALBs, swap the storage provisioner for the EBS/EFS CSI driver, add IRSA annotations, point at ECR, and use `eksctl` or Terraform instead of kubeadm for cluster creation itself. Everything above the infrastructure layer stays exactly as you wrote it.
