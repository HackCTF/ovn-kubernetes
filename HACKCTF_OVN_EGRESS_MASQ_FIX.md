# HackCTF: egress de pods en GatewayModeDisabled — MASQUERADE persistente del host

> **Aviso de alcance:** este documento describe el **MECANISMO** de egress (el NAT
> del nodo que hace funcionar la salida *permitida*). El **quién tiene acceso a
> internet** es una capa aparte, gestionada por Kumi (parámetro `internet`, default
> `false`) y por las **NetworkPolicies** (ver §4). **El MASQUERADE global NO habilita
> internet a todos los pods**: solo materializa el egress que la policy ya autorizó.

## Contexto

El cluster Combate (VirtualBox host-only, master `eth0` NAT + `eth1`, workers WiFi)
corre OVN-Kubernetes con **`OVN_GATEWAY_MODE=""` (disabled)** de forma deliberada —
`shared`/`local` enslavan el uplink vía `util.NicToBridge()` y, como esa NIC es a la
vez el único camino de management (SSH/API), el nodo/control-plane queda inalcanzable
(ver `HACKCTF_GATEWAY_MODE_DISABLED_FIX.md`).

En `disabled` **no hay gateway router ni `breth`** y, por lo tanto, **OVN no programa
NAT de salida**. El datapath de egress de la red default es:

```
  pod (10.244.x.x) ──▶ ovn-k8s-mp0 (mgmt port 10.244.x.2) ──▶ [ kernel del host ]
                                                                    │
                                                                    ▼
                                        rutas del host ──▶ uplink (eth0 / wlp4s0 / wlp1s0)
```

Es decir: OVN entrega el tráfico del pod al stack de red del **nodo**, y **el nodo
(hace de router) es quien debe hacer el SNAT** hacia su NIC física. Eso funcionó
(medido 2026-07-21: `curl 1.1.1.1` desde un pod → `exit=0`), pero **la regla NO era
persistente**: no hay `iptables-persistent` en los nodos.

## Incidente 2026-08-13 (reboot → pods sin internet)

El reboot de w1 (11:01:39) y la posterior operación dejaron los pods sin egress:

- El SYN del pod salía de `ovn-k8s-mp0` y se reenviaba por `wlp4s0` **con `src=IP
  del pod` (10.244.0.31), sin NAT** → el destino no puede responderle → timeouts.
- `curl 1.1.1.1` desde el pod → `code=000/exit 28`; `TCP 8.8.8.8:53` FAIL.
- **DNS externo SERVFAIL**: CoreDNS (pods en el master) tampoco alcanza los
  upstream `8.8.8.8` / `187.221.155.138:53` → `lookup ... on 10.96.0.10:53: server
  misbehaving`. Esto también rompió el **webhook de Kumi** (`machine-status`), que
  falló con ese mismo error DNS.
- Evidencia por nodo: `iptables -t nat -S POSTROUTING` sin ninguna regla
  MASQUERADE/SNAT para `10.244.0.0/16` (solo `KUBE-POSTROUTING` mark 0x4000 y el
  SNAT especial de la API `192.168.1.50:6443` de `kube-svc-dnat`).

**Causa raíz**: no existe el MASQUERADE del host para el CIDR de pods. En el diseño
disabled es **responsabilidad del nodo** proveerlo, y se perdió con el reboot.

## Fix

Servicio systemd **oneshot por nodo** que re-aplica la regla al boot (patrón
`kube-svc-dnat.service` / `hackctf-cleanup-ovs-db.service`), idempotente:

### `/usr/local/bin/hackctf-ovn-egress-masq.sh`

```bash
#!/bin/bash
# hackctf-ovn-egress-masq.sh - MASQUERADE persistente para egress de pods OVN-K
# OVN_GATEWAY_MODE="" (disabled): OVN no aplica NAT de salida; el host debe
# SNATear el trafico de POD_CIDR hacia su uplink. Se re-aplica al boot porque
# no hay iptables-persistent y el reboot limpia las reglas.
# NOTA: esto es el MECANISMO de egress, no una habilitacion de internet. La
# autorizacion por pod la hacen las NetworkPolicies (param `internet` de Kumi).
set -e

POD_CIDR="10.244.0.0/16"

if iptables -t nat -C POSTROUTING -s "$POD_CIDR" ! -d "$POD_CIDR" -j MASQUERADE 2>/dev/null; then
    echo "[ovn-egress-masq] rule already present for $POD_CIDR"
else
    iptables -t nat -A POSTROUTING -s "$POD_CIDR" ! -d "$POD_CIDR" -j MASQUERADE
    echo "[ovn-egress-masq] MASQUERADE added for $POD_CIDR"
fi

iptables -t nat -S POSTROUTING | grep -E "MASQUERADE.*$POD_CIDR" || true
echo "[ovn-egress-masq] Done"
```

### `/etc/systemd/system/hackctf-ovn-egress-masq.service`

```ini
[Unit]
Description=HackCTF: MASQUERADE egress pods OVN-K (GatewayMode disabled)
Documentation=https://github.com/HackCTF/ovn-kubernetes
After=network-online.target
Before=kubelet.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hackctf-ovn-egress-masq.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Detalles de diseño

- **Regla**: `MASQUERADE -s 10.244.0.0/16 ! -d 10.244.0.0/16`. El guard `! -d` evita
  enmascarar el tráfico este-oeste (pod↔pod, mgmt ports) que NO debe pasar por el
  NAT del host. No usa `-o eth0` (a diferencia de los `postUp` de los labs): así
  funciona en cualquier uplink por nodo (master `eth0` NAT / workers WiFi).
- **MASQUERADE** (no SNAT a IP fija): toma la IP fuente de la ruta de salida de cada
  nodo (master `10.0.2.15`, workers `192.168.1.x`) → correcto para los 3.
- **`Before=kubelet.service`**: la regla está activa antes de que arranquen los
  pods; de todos modos es global (aplica al tráfico futuro aunque se añada tarde).
- Es **aditivo y no conflictivo** con `kube-svc-dnat` (API DNAT) ni con
  `KUBE-POSTROUTING` (mark 0x4000), que operan por destinos específicos.

## Modelo de acceso a Internet en Kumi (la capa de POLÍTICA)

El egress de cada pod NO lo decide el MASQUERADE del nodo: lo decide la capa de
**NetworkPolicies** (ACLs OVN). Kumi lo orquesta con un parámetro explícito:

### Parámetro `internet` (default `false` = desactivado)

- Entra por la API: `req.Internet` (`internal/api/handlers.go:451,472`) →
  `PodParams.Internet` / `SessionParams.Internet` (`internal/k8s/pod.go:86`,
  `internal/k8s/session.go:33`). El backend lo mapea desde el campo "Acceso a
  Internet" de la UI y lo envía en `device.config["internet"]` (ver
  `docs/FLUJOS_INTERACCION_SISTEMAS.md` §modal atacante).
- Se materializa en el pod/StatefulSet como label `internet` (`true`/`false`) y
  annotation `kumi.io/internet-enabled` (`pod.go:342`).
- Cuando es `true` (v2.19.8+), Kumi **crea** la NetworkPolicy
  `allow-internet-{podUUID}`: `CreateStatefulSet` invoca `ApplyInternetPolicy`
  tras el Create (`pod.go:492`), y esta (`pod.go:875`) amplía el egress a
  **todos los puertos** hacia `0.0.0.0/0` excepto RFC1918, además de DNS.

### Policy base de los labs (`allow-kali-base-{username}`)

`ApplyBaseNetworkPolicy` (`internal/k8s/init.go:410-516`) aplica a todos los
pods de lab del usuario:

| Plano | Egress permitido | Ingress permitido |
|---|---|---|
| DNS | `53/udp` + `53/tcp` → kube-dns | — |
| Web | `80/tcp` + `443/tcp` → `0.0.0.0/0` excepto RFC1918 | — |
| Consola | — | `6080/tcp` desde ns `traefik` |

Consecuencia: con `internet=false` (default) el pod de lab tiene **DNS + web
(80/443)**, pero NO puertos arbitrarios, ICMP, ni egress a rangos privados. Con
`internet=true` el union de ambas policies le da **egress completo**.

> **Gap RESUELTO (2026-08-14, v2.19.8):** `ApplyInternetPolicy` **ya tiene
> callers** en el código — `internet: true` SÍ crea el `allow-internet-{podUUID}`
> en el cluster. Fix: `createTopologyVM` y `createTopologyAttacker`
> (`topology.go:353,812`) leen `device.Config["internet"]` vía
> `models.ExtractConfigBool` y lo propagan a `PodParams.Internet`; `CreateStatefulSet`
> llama a `ApplyInternetPolicy` tras el Create (`pod.go:492`, idempotente ante
> `IsAlreadyExists`). El borrado sigue cableado (`DeleteInternetPolicyByUUID`,
> `delete.go:323`, invocado en `delete.go:551`). Verificado end-to-end (§Verificación).

### Quién tiene egress HOY en el cluster (inventario real, 2026-08-14)

| Plano | Namespaces | Netpol egress | Resultado |
|---|---|---|---|
| Infra Kumi | `kumi-system` | **ninguna** | egress total vía MASQUERADE (requerido: webhooks `:4000`, DNS) |
| Sistema | `kube-system` | (CoreDNS) | egress requerido para upstreams DNS |
| OVN | `ovn-kubernetes` | ninguna | egress requerido (GARP, registros, etc.) |
| Labs (`user-*`) | `user-superadmin`, … | base + lab-isolation (+ `allow-internet-{uuid}` si `internet=true`) | default: DNS + web (80/443) a público; con `internet=true`: egress completo a 0.0.0.0/0 excepto RFC1918 |

El MASQUERADE global es **prerrequisito** para que esos egress legítimos funcionen;
no les agrega permiso a los que la policy restringe (con `internet=false` la Kali no
llega a `:4000` pese al MASQUERADE — su netpol solo permite 53/80/443; con
`internet=true` el `allow-internet-{uuid}` sí lo habilita).

## Políticas de acceso, monitoreo y alertas

### Políticas de acceso (estado)

1. **Mecanismo** (este fix): MASQUERADE del nodo para `10.244.0.0/16` — implementado,
   persistente (systemd), idéntico en los 3 nodos.
2. **Autorización por pod** (Kumi `internet` + netpols) — **implementado completo**
   (v2.19.8): base `allow-kali-base-{username}` (DNS + web 80/443) + `allow-internet-{uuid}`
   cuando `internet=true` (egress completo a 0.0.0.0/0 excepto RFC1918), borrado en el delete.
3. **Inventario de acceso** — pendiente: revisar qué netpols aplican en cada
   namespace `user-*` y en infra (esto doc es el punto de partida).

### Monitoreo

- **Enforcement**: las NetworkPolicies se aplican como ACLs OVN por LSP → el egress
  no autorizado se descarta antes de llegar al host (observable con `tcpdump` en
  `ovn-k8s-mp0`). Monitorear el contador de paquetes drop de ACLs
  (`ovn-nbctl acl-list` + `ovs-ofctl dump-flows br-int`) para detectar intentos de
  egress bloqueados.
- **Regla del nodo**: verificar en cada boot/checks que la regla
  `-A POSTROUTING -s 10.244.0.0/16 ... -j MASQUERADE` esté presente en los 3 nodos
  (`systemctl is-active hackctf-ovn-egress-masq` + `iptables -t nat -S POSTROUTING`).
- **Egress monitoring (planificado)**: el threat model ya lo exige — AM-4
  "Exfiltración de datos via egress" → mitigación "Tetragon egress monitoring,
  egress filtering"; KPI "Cobertura de egress monitoring = 100%" está **PENDING**
  (`ARQUITECTURA_OVN_KUBERNETES_TETRAGON.md` §3.2 y §7.2). Es el item que cierra
  el monitoreo real de lo que sale de cada pod.

### Alertas (planificadas)

| Alerta | Detonante | Canal sugerido | Estado |
|---|---|---|---|
| Drift de regla de egress | `hackctf-ovn-egress-masq` inactivo o regla ausente en algún nodo | Prometheus/blackbox + notif. | Planificado |
| Egress no autorizado | Conteo alto de drops de ACL OVN (intentos bloqueados) | Alertmanager | Planificado |
| Pod con egress fuera de policy | Evento de netpol en `user-*` que amplíe egress (no `internet:true` aprobado) | Auditoría de eventos k8s | Planificado |
| Cambio de netpol en infra | netpol nueva/borrada en `kumi-system`/`kube-system`/`ovn-kubernetes` | Auditoría de eventos k8s | Planificado |

## Verificación (2026-08-14, cluster Combate)

- Desplegado en los 3 nodos: `systemctl is-enabled` → `enabled`; `is-active` →
  `active`; regla presente en `POSTROUTING`.
- Pod `d-47976a8c2576-0` (user-superadmin, w1): `curl http://1.1.1.1/` → `301`,
  `TCP 8.8.8.8:53` OK, `getent ahosts home.hackctf.com.ar` → `187.221.155.138`.
- **Webhook Kumi** (`machine-status`, `status=running`) entregado sin fallos. Antes
  del fix fallaba: `Post "https://home.hackctf.com.ar:4000/api/webhooks/kumi/machine-status":
  dial tcp: lookup home.hackctf.com.ar on 10.96.0.10:53: server misbehaving`.
- Backend `https://home.hackctf.com.ar:4000` responde (health `200`).
- **La policy sigue mandando**: con `internet=false` el pod Kali NO alcanza `:4000`
  (su netpol solo permite 53/80/443) pese a tener el MASQUERADE activo → confirma
  que el MASQUERADE es mecanismo y no habilitación.

## Verificación del fix de egress (Kumi v2.19.8, 2026-08-14)

- Desplegado: imagen `harbor.k8s.local:8443/library/kumi-server:2.19.8`, health
  `{"status":"ok","version":"2.19.8"}` (helm REVISION 12).
- Kali creado desde el **Backend** (flujo completo: UI → `POST /labs/v2` →
  webhook `machine-status`): pod `d-47976a8c2576-0` en `user-superadmin` con
  label **`internet=true`**.
- NetworkPolicy `allow-internet-47976a8c-...` creada automáticamente con selector
  `internet: "true"` + egress (53 UDP/TCP, 80/443, IPBlock `0.0.0.0/0` excepto
  RFC1918).
- Egress real desde el pod: `https://8.8.8.8/` → 302, `http://1.1.1.1/` → 301,
  `https://www.google.com/` → HTML completo.
- Test TDD: `internal/k8s/internet_test.go` (`TestCreateTopologyLab_AttackerInternet`)
  — rojo→verde, asserta label `internet=true` + NetworkPolicy existente.

## Referencias

- `D:\HackCTF\ovn-kubernetes\HACKCTF_GATEWAY_MODE_DISABLED_FIX.md` — por qué disabled
  y el riesgo de `shared`/`local` (enslave).
- `D:\HackCTF\chart\Kumi\docs\Laboratorios\ARQUITECTURA_OVN_KUBERNETES_TETRAGON.md`
  §15 (Issue 4) — historial del gateway mode empty y el intento `local` de julio;
  §3.2 (AM-4) y §7.2 (KPI egress monitoring PENDING) — monitoreo/alertas.
- `D:\HackCTF\chart\Kumi\internal\k8s\pod.go` (`ApplyInternetPolicy`),
  `internal\k8s\init.go` (`ApplyBaseNetworkPolicy`), `internal\api\handlers.go`
  (campo `internet`) — modelo de acceso de Kumi.
- `D:\HackCTF\chart\Kumi\docs\Laboratorios\FIX_OVN_BRIDGE_CATCH22.md` — patrón de
  unidad systemd pre-boot (`hackctf-cleanup-ovs-db.service`).
- `/etc/systemd/system/kube-svc-dnat.service` + `/usr/local/bin/kube-svc-dnat.sh`
  (workers) — patrón del que deriva este servicio (After/Befor/oneshot/idempotente).
