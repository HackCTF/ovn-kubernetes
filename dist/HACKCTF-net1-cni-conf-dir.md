# HackCTF — ovnkube-node escribe su CNI conf en un subdir (fix del race de `net1`)

> Rama: `release-1.1` (fork HackCTF). Fecha: 2026-07-16.
> Doc completa de la investigación: `multus-cni: docs/HACKCTF-net1-attach-race.md`.

## Problema

En los workers, pods creados en lotes concurrentes quedaban `Running` **sin su
interfaz secundaria `net1`** (~13% de los casos), de forma silenciosa. Rompe el
arranque instantáneo de laboratorios (pods con red secundaria de Kumi).

## Causa raíz

**CRI-O saltea Multus.** El directorio `/etc/cni/net.d` de los workers contiene la
CNI conf de OVN-K (`10-ovn-kubernetes.conf`, `type=ovn-k8s-cni-overlay`) **junto** a
`00-multus.conf`. Multus regenera `00-multus.conf` atómicamente; en cada regen CRI-O
recarga y re-elige la default network, y a veces cae a `10-ovn-kubernetes.conf` →
networkea el pod con OVN **directo, sin Multus** → sin redes secundarias → sin `net1`.
Probado con un build instrumentado de Multus: el pod fallido no tiene ninguna línea
de log de Multus; el journal de CRI-O muestra `Adding pod ... to CNI network
"ovn-kubernetes"`.

## Fix (este commit)

Que CRI-O vea **solo** `00-multus.conf`: ovnkube-node escribe su CNI conf en un
**subdir que CRI-O no escanea** (el escaneo de CNI es no-recursivo), y Multus lee el
master de ahí. Sin renombrar confs, sin ventana, sin crashloop.

| Archivo | Cambio |
|---|---|
| `dist/images/ovnkube.sh` | `--cni-conf-dir=/etc/cni/net.d/ovn.d` en `ovnkube --init-node` → `WriteCNIConfig` escribe `10-ovn-kubernetes.conf` en el subdir. |
| `dist/templates/ovnkube-node.yaml.j2` | `readinessProbe` del container `ovnkube-node` → `test -f /etc/cni/net.d/ovn.d/10-ovn-kubernetes.conf`. El probe nativo (`ovn-kube-util readiness-probe -t ovnkube-node`) **hardcodea** `/etc/cni/net.d/10-ovn-kubernetes.conf` (`go-controller/cmd/ovn-kube-util/app/readiness-probe.go:153-160`, comentario: *"we always use /etc/cni/net.d"*), así que al mover el conf hay que apuntar el probe al subdir. |

Cambio complementario en Multus (repo `multus-cni`, rama `hackctf/net1-race-fix`):
`deployments/multus-daemonset.yml` → `--multus-autoconfig-dir=/host/etc/cni/net.d/ovn.d`
(Multus lee el master del subdir).

## Aplicar

El cambio de `ovnkube.sh` está baked en la imagen → requiere **rebuild** de
`ovn-kube-ubuntu` (p.ej. `hackctf-v21`) y redeploy del DaemonSet `ovnkube-node`. El
readinessProbe (j2) toma efecto al re-renderizar/re-aplicar.

**Equivalente sin rebuild (estado actual del cluster):** en cada worker,
`/etc/openvswitch/ovn_k8s.conf` con:
```ini
[cni]
conf-dir=/etc/cni/net.d/ovn.d
```
(`ovnkube` lo lee por default vía `getConfigFilePath` → `/etc/openvswitch/ovn_k8s.conf`;
nota: la `ovn_k8s.conf` de la imagen está shadoweada por el mount hostPath de
`/etc/openvswitch`). El CLI flag de `ovnkube.sh` lo vuelve redundante tras el rebuild.

## Validación

0 fallos / 60 pods (vs ~13%). Robusto: reinicios de multus **y** ovnkube-node
recuperan sin crashloop (a diferencia de `--rename-conf-file`, que crashloopea el pod
multus porque ovnkube-node no mantiene un master estable en la ubicación renombrada).
