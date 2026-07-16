# HackCTF — match de static IP por label (`kumi.io/static-ip-key`), no por nombre de pod

> Rama: `release-1.1` (fork HackCTF). Fecha: 2026-07-16.
> Relacionado: plan `Kumi: docs/superpowers/plans/2026-07-15-kumi-ovn-k-migration.md` (Task 6, resuelve R-A).

## Problema

El feature HackCTF de `staticIPs[]` en la NAD (`ovn-k8s-cni-overlay` layer2) bindea la
IP fija de un pod comparando `entry.PodName == pod.Name`. Eso funciona para
contenedores (nombre determinista), pero **no para VMs KubeVirt**: el pod real es el
`virt-launcher-<vmi>-<sufijo-aleatorio>`, así que `pod.Name` nunca coincide con el
`podName` que Kumi pone en la NAD. Además, al consolidar las static IPs por red
(Kumi usa `podName = d-<deviceShort>`), el contenedor es `d-<deviceShort>-0`
(ordinal del StatefulSet) → tampoco casa por nombre.

## Fix (este commit)

Match por un **label que Kumi estampa idéntico en el pod del contenedor y en el VMI**
(`kumi.io/static-ip-key`), con precedencia sobre el nombre. KubeVirt copia los
`vmi.Labels` al pod `virt-launcher` (`template.go` `podLabels()`), así que el label
llega al pod real de la VM. Una sola identidad de match para ambos runtimes, sin
depender del `-0` ni del sufijo aleatorio del virt-launcher.

| Archivo | Cambio |
|---|---|
| `go-controller/pkg/ovn/base_network_controller_pods.go` | Nuevo helper `staticIPMatchKey(pod)` → `(key, via)`. Precedencia: `pod.Labels["kumi.io/static-ip-key"]` → `kubevirt.ExtractVMNameFromPod(pod).Name` (fallback defensivo VM) → `pod.Name`. Los dos sitios de match (`addLogicalPortToNetwork` ~L893 y `allocatePodAnnotationForSecondaryNetwork` ~L988) usan `entry.PodName == matchKey`. Log `DEBUG-HACKCTF` indica la vía (`label`/`vm`/`pod`). |
| `go-controller/pkg/ovn/base_network_controller_pods_hackctf_test.go` | Unit test `TestStaticIPMatchKey` (4 casos: label > vm > pod, label vacío ignorado). |

## Contrato con Kumi

Kumi (`internal/k8s`): NAD `staticIPs[].podName = d-<shortID(device.ID)> = computeName(device.ID)`,
y estampa `kumi.io/static-ip-key = computeName(device.ID)` en:
- el **pod template** del StatefulSet (contenedores);
- los **`metadata.labels` del VMI** (VMs) → copiado al virt-launcher.

## Aplicar

El cambio está en `go-controller` → requiere **rebuild de la imagen OVN-K**
(`ovn-kube-ubuntu:hackctf-v21`) y redeploy del DaemonSet `ovnkube-node` **y** del
Deployment `ovnkube-master`/cluster-manager (la asignación de IP secundaria corre en
cluster-manager — lección de `LAB_l2-attacks-01_VERIFICACION.md` §7.1). Ver Task 9.

## Validación

- Unit: `go test ./pkg/ovn/ -run TestStaticIPMatchKey` → PASS (4/4, en `golang:1.25` Docker).
- Build: `go build ./pkg/ovn/...` → OK.
- End-to-end (pendiente, Task 8): pod contenedor y VM Cirros con `kumi.io/static-ip-key`
  reciben su IP fija; nota MAC (fork deriva MAC del LSP de la IP — verificar propagación al guest).
