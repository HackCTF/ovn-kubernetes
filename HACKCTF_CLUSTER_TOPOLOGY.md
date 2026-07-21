# HackCTF: topología del cluster Combate (OVN-K + MetalLB + Traefik + labs)

Vista de ingeniería de cómo encaja la red del cluster de labs, con OVN-Kubernetes en
`GatewayModeDisabled` (sin gateway bridge). Datos verificados en vivo 2026-07-21
(post-recuperación de `funny-einstein`).

## Nodos

| Nodo | IP host-only | Rol | Estado |
|------|-------------|-----|--------|
| thirsty-kapitsa | 192.168.56.140 | control-plane (API, etcd) + OVN NB/SB db | ✅ Ready |
| nervous-vaughan | 192.168.56.142 | worker (labs, VMs) | ✅ Ready |
| funny-einstein | 192.168.56.141 | worker (labs, VMs) | ✅ Ready (recuperado 2026-07-21) |

Red física: host-only `192.168.56.0/24` (management/API + MetalLB) + NAT `10.0.2.0/24`
(egress). NIC `e1000` (una cola RX). Host Windows con VirtualBox.

### Storage por nodo (post-recuperación)

| Nodo | OS disk | Container storage | LVM (topolvm) |
|------|---------|-------------------|---------------|
| thirsty-kapitsa | /dev/sda (20 GB) | /dev/sda4 (rootfs) | /dev/sdc (300 GB) |
| funny-einstein | /dev/sda (20 GB) | **/dev/sdd (200 GB XFS) montado en `/var/lib/containers/storage`** | /dev/sdc (300 GB) |
| nervous-vaughan | /dev/sda (20 GB) | /dev/sdd (200 GB XFS) montado en `/var/lib/containers/storage` | /dev/sdc (300 GB) |

`funny-einstein` recuperó su nodo tras corrupción del VDI de 200G durante un
`Move-Item` entre discos NTFS distintos (ver `D:\HackCTF\Vms\AGENTS.md` sesión
v2.16.1). El VDI fue reemplazado y el storage re-formateado con el mismo patrón
que `nervous-vaughan` (XFS en `sdd` montado vía fstab con `defaults,nofail`).
NIC interface names cambiaron a `enp0s3` (NAT) / `enp0s8` (host-only) tras el
recovery (antes `eth0`/`eth1` en nervous-vaughan).

## Capa 1 — Plano de datos OVN (este-oeste, disabled)

OVN corre en **disabled**: NO hay `breth`/gateway router. Sólo `br-int` (overlay) +
túneles **Geneve** entre nodos. Componentes (namespace `ovn-kubernetes`):
`ovnkube-node` (DS, gateway init/CNI), `ovs-node` (DS, OVS con `emptyDir`),
`ovnkube-master` (Deploy, cluster-manager), `ovnkube-db` (Deploy, NB/SB), `ovnkube-identity`.

```
         thirsty-kapitsa (.140)              nervous-vaughan (.142)              funny-einstein (.141)
   ┌───────────────────────────┐      ┌───────────────────────────┐      ┌───────────────────────────┐
   │  pods ─veth─▶ br-int      │      │      br-int ◀─veth─ pods   │      │      br-int ◀─veth─ pods   │
   │              (overlay)    │      │      (overlay)            │      │      (overlay)            │
   │                 │         │      │         │                 │      │         │                 │
   │              Geneve ══════╪══════╪═════════ Geneve           │══════╪═════════ Geneve           │  ◄── E-W entre nodos
   │                           │      │                           │      │                           │      (UDP 6081)
   │  enp0s8 .140 (mgmt)       │      │   enp0s8 .142 (mgmt)       │      │   enp0s8 .141 (mgmt)       │  ◄── NIC física PLANA,
   │  enp0s3 (NAT egress)      │      │   enp0s3 (NAT egress)      │      │   enp0s3 (NAT egress)      │      sin breth, sin enslave
   │  /dev/sda (20G, rootfs)   │      │   /dev/sda (20G, rootfs)   │      │   /dev/sda (20G, rootfs)   │  ◄── OS disk
   │  /dev/sdd (200G, no LVM)  │      │   /dev/sdd (200G, storage) │      │   /dev/sdd (200G, storage) │  ◄── container storage
   │  /dev/sdc (300G, topolvm) │      │   /dev/sdc (300G, topolvm) │      │   /dev/sdc (300G, topolvm) │      XFS en sdd, vg en sdc
   └───────────────────────────┘      └───────────────────────────┘      └───────────────────────────┘
```

Lo que da OVN sin gateway: pod↔pod, **ClusterIP** (LB en el logical switch),
secondary networks L2 de los labs. Lo que **no** da: NodePort/ExternalIP/LB nativos
(los cubre MetalLB, abajo).

## Capa 2 — Norte-sur SIN gateway OVN: MetalLB + Traefik

Como OVN no hace el ingress norte-sur en disabled, el acceso externo entra por
**MetalLB (L2)** + **Traefik**:

- **MetalLB** anuncia por ARP (L2Advertisement `default-l2-adv`) IPs del pool
  `192.168.56.211-250` sobre la red host-only.
- El Service `traefik/traefik` es `LoadBalancer` → MetalLB le asigna
  **`192.168.56.211`** (puertos 80/443). Traefik (2 réplicas) hace el ruteo por
  `Host()` / `PathPrefix()` a los Services de las consolas de labs.

```
   red física host-only 192.168.56.0/24
            │  (ARP: MetalLB anuncia .211)
            ▼
   ┌─────────────────────────────────────────────┐
   │ Service traefik  LoadBalancer  192.168.56.211│  :80 / :443
   └───────────────────────┬─────────────────────┘
                           ▼
                  Traefik (IngressRoute: Host(`user.kali.lab`) + PathPrefix(`/labs/...`))
                           ▼
                  Service (ClusterIP) ─▶ pod consola (VNC/ttyd) del lab
```

## Capa 3 — Provisioning: Kumi

`kumi-system`: **Kumi API** (3 réplicas) + **PostgreSQL**. Kumi es el único operador
del cluster: recibe `POST /labs/v2` y crea, en el namespace `user-{username}`, los
recursos del lab (StatefulSets/VMs, Services, IngressRoutes+Middlewares Traefik,
NADs, Secrets). `kumi-middleware-system` = operador de middlewares.

## Capa 4 — Anatomía de un lab (namespace `user-{username}`)

Dos planos de red por lab:

- **Redes de acceso/VLAN** = **OVN secondary networks** (`ovn-k8s-cni-overlay`
  `topology:layer2`) vía Multus: una NAD = un logical switch L2 aislado, cruza
  nodos por Geneve. Ej. l2-attacks: VLAN10 `10.10.10.0/24`, VLAN20, VLAN30.
- **Cable trunk 802.1q** (sólo `nf-ovs-switch`) = **ovs-cni** sobre bridge
  `br-lab-trunk-{hash}` con **malla VXLAN cross-node** (DaemonSet `kumi-lab-trunk-mesh`,
  mesh v2 namespace-isolated: bridge + VNI + IPsec PSK por namespace).
- **Víctimas** pueden ser pods **o VMs KubeVirt** (`kubevirt` ns, 10 virt pods).

```
   namespace user-superadmin
   ┌──────────────────────────────────────────────────────────────┐
   │  kali-attack ──net1── OVN LS vlan10 (10.10.10.0/24) ──net1── victim-hr        │
   │       │                     (Geneve, cross-node)                              │
   │       └──net2── OVN LS trunk / br-lab-trunk-{hash} (ovs-cni + VXLAN mesh)      │
   │                                                                              │
   │  eth0 de cada pod ── red default OVN ── Service/IngressRoute ── Traefik ──▶ consola web │
   └──────────────────────────────────────────────────────────────┘
```

## Capa 5 — Acceso externo end-to-end (usuario → consola de lab)

```
  usuario ─▶ home.hackctf.com.ar (frontend)
              │
              ▼
          Backend ─▶ Torii (proxy en Windows, :8443)
              │
              ▼   https://kumi.hackctf.com.ar:8443  →
          192.168.56.211:443  (MetalLB → Traefik)
              │
              ▼  IngressRoute: Host(`user.kali.lab`) && PathPrefix(`/labs/{name}/`)
          Service ClusterIP ─▶ pod consola (VNC 6080 / ttyd 7681)
```

Notas: la API de Kumi se alcanza por el mismo camino (Torii → MetalLB → Traefik →
Service `kumi`). Harbor (registry/charts) vive en un **cluster aparte**
(192.168.56.136-138), alcanzable sólo desde la red interna.

## Resumen: quién hace qué

| Función | Componente |
|---------|-----------|
| E-W pod↔pod, ClusterIP, L2 de labs | OVN-K (`br-int` + Geneve), disabled |
| Egress de pod a internet | stack del nodo (NAT eth0) |
| Ingress externo (norte-sur) | **MetalLB (L2, .211)** + **Traefik** |
| Provisioning de labs | **Kumi** (kumi-system) |
| Aislamiento de red de labs | OVN logical switches (VLANs) + trunk VXLAN mesh v2 por namespace |
| VMs víctima | KubeVirt |
| Registry/charts | Harbor (cluster aparte) |
| Entrada desde internet | frontend → Torii (Windows) → MetalLB |

> Por qué OVN va en disabled y no rompe nada: el único norte-sur real (ingress a
> consolas y API) lo hace MetalLB+Traefik, no el gateway OVN. Ver
> `HACKCTF_GATEWAY_MODE_DISABLED_FIX.md`.
