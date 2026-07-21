# HackCTF: gateway mode disabled fijo + cleanup de bridges stale robusto

## Contexto

En el cluster Combate (VirtualBox, red host-only, NIC e1000, Hyper-V en el host)
OVN-Kubernetes se corre en **GatewayModeDisabled**. Motivo: en `shared`/`local`
OVN-K ejecuta `util.NicToBridge()` sobre la interfaz de gateway → crea `breth0`/
`breth1` y **esclaviza el uplink físico (`eth0`/`eth1`)**. En este sustrato esa
interfaz es también el único camino de management (SSH/kubectl/API), así que el
enslavement deja la IP del nodo atrapada detrás de OVS → loop → drop → nodo
inalcanzable. Los labs usan **OVN secondary networks (layer2, Geneve)**, que
**no dependen** del bridge de gateway; por eso disabled no les quita nada.

`OVN_GATEWAY_MODE=""` (disabled) NO es un modo de primera clase upstream: el
entrypoint `ovnkube.sh` reescribe vacío→`"shared"` (ya parcheado con `sed` en
`Dockerfile.hackctf*`), y el binario paniquea sin gateway bridge (guardas nil
ya agregadas en `default_node_network_controller.go` / `openflow_manager.go` /
`gateway_init.go`). Ver commit `bacdbdc` (fix gateway-mode).

## Incidente 2026-07-20

El DS `ovnkube-node` amaneció con **`OVN_GATEWAY_MODE=local`** (seteado por un
`kubectl set env` el 2026-07-17 durante el deploy de Kumi 2.15.0; visible en
`managedFields`, manager `kubectl-set`). Desde entonces enslavaba `eth1`,
flapeaba (5 restarts en el master) y terminó dejando master y `nervous-vaughan`
inalcanzables. Root cause: **config del DS**, no la imagen (`hackctf-v21` es
correcta). Resolución en vivo: revertir el env a `""` + `ovs-vsctl del-br
breth0/breth1` a mano (el cleanup automático no completó — ver abajo).

## Cambios en este fork

### (a) Fuente pinneada a disabled

- `dist/templates/ovnkube-node.yaml.j2`: `OVN_GATEWAY_MODE` **pinneado a `""`**
  (ya no se templetea desde `ovn_gateway_mode`), con comentario del porqué.
- `helm/ovn-kubernetes/charts/ovnkube-node/templates/ovnkube-node.yaml`: el
  default cambió de `"shared"` a `""` (`default "" .Values.global.gatewayMode
  | quote`). Elimina el landmine de que un `helm install` sin `gatewayMode`
  arranque en shared y enslave la NIC.

Re-renderizar/re-aplicar la fuente ahora restaura disabled. Para correr un
gateway norte-sur real hay que **agregar una NIC dedicada** (no la de
management) y revertir estos pins.

### (b) `cleanupStaleGatewayBridges` robusto (`go-controller/pkg/node/gateway_init.go`)

El cleanup original corría **una sola vez**, ~2s tras el arranque, y con un
guard estricto (`bridge-uplink == ""` → skip). En una transición **en vivo**
local→disabled eso dejaba los `breth*` sin borrar (IP movida a la NIC pero la
NIC seguía como puerto OVS → nodo inalcanzable), requiriendo `del-br` manual.
Log observado: `HackCTF fix: no stale gateway bridges required cleanup` aun con
`breth0/breth1` presentes.

Nueva implementación:

1. **Reintentos en ventana** (hasta 45s, cada 3s) y éxito sólo tras **dos
   pasadas limpias consecutivas** → vence el race donde el bridge stale aún no
   es enumerable en el instante del arranque.
2. **Detecta todo `breth*`** (el prefijo ya es el filtro seguro; `br-int`,
   `br-lab-trunk` y cualquier otro bridge nunca se tocan). Se eliminó el guard
   `bridge-uplink == ""` que dejaba escapar bridges medio-creados.
3. **Force `del-br` como fallback** si `BridgeToNic` falla pero el bridge sigue,
   **sólo cuando es seguro**: la NIC uplink ya tiene una IP global (la IP del
   nodo ya se movió) o el bridge no tiene IP global que perder. Nunca deja al
   nodo sin IP.

Funciones nuevas: `removeStaleGatewayBridgesOnce`, `removeOneStaleGatewayBridge`,
`ovsBridgeExists`, `interfaceHasGlobalIP`.

**(b.2) Cleanup ANTES de `getGatewayNextHops()`** (descubierto validando en vivo,
2026-07-20): el cleanup estaba en el `case GatewayModeDisabled`, que corre
DESPUÉS de `getGatewayNextHops()` (gateway_init.go:240). Si un breth stale
enslavó el uplink y **rompió la default route** (p.ej. una transición a local
que crasheó a mitad), `getGatewayNextHops()` falla con `unable to find default
gateway` y el node controller crashea **antes** de llegar al cleanup → loop. Fix:
`cleanupStaleGatewayBridges()` ahora corre al inicio de `initGatewayPreStart`,
antes de `getGatewayNextHops()`, cuando el modo es disabled. Así limpia el breth
(restaurando IP/ruta al uplink) y recién ahí detecta el next-hop.

Nota: en **reboot** el cleanup manual no hace falta porque `ovs-node` usa
`emptyDir` en `/etc/origin/openvswitch` (db OVS fresca, sin `breth*` stale). El
fix (b) cubre además la transición **en vivo**.

## Evidencia de validación en vivo (2026-07-20, cluster Combate)

Con `hackctf-v22` desplegado (DS `ovnkube-node` + Deployment `ovnkube-master`):
- Master y worker corren el código nuevo: log `HackCTF fix: no stale gateway
  bridges present (confirmed over 2 passes)`.
- **Auto-remoción probada end-to-end** en nervous-vaughan: se creó un breth0
  stale (uplink dummy + IP global), se roló el pod en disabled, y v22 lo borró
  solo:
  ```
  gateway_init.go:713] HackCTF fix: removing stale gateway bridge "breth0" (uplink="breth0up")
  nicstobridge.go:355] Successfully deleted OVS bridge "breth0"
  gateway_init.go:665] HackCTF fix: stale gateway bridge scan pass 1: removed=1 still-present=0
  ```
  Post: `list-br` sin breth0, pod `Running true,true,true`, sin `del-br` manual.
- El fix (b.2) sale en la próxima imagen (`hackctf-v23`); v22 ya cubre el caso
  del incidente real (local mode con breth + ruta funcionando).

## Build y deploy

```bash
# Build (Docker/WSL2 — no cross-compile en Windows):
docker build -f Dockerfile.hackctf.minimal \
  -t harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-v22 .
docker push harbor.k8s.local/library/ovn-kube-ubuntu:hackctf-v22

# Deploy: actualizar DaemonSet ovnkube-node Y Deployment ovnkube-master a v22
# (ambos usan la misma imagen). Verificar OVN_GATEWAY_MODE="" en el DS vivo.
```

> El deploy (rebuild + push + roll) es un paso aparte, no incluido en este commit.
> El cluster vivo ya está en disabled con los bridges limpios (fix aplicado a mano
> el 2026-07-20); (b) hace que la próxima transición en vivo sea automática.

## Validación

- `CGO_ENABLED=0 go build ./cmd/ovnkube/` en contenedor `golang:1.25` → OK.
- `gofmt` limpio.
