# HackCTF: el binario `ovnkube` (nombre, ubicación, build, runtime)

Referencia de dónde vive el binario que contiene los fixes de gateway/enslavement
del cluster Combate, cómo se compila y dónde corre.

## Qué es

`ovnkube` es **un único binario Go** que implementa TODOS los subcomandos de
OVN-Kubernetes (`ovn-node`, `ovn-cluster-manager`/master, etc.). El subcomando lo
elige el entrypoint según el argumento (`ovnkube.sh ovn-node`, etc.).

- Compilado con `CGO_ENABLED=0` (estático) y `-ldflags="-s -w"` (sin símbolos).
- Tamaño: ~78 MB (`78221496` bytes en el build v24).
- El código del **enslavement/gateway (los fixes)** corre en la ruta
  `ovnkube ovn-node`, o sea dentro del contenedor `ovnkube-node`.

## Código fuente

| Qué | Ruta |
|-----|------|
| Paquete `main` | `go-controller/cmd/ovnkube/ovnkube.go` |
| **Fixes de gateway/enslavement** | `go-controller/pkg/node/gateway_init.go` |
| Guardas nil de disabled mode | `go-controller/pkg/node/default_node_network_controller.go`, `openflow_manager.go` |

- Fork: `github.com/HackCTF/ovn-kubernetes`, rama **`release-1.1`**.
- Commits de los fixes de gateway (en orden):
  - `bacdbdc` — respeta `OVN_GATEWAY_MODE` vacío (disabled) + `cleanupStaleGatewayBridges` + guardas nil.
  - `c1d051860` — fuente pinneada a disabled + cleanup robusto (reintentos, force del-br seguro).
  - `e62e2858e` — cleanup ANTES de `getGatewayNextHops()`.
  - `bec4528c1` — `getGatewayNextHops()` no-fatal en disabled (no crash por falta de ruta).

## Cómo se compila

`Dockerfile.hackctf.minimal` (multi-stage). El binario `ovnkube` es uno de varios
que se compilan:

```dockerfile
# Stage 1 (builder):
RUN ... go build -mod=vendor -ldflags="-s -w" -o /ovnkube          ./cmd/ovnkube/
RUN ... go build -mod=vendor -ldflags="-s -w" -o /ovn-kube-util    ./cmd/ovn-kube-util/
RUN ... go build -mod=vendor -ldflags="-s -w" -o /ovnkube-identity ./cmd/ovnkube-identity/
RUN ... go build -mod=vendor -ldflags="-s -w" -o /ovndbchecker     ./cmd/ovndbchecker/

# Stage final:
COPY --from=builder /ovnkube /usr/bin/ovnkube          # <-- destino runtime
COPY dist/images/ovnkube.sh /root/ovnkube.sh           # entrypoint
# parches al entrypoint (mismo Dockerfile):
RUN sed -i 's|ovn_gateway_mode=${OVN_GATEWAY_MODE:-"shared"}|ovn_gateway_mode=${OVN_GATEWAY_MODE}|' /root/ovnkube.sh
# + patch external_ids:ovn-remote antes de ovn-controller
ENTRYPOINT ["/root/ovnkube.sh"]
```

Build (Docker o WSL2, NO cross-compile en Windows):
```bash
cd D:\HackCTF\ovn-kubernetes
docker build -f Dockerfile.hackctf.minimal \
  -t harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-v24 .
docker push --provenance=false harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-v24
```
Type-check del binario sin buildear la imagen entera:
```bash
docker run --rm -e CGO_ENABLED=0 -e GOFLAGS=-mod=vendor \
  -v D:/HackCTF/ovn-kubernetes/go-controller:/src -w /src golang:1.25 \
  sh -c 'go build -o /tmp/ovnkube ./cmd/ovnkube/ && echo OK'
```

## Dónde está en runtime

| Aspecto | Valor |
|---------|-------|
| Ruta en el contenedor | **`/usr/bin/ovnkube`** |
| Entrypoint | `/root/ovnkube.sh` (parcheado) |
| Imagen | `harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-v24` |
| Digest v24 | `sha256:7d4b17b3806369bea82590d4960ba4c2997c65a6d4b2d0fa1bdb661c64c7b7b6` |

Corre en dos workloads del namespace **`ovn-kubernetes`**:

| Workload | Contenedor | Comando | Contiene el fix |
|----------|-----------|---------|-----------------|
| DaemonSet `ovnkube-node` | `ovnkube-node` | `ovnkube ovn-node` | **SÍ** (gateway init / cleanup) |
| DaemonSet `ovnkube-node` | `ovn-controller` | wrapper OVS | usa misma imagen |
| DaemonSet `ovnkube-node` | `ovs-metrics-exporter` | métricas | usa misma imagen |
| Deployment `ovnkube-master` | `ovnkube-master` | cluster-manager | mismo binario |

> El fix del enslavement/crash vive en el contenedor **`ovnkube-node`** (el que
> corre `ovnkube ovn-node`), presente en cada nodo vía el DaemonSet.

## Estado desplegado (cluster Combate, 2026-07-20)

| Nodo | IP | Imagen ovnkube-node |
|------|-----|--------------------|
| thirsty-kapitsa (master) | 192.168.56.140 | `hackctf-v24` |
| nervous-vaughan (worker) | 192.168.56.142 | `hackctf-v24` |
| funny-einstein (worker) | 192.168.56.141 | **MUERTO (NotReady)** |

`OVN_GATEWAY_MODE=""` (disabled) en el DS. Validado por reboot de nervous-vaughan:
levanta en disabled, sin breth stale (emptyDir), cleanup `confirmed over 2 passes`,
sin crash.

## Desplegar una imagen nueva

OVN-K en Combate **NO está gestionado por helm** (manifests + kubectl). El rollout
del DaemonSet **deadlockea** con un nodo muerto (funny-einstein NotReady cuenta
como `maxUnavailable=1`), así que hay que rolar los pods a mano:

```bash
kubectl -n ovn-kubernetes set image ds/ovnkube-node \
  ovnkube-node=harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-vXX \
  ovn-controller=harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-vXX \
  ovs-metrics-exporter=harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-vXX
kubectl -n ovn-kubernetes set image deploy/ovnkube-master \
  ovnkube-master=harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-vXX

# rolar a mano (worker primero para validar, luego master):
kubectl -n ovn-kubernetes delete pod <ovnkube-node-pod-del-worker>
# ...validar READY + log del cleanup...
kubectl -n ovn-kubernetes delete pod <ovnkube-node-pod-del-master>
```

> **Nota:** el pull de una imagen nueva en `nervous-vaughan` es LENTÍSIMO
> (~12min para 515MB) por el sustrato e1000/host-only. El master cachea la imagen
> vía el rollout automático del Deployment `ovnkube-master`, así que su pod
> `ovnkube-node` arranca rápido tras el cache.

## Verificación rápida en un contenedor corriendo

```bash
# ID del contenedor ovnkube-node en un nodo:
crictl ps --name ovnkube-node -q
# binario + imagen:
crictl exec <cid> ls -la /usr/bin/ovnkube
crictl inspect --output go-template --template '{{.status.image.image}}' <cid>
# log del cleanup (confirma que corre el código del fix):
kubectl -n ovn-kubernetes logs <pod> -c ovnkube-node | grep "HackCTF fix"
```

Ver también: `HACKCTF_GATEWAY_MODE_DISABLED_FIX.md` (detalle de los fixes).
