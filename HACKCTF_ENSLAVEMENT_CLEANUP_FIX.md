# HackCTF: fix del enslavement / cleanup de gateway bridges (defensa en 4 capas)

Cómo se corre OVN-Kubernetes en `GatewayModeDisabled` de forma **robusta** en el
cluster Combate, de modo que el enslavement del uplink (`eth1`→`breth1`) no vuelva
por **ninguna** de las vías por las que puede volver. Complementa
`HACKCTF_GATEWAY_MODE_DISABLED_FIX.md` (qué es el gateway y sus modos).

## El problema

En `shared`/`local`, OVN-K llama `util.NicToBridge()` sobre el uplink: crea
`breth1`, **enslava `eth1`** y le mueve la IP del nodo. En el sustrato VirtualBox
host-only, `eth1` es **también** el único camino de management/API. Cuando el setup
del bridge queda a medias, la IP del nodo queda atrapada detrás de OVS → **nodo (y
en el master, el control-plane) inalcanzable**. Ese fue el incidente que costó un
worker (`funny-einstein`).

La solución de fondo es correr `disabled` (sin gateway bridge). Pero `disabled` no
es de primera clase upstream y el enslavement puede reaparecer por **cuatro vías
distintas** — cada capa del fix cierra una.

## Las 4 vías por las que el enslavement/crash puede reaparecer

| # | Vía | Qué pasa |
|---|-----|----------|
| **V1** | **Config**: alguien setea `OVN_GATEWAY_MODE=local/shared`, o el entrypoint upstream coerciona vacío→`shared` | El pod arranca en gateway mode → `NicToBridge()` → `breth1` enslava `eth1` |
| **V2** | **Transición en vivo** local→disabled | El cleanup mueve las IPs pero deja los bridges/puertos, o corre demasiado temprano y no ve el breth → `eth1` sigue enslavado |
| **V3** | **Reboot** | El OVS del host recrea `breth1` desde su db persistida **antes** de que arranque `ovnkube-node` → catch-22 (no puede arrancar a limpiar porque la red ya está rota) |
| **V4** | **Crash**: un `breth` stale rompió la default route | `getGatewayNextHops()` aborta con `unable to find default gateway` **antes** de llegar al cleanup → crashloop |

## Las 4 capas (qué vía cierra cada una)

### Capa 0 — Base: hacer que `disabled` exista y sea limpio en reboot
Commits `bacdbdc` (binario+entrypoint), `5de4f76` (emptyDir), `80774e3` (ovn-remote).

- **Entrypoint respeta el modo vacío**: `ovnkube.sh` reescribía
  `ovn_gateway_mode=${OVN_GATEWAY_MODE:-"shared"}` (vacío→shared). Parche `sed` a
  `${OVN_GATEWAY_MODE}`. → **cierra parte de V1** (la coerción del entrypoint).
- **Guardas nil**: upstream deref-ea `openflowManager`/`defaultBridge` (que en
  disabled son nil) y paniquea. Guardas en `default_node_network_controller.go`,
  `openflow_manager.go`, `gateway_init.go`.
- **`emptyDir` para la OVS db** del DaemonSet `ovs-node` (`/etc/origin/openvswitch`):
  la db es efímera → en el boot no hay `breth1` stale que recrear. → **cierra V3**.
- **`ovn-remote` re-set** en `ovnkube.sh` antes de `ovn-controller` (necesario
  porque el emptyDir borra el external_id).

### Capa 1 — Fuente pinneada + cleanup robusto
Commit `c1d051860`.

- **(a) Fuente pinneada a `""`**: `dist/templates/ovnkube-node.yaml.j2` fija
  `OVN_GATEWAY_MODE: ""`; helm chart default `"shared"`→`""`. Un re-apply / `helm
  install` **nunca** deja shared/local por accidente. → **cierra el resto de V1**.
- **(b.1) `cleanupStaleGatewayBridges()` robusto** (`gateway_init.go`):
  - **Reintentos en ventana** (hasta 45s), éxito sólo tras **2 pasadas limpias
    consecutivas** → vence el race donde el breth aún no es enumerable.
  - **Detecta todo `breth*`** por prefijo (se quitó el guard `bridge-uplink==""`
    que dejaba escapar bridges medio-creados). `br-int`/`br-lab-trunk` nunca se tocan.
  - **Force `del-br` de fallback** si `BridgeToNic` falla, **sólo cuando es seguro**
    (la NIC uplink ya tiene IP global, o el bridge no tiene IP que perder) → nunca
    deja al nodo sin IP.
  - → **cierra V2** (la transición en vivo ya no necesita `del-br` manual).

### Capa 2 — Cleanup ANTES de `getGatewayNextHops()`
Commit `e62e2858e`.

`cleanupStaleGatewayBridges()` estaba en el `case GatewayModeDisabled`, que corre
**después** de `getGatewayNextHops()` (`gateway_init.go:254`). Si un breth stale
rompió la default route, `getGatewayNextHops()` crashea antes de limpiar. Se movió
el cleanup al inicio de `initGatewayPreStart`, antes del next-hop. → **primer freno
a V4** (limpia el breth y restaura la ruta antes de necesitarla).

### Capa 3 — `getGatewayNextHops()` no-fatal en disabled
Commit `f9ff50d89`.

Aunque no haya default route, en disabled el next-hop **no se usa** (no se arma
gateway). Ahora ese error **no es fatal**: se deriva `gatewayIntf` de la IP primaria
del nodo (`util.GetNodePrimaryIP` → `getInterfaceByIP`, el patrón del modo DPU) y se
continúa con next-hops vacíos. → **cierra V4 de raíz** (el binario ya no puede
crashear por falta de ruta en disabled, haya o no breth stale).

## Lifecycle: dónde actúa cada capa en el arranque

```
  REBOOT / start del pod ovnkube-node
        │
        ▼
  ovs-node (emptyDir) ──────────────▶ OVS db FRESCA, sin breth1 stale   ◄── Capa 0 (V3)
        │
        ▼
  ovnkube.sh (entrypoint)
     OVN_GATEWAY_MODE="" respetado ──▶ modo = disabled                  ◄── Capa 0/1 (V1)
        │
        ▼
  ovnkube ovn-node → initGatewayPreStart()
        │
        ├─▶ cleanupStaleGatewayBridges()  (reintentos, del-br seguro)   ◄── Capa 1+2 (V2, V4)
        │      · borra cualquier breth* stale, restaura IP/ruta al uplink
        │
        ├─▶ getGatewayNextHops()
        │      · si no hay ruta → NO fatal, usa la iface del IP del nodo ◄── Capa 3 (V4)
        │
        ├─▶ switch mode == Disabled → gateway stub (sin bridge)          ◄── Capa 0 (nil guards)
        │
        ▼
  nodo Ready, eth1 con IP (sin enslave), sin breth
```

## Mapeo falla → capa

| Vía | Capa que la cierra | Mecanismo |
|-----|-------------------|-----------|
| V1 config/coerción | Capa 0 (sed entrypoint) + Capa 1 (pin fuente) | Modo vacío se respeta y la fuente no vuelve a shared |
| V2 transición en vivo | Capa 1 (cleanup robusto) + Capa 2 (orden) | Borra breth* con reintentos + force del-br seguro |
| V3 reboot | Capa 0 (emptyDir) | OVS db efímera, sin breth stale que recrear |
| V4 crash sin ruta | Capa 2 (cleanup temprano) + Capa 3 (no-fatal) | Limpia antes del next-hop; y si falta ruta, no crashea |

## Funciones clave (código)

| Función | Archivo | Rol |
|---------|---------|-----|
| `cleanupStaleGatewayBridges` | `pkg/node/gateway_init.go` | Loop de reintentos, 2 pasadas limpias |
| `removeStaleGatewayBridgesOnce` | idem | Un escaneo: borra cada `breth*` |
| `removeOneStaleGatewayBridge` | idem | `BridgeToNic` o force `del-br` seguro |
| `interfaceHasGlobalIP` / `ovsBridgeExists` | idem | Guardas de seguridad del force-delete |
| `getGatewayNextHops` (fallback disabled) | idem | No-fatal + deriva iface del IP del nodo |
| `util.NicToBridge` / `util.BridgeToNic` | `pkg/util/nicstobridge.go` | Crean/deshacen el enslavement |

## Evidencia (validado en vivo 2026-07-20, imagen `hackctf-v24`)

- **Auto-remoción (V2)** — breth0 stale sintético borrado solo:
  ```
  gateway_init.go: HackCTF fix: removing stale gateway bridge "breth0" (uplink="breth0up")
  nicstobridge.go: Successfully deleted OVS bridge "breth0"
  gateway_init.go: HackCTF fix: stale gateway bridge scan pass 1: removed=1 still-present=0
  ```
- **Reboot (V3)** — worker Y master levantaron limpios:
  ```
  gateway_init.go: HackCTF fix: no stale gateway bridges present (confirmed over 2 passes)
  gateway_init.go: Gateway Mode is disabled
  ```
  eth1 con IP, sin breth, sin crash, control-plane vuelve solo.
- **Sin crash (V4)**: ningún `unable to find default gateway` / panic en el arranque.

## Deploy

Los fixes van en el binario `ovnkube` (ver `HACKCTF_OVNKUBE_BINARY.md`). Build con
`Dockerfile.hackctf.minimal`, tag `hackctf-vXX`, y rolar `ovnkube-node` +
`ovnkube-master` a mano (el rollout del DS deadlockea con un nodo muerto).
