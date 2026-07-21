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

## Modos de `OVN_GATEWAY_MODE`

Flag estándar de OVN-Kubernetes `--gateway-mode` (env `OVN_GATEWAY_MODE`).

### Qué es el "gateway" y qué NO depende de él

El gateway maneja el tráfico **norte-sur de la red default (`eth0` del pod)**:
egress de pods hacia afuera del cluster e ingress de servicios expuestos
(NodePort / ExternalIP / LoadBalancer). Se materializa como un **OVN gateway
router (GR)** conectado a un **bridge externo `breth<uplink>`**.

OVN construye ese bridge con `util.NicToBridge()`
(`go-controller/pkg/util/nicstobridge.go`):
1. crea `breth<uplink>` (`add-br`),
2. **agrega la NIC física como puerto del bridge** (`add-port breth eth1`) — el enslave,
3. **mueve la IP del nodo y sus rutas** de la NIC a la interfaz interna `breth`,
4. crea un patch `breth ↔ br-int`.

**No pasan por el gateway** (funcionan sin él): tráfico este-oeste pod↔pod,
ClusterIP, y las **secondary networks** de los labs (OVN layer2 / Geneve). Esos
van por `br-int` / los túneles Geneve directamente.

### Por qué OVN-K necesita un gateway (y por qué el default es `shared`)

OVN-Kubernetes construye una **red overlay** (Geneve): las IPs de pod
(`10.244.x.x`) son internas al overlay y **la red física no sabe rutearlas**. Todo
lo que cruza el borde entre el overlay OVN y la red física/host necesita un punto
de traducción/routing — ése es el **gateway** (GR + `breth`). Existe para dos cosas:

- **Egress de pods al exterior**: la IP origen del pod no es ruteable fuera del
  cluster → hay que hacer **SNAT** a la IP del nodo y sacar el tráfico por la NIC
  física.
- **Ingress de servicios expuestos** (NodePort / ExternalIP / LoadBalancer): el
  cliente externo llega a `IP-del-nodo:puerto`; ese tráfico entra por la NIC física
  y hay que **DNAT / balancearlo** hacia un pod del overlay. El gateway es el punto
  donde OVN programa esos load balancers de servicio.

Lo que **NO** necesita gateway es el este-oeste: **ClusterIP** se implementa como
load balancer en los logical switches/router **dentro del overlay** (por eso anda
en disabled), y pod↔pod va por `br-int`/Geneve.

Por eso el **default upstream es `shared`**: un cluster Kubernetes "normal" da por
sentado que necesita norte-sur (services externos, egress con SNAT), y `shared` es
el camino más simple y performante — OVN dueña de todo el datapath, sin hairpin por
el host. `local` existe para meter el kernel del host en el camino (aplicar
routing/políticas host-level al egress). **Ninguno de los dos contempla "sin
gateway"**: por eso `disabled` no es de primera clase upstream (lo coercionan a
`shared`; ver más abajo).

> En Combate `disabled` es viable porque el norte-sur que realmente se usa —el
> ingress a las consolas de los labs— lo resuelve **MetalLB (L2) + Traefik**, no el
> gateway OVN; y los labs viven en secondary networks L2 aisladas (Geneve), no en la
> red default. El egress de pod igual funciona (lo resuelve el stack del nodo), pero
> el **ingress tipo NodePort/LB por OVN no** — de ahí MetalLB.

### Los tres valores (fuente: `config.go:444-448`, `1417-1419`, `1924-1935`)

| Valor (`GatewayMode`) | Datapath de egress de la red default | ¿`NicToBridge()` → `breth` + enslave uplink? |
|---|---|---|
| `"shared"` | pod → `br-int` → GR → `breth` → uplink físico. **OVN rutea y hace SNAT en su propio datapath**; host y OVN comparten `breth`. Es el default upstream. | **SÍ** |
| `"local"` | Igual que shared para armar `breth`, **pero además** corre `initLocalGateway()` (`gateway_localnet.go:18`): el egress se deriva al **kernel del host** vía la management port `ovn-k8s-mp0` con **masquerade iptables/nftables**, y sale por la **tabla de rutas del host**. Permite aplicar routing/políticas host-level al tráfico de pods. | **SÍ** |
| `""` (vacío = `GatewayModeDisabled`) | No se crea GR ni `breth`. No hay gateway OVN para la red default. La IP del nodo queda en la NIC física (`eth1`). | **NO** |

El branch está en `newGateway()` (`gateway_shared_intf.go:1432`): `local` llama
`initLocalGateway()` antes del `gatewayInitInternal()` común; `shared` sólo el común;
`disabled` no construye ninguno (arma un `gateway` stub sin bridge ni openflowManager).

### Diagramas: datapath por modo

Leyenda: `br-int` = OVS integration bridge (overlay) · `breth1` = gateway/ext
bridge · `GR` = OVN gateway router (SNAT/DNAT, lógico) · `mp0` = `ovn-k8s-mp0`
(management port host↔overlay) · `eth1` = uplink físico del nodo.

**`shared`** — OVN dueña del norte-sur (default upstream):

```
  ┌──────────────────────────── nodo ────────────────────────────┐
  │  pod ──veth──▶ br-int ══patch══▶ breth1 ──▶ eth1 ────────────────▶ red física / internet
  │ 10.244.x      (overlay)      (GR: SNAT)   (uplink            │     egress: SNAT a IP nodo
  │                  │            IP nodo      enslavado)         │
  │                  │            vive acá)                       │
  │               Geneve ─────────────────────────────────────────────▶ otros nodos (E-W)
  └───────────────────────────────────────────────────────────────┘
  ingress:  red física ─▶ eth1 ─▶ breth1 (GR: DNAT/LB de Service) ─▶ br-int ─▶ pod
```

**`local`** — el egress hace hairpin por el kernel del host:

```
  ┌──────────────────────────── nodo ────────────────────────────┐
  │  pod ──veth──▶ br-int ──▶ mp0 ──▶ [ KERNEL DEL HOST ]         │
  │ 10.244.x      (overlay)  (ovn-    iptables/nft masquerade     │
  │                          k8s-mp0) + tabla de rutas del host   │
  │                                          │                    │
  │                                          ▼                    │
  │                                        eth1 ────────────────────▶ red física / internet
  │  (breth1 se crea igual; el uplink eth1 sigue enslavado)       │
  └───────────────────────────────────────────────────────────────┘
```

**`disabled`** (`""`) — sin gateway; lo que corre en Combate:

```
  ┌──────────────────────────── nodo ────────────────────────────┐
  │  pod ──veth──▶ br-int ──Geneve──────────────────────────────────▶ otros nodos (E-W, labs L2)
  │ 10.244.x      (overlay)                                       │
  │                  └─ ClusterIP (LB en el logical switch) ✅    │
  │                                                               │
  │  eth1 ── IP nodo 192.168.56.140 ── management / API / SSH     │   NIC física PLANA:
  │                                                               │   sin breth, sin enslave
  └───────────────────────────────────────────────────────────────┘
  ✗ sin breth/GR  →  NodePort/ExternalIP/LB por OVN NO disponibles
  ingress externo:  red física ─▶ MetalLB (L2) ─▶ Traefik ─▶ Service ─▶ pod
```

**Por qué `shared`/`local` rompen en VirtualBox host-only** (el incidente): `eth1`
es a la vez el uplink enslavado (puerto de `breth1`) y el único camino de
management.

```
  Estado SANO   (IP .140 en breth1):
     worker ─▶ eth1 ─▶ [OVS] ─▶ LOCAL(breth1)=IP .140 ─▶ host   ✅

  Estado ROTO   (IP .140 quedó en eth1, la esclava):
     worker ─▶ eth1 (puerto de OVS) ─▶ [OVS] ─▶ intenta reenviar a eth1 ─▶ LOOP ─▶ DROP
     (el kernel routea las replies por eth1; conntrack ct(zone=64000) las descarta
      antes de llegar a LOCAL)  →  nodo / control-plane inalcanzable
```

### Qué gana/pierde disabled en ESTE cluster (verificado en vivo, 2026-07-20)

Por qué `shared`/`local` rompen acá: ambos enslavan el uplink `eth1`, que en el
sustrato **VirtualBox host-only es también el único camino de management/API**. Un
`NicToBridge()` a medias, o el OVS del host recreando `breth` desde su db en el
boot, deja la IP del nodo **atrapada detrás de OVS** → nodo (y en el master, el
control-plane) inalcanzable. Ese es el incidente. Sólo `disabled` evita el enslave.

Qué se **pierde** en disabled: el rol del gateway OVN en **ingress norte-sur**
(NodePort/ExternalIP/LoadBalancer resueltos por el GR) y las features que dependen
del GR (**EgressIP**, **EgressService**).

Qué **sigue funcionando** (medido en el cluster, no asumido):

| Prueba | Comando | Resultado |
|---|---|---|
| Egress pod → internet | `curl 1.1.1.1` desde un pod | `exit=0` (alcanza el exterior) |
| ClusterIP (API server) | `curl https://10.96.0.1:443` desde un pod | `HTTP 403` (el API responde) |
| Pod↔pod / secondary L2 | labs l2-attacks (Geneve) | OK |

El **ingress externo** lo provee **MetalLB (L2) + Traefik**, no el gateway OVN —
por eso disabled es viable para este cluster de labs.

### Gotchas de configuración (por qué `""` no es trivial upstream)

- **Coerción por flag legacy** (`config.go:1910-1917`): aunque `--gateway-mode`
  sea vacío, el flag **deprecado `--init-gateways`** lo fuerza a `shared` (o
  `local` si además está `--gateway-local`).
- **Coerción por entrypoint**: upstream `ovnkube.sh` reescribe vacío→`"shared"`
  (`ovn_gateway_mode=${OVN_GATEWAY_MODE:-"shared"}`). **Parcheado con `sed`** en la
  imagen HackCTF (si no, `OVN_GATEWAY_MODE=""` en el DS no tiene efecto).
- **Restricciones** (`config.go:1952-1958`): en disabled, `gateway-interface` y
  `gateway next-hop` no están permitidos (error de arranque si se setean).
- **Panics del binario en disabled**: upstream asume que siempre hay gateway;
  deref nil de `openflowManager`/`defaultBridge`. Guardas agregadas en `bacdbdc`.

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

**(b.3) `getGatewayNextHops()` no fatal en disabled** (fix de raíz del crash): en
`GatewayModeDisabled` el next-hop NUNCA se usa (no se arma gateway bridge), pero
`getGatewayNextHops()` abortaba con `unable to find default gateway` (gateway_init.go:94)
si el nodo no tenía ruta default — crasheando el node controller. Ahora, en
disabled, ese error **no es fatal**: se deriva `gatewayIntf` de la IP primaria del
nodo (`util.GetNodePrimaryIP` → `getInterfaceByIP`, mismo patrón que el modo DPU)
y se continúa con next-hops vacíos. Resultado: **el nodo nunca revienta por falta
de ruta default en disabled**, tenga o no un breth stale. Defensa en profundidad
con (b.2): (b.2) limpia el breth y restaura la ruta; (b.3) evita el crash aunque
la ruta siga faltando.

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
