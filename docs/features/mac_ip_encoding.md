# IP Estática vs Dinámica en OVN-K Layer 2 (Layer 2 Topology)

## Descripción general

OVN-Kubernetes soporta dos modos de asignación de IPs para redes secundarias (secondary networks) con topología layer 2:

1. **IPAM dinámico** (por defecto): OVN-K asigna IPs automáticamente del rango definido en `subnets`.
2. **IP fija en anotación Multus**: el pod solicita una IP específica vía `"ips"` en la anotación.

Este documento describe ambos modos, sus limitaciones, y la **solución actual** usada en producción.

## IPAM Dinámico (recomendado)

### Descripción

Cuando el NAD define un `subnets`, OVN-K activa IPAM automáticamente. Cada pod que se conecta a ese NAD recibe una IP única del rango disponible. No se requiere configuración adicional en el pod.

### Configuración

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: lab-net-vlan10
  namespace: user-superadmin
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "type": "ovn-k8s-cni-overlay",
      "name": "lab-net-vlan10",
      "topology": "layer2",
      "subnets": "10.10.10.0/24"
    }
```

```yaml
# Pod con anotación Multus (SIN "ips")
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [{"name": "lab-net-vlan10", "interface": "net1"}]
```

### Diagrama: Asignación dinámica

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         IPAM DINÁMICO (por defecto)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  NAD Config:                                                                │
│  {                                                                          │
│    "subnets": "10.10.10.0/24"    ← Rango de IPs disponible                  │
│  }                                                                          │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    OVN-K IPAM Allocator                              │   │
│  │                                                                      │   │
│  │   Rango: 10.10.10.0/24 (.1 - .254)                                  │   │
│  │                                                                      │   │
│  │   ┌─────────────────────────────────────────────────────────────┐    │   │
│  │   │ Pool de IPs:                                                │    │   │
│  │   │ 10.10.10.1  │ 10.10.10.2  │ 10.10.10.3  │ ... │ 10.10.10.254│    │   │
│  │   └─────────────────────────────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  victim-hr-1 solicita → IPAM asigna 10.10.10.18                              │
│  victim-hr-2 solicita → IPAM asigna 10.10.10.6                               │
│  kali-attack solicita → IPAM asigna 10.10.10.15                              │
│                                                                             │
│  ✅ Cada pod tiene IP única automáticamente                                  │
│  ✅ Sin coordinación manual                                                  │
│  ✅ IPs pueden cambiar entre recreaciones (no estables)                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Limitación importante

**Las IPs asignadas por IPAM NO son estables entre recreaciones del pod.** Cada `kubectl delete pod` + `apply` puede resultar en una IP diferente, porque IPAM recorre el pool. Para obtener la IP actual:

```bash
# Desde el pod
kubectl exec -n <ns> <pod> -- ip -4 addr show <interface>

# Desde el NAD/OVN-K
kubectl exec -n ovn-kubernetes ovs-node-XXX -- \
  ovs-vsctl --columns=name,external_ids list Interface | \
  grep <pod-name>

# Desde KubeVirt (si aplica)
kubectl get vmi -n <ns> <vm> -o jsonpath='{.status.interfaces[*].ipAddress}'
```

## IP Fija en Anotación Multus — ❌ NO FUNCIONA en OVN-K

### El problema

Incluir `"ips": ["10.10.10.99/24"]` en la anotación Multus para OVN-K secondary networks **causa timeout** y el pod nunca arranca.

### Síntoma exacto (de logs reales)

```
failed to get pod annotation: timed out waiting for annotations:
context deadline exceeded
```

El pod queda en estado `ContainerCreating` indefinidamente y, eventualmente, falla.

### Causa raíz

OVN-K ignora la solicitud `IPRequest` cuando el NAD requiere IPAM (`doesNetworkRequireIPAM() == true`, que es el caso para layer 2 con `subnets` configurado). El CNI annotation writer espera una respuesta del OVN-K IPAM que nunca llega, porque IPAM maneja la asignación internamente y no notifica al annotation writer.

### Configuración que causa timeout (NO USAR)

```yaml
# ❌ ESTO CAUSA TIMEOUT — NO USAR
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "lab-net-vlan10",
          "interface": "net1",
          "ips": ["10.10.10.99/24"]   ← Ignorado por OVN-K, causa timeout
        }
      ]
```

### Alternativas probadas

| Alternativa | Estado | Notas |
|-------------|--------|-------|
| IPAM dinámico (sin `ips` en anotación) | ✅ Funciona | **Solución actual recomendada** |
| `"ips"` en anotación Multus | ❌ Timeout | Probado en lab `l2-attacks-01`, no viable |
| Pre-asignar IP via `whereabouts` (otro CNI) | ⚠️ Requiere migrar | No aplica con OVN-K |

## Codificación MAC↔IP (observación técnica)

OVN-K codifica la IP asignada dentro de los últimos bytes de la MAC address. Esto es **determinista** y permite que un guest OS (como Cirros) derive su propia IP leyendo el MAC de la interfaz — sin necesidad de DHCP ni configuración previa.

### Patrón observado

| Subred | 5to byte MAC | Último byte MAC | IP resultante |
|--------|--------------|-----------------|---------------|
| `10.10.10.0/24` | `0a` (=10 decimal) | `XX` (=host) | `10.10.10.XX` |
| `10.10.20.0/24` | `14` (=20 decimal) | `XX` (=host) | `10.10.20.XX` |
| `10.10.30.0/24` | `1e` (=30 decimal) | `XX` (=host) | `10.10.30.XX` |
| `10.10.99.0/24` | `63` (=99 decimal) | `XX` (=host) | `10.10.99.XX` |

**Ejemplo verificado**: VM con MAC `0a:58:0a:0a:0a:42` → IP `10.10.10.66` (0x42 = 66).

### Shell script para derivar IP desde MAC (Cirros cloud-init)

```sh
#!/bin/sh
i=0
while [ "$i" -lt 60 ]; do
  if [ -e /sys/class/net/eth1 ]; then
    ip link set eth1 up
    MAC=$(cat /sys/class/net/eth1/address)
    LAST_HEX=${MAC##*:}
    LAST=$((0x$LAST_HEX))
    ip addr add 10.10.10.$LAST/24 dev eth1
    break
  fi
  i=$((i+1))
  sleep 1
done
```

**Importante**: este patrón **NO** garantiza la misma IP entre recreaciones. Si la MAC cambia (no debería, porque OVN-K deriva la MAC de la IP), la IP cambia con ella. En pruebas reales, OVN-K mantiene la MAC estable para un mismo par (puerto lógico, namespace) entre recreaciones — pero esto no está documentado oficialmente.

## Toggle `mac_ip_encoding` en NAD

OVN-K codifica la MAC de un pod determinísticamente a partir de la IPv4 asignada. Por defecto, esta codificación está **activada** y usa el método heredado `IPAddrToHWAddr` (4 bytes completos de la IP), lo cual funciona bien para `/24` pero produce colisiones cuando varias subredes `10.x.x.x` coexisten.

El toggle `mac_ip_encoding` en el NAD permite controlar este comportamiento explícitamente.

### Configuración

Agregar `mac_ip_encoding` al `spec.config` del NAD:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: lab-net-vlan10
  namespace: user-superadmin
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "type": "ovn-k8s-cni-overlay",
      "name": "lab-net-vlan10",
      "subnets": "10.10.10.0/24",
      "mac_ip_encoding": true
    }
```

### Valores

| Valor | Comportamiento |
|-------|----------------|
| `true` | Codificación activada con longitud variable (soporta `/16`-`/32` sin colisiones). Subredes `/8`-`/15` usan método heredado. |
| `false` | Codificación desactivada. MAC aleatorio por pod (`GenerateRandMAC`), OUI `0a:58` se mantiene. |
| _(omitido)_ | **Default: `true`** (preserva comportamiento original de OVN-K). |

### Precedencia

La anotación `MacRequest` del pod **siempre tiene prioridad** sobre el toggle del NAD:

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"lab-net","mac":"aa:bb:cc:dd:ee:ff"}]'
```

Ese pod obtendrá `aa:bb:cc:dd:ee:ff` independientemente de `mac_ip_encoding`.

### Formato de codificación variable-length

```
MAC[0:2] = 0a:58                       (OUI de OVN-K)
MAC[2]   = 0x10 + (prefijo - 16)       (indicador de longitud de prefijo)
MAC[3:6] = bits_subred << bits_host | bits_host_del_IP
```

**Ejemplos:**

| Subred | IP | MAC resultante |
|--------|-----|----------------|
| `10.10.10.0/24` | `10.10.10.99` | `0a:58:18:0a:0a:63` |
| `10.10.0.0/16` | `10.10.10.99` | `0a:58:10:0a:0a:63` |
| `10.10.10.0/25` | `10.10.10.99` | `0a:58:19:00:0a:63` |

El indicador de prefijo (`MAC[2]`) previene colisiones: un pod en `/16` obtiene `0x10`, mientras que uno en `/24` obtiene `0x18`. Misma IP, MAC diferente.

### Cuándo usar cada valor

| Escenario | Valor | Razón |
|-----------|-------|-------|
| Múltiples subredes `10.x.x.x` coexisten | `true` con variable-length | Evita colisiones MAC entre VLANs |
| Necesitas MAC aleatorios por privacidad/testing | `false` | MAC no correlacionado con IP |
| Compatibilidad con código legacy que asume `IPAddrToHWAddr` | _(omitido)_ o `false` | Default `true` usa variable-length que cambia formato |
| Máximo determinismo para reproducibilidad | `true` | Misma IP → misma MAC siempre |

## Limitaciones

- **`"ips"` en anotación Multus**: NO funciona en OVN-K con layer 2 + `subnets`. Causa timeout. **Workaround conocido: ninguno.**
- **IPAM dinámico**: Las IPs no son estables. Cada recreación puede dar IP distinta.
- **DHCP de OVN-K**: El servidor DHCP interno no se propaga al puerto de la VM correctamente en este cluster (al menos para KubeVirt VMs). Usar cloud-init estático basado en MAC.
- **IPv6**: Probado parcialmente, fuera de alcance para CTF labs.

## Cuándo usar cada modo

| Necesidad | Modo | Configuración |
|-----------|------|---------------|
| Múltiples VMs/pods en misma subred | ✅ **IPAM dinámico** | NAD sin `"ips"` en anotaciones |
| Pods efímeros (jobs, batch) | ✅ **IPAM dinámico** | Sin `"ips"` en anotación |
| Lab donde las IPs exactas no importan | ✅ **IPAM dinámico** | Configuración mínima |
| IPs estables para tests repetibles | ⚠️ Limitado | IPAM asigna IPs predecibles en orden de creación, no estables entre reinicios totales |
| Múltiples subredes `10.x.x.x` con MACs únicas | `mac_ip_encoding: true` (variable-length) | Sin colisiones entre VLANs |
| MACs aleatorios (privacidad) | `mac_ip_encoding: false` | Genera MAC random por pod |

## Solución usada en `l2-attacks-01` (lab funcional)

### NADs del lab

```yaml
# Sin "ips" en anotaciones — IPAM dinámico estándar
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: lab-l2-attacks-01-ovn-vlan10
  namespace: user-superadmin
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "ovn-k8s-cni-overlay",
      "topology": "layer2",
      "subnets": "10.10.10.0/24",
      "name": "lab-l2-attacks-01-vlan10",
      "netAttachDefName": "user-superadmin/lab-l2-attacks-01-ovn-vlan10"
    }
```

### Pods del lab (sin `"ips"` en anotación)

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {"name": "lab-l2-attacks-01-ovn-vlan10", "interface": "net1"}
      ]
```

### Resultados verificados

| IP real (asignada por IPAM) | Pod |
|------------------------------|-----|
| 10.10.10.18 | victim-hr-1 (nervous-vaughan) |
| 10.10.10.6 | victim-hr-2 (funny-einstein) |
| 10.10.10.15 | kali-attack (nervous-vaughan) |
| 10.10.20.6 | victim-fin (nervous-vaughan) |
| 10.10.30.2 | victim-mgmt (funny-einstein) |
| 10.10.99.8 | kali-attack (trunk, nervous-vaughan) |

Las IPs fueron asignadas por IPAM en orden de creación del pod. No se coordinaron manualmente.

## Compatibilidad con KubeVirt

Para máquinas virtuales KubeVirt, el patrón recomendado es:

1. Configurar la NAD con IPAM dinámico (sin `"ips"` en anotación de la VM)
2. KubeVirt asigna la interfaz secundaria al pod `virt-launcher`
3. OVN-K asigna la IP al `virt-launcher`
4. La VM ve la MAC de la interfaz derivada de la IP vía MAC encoding
5. Cloud-init (shell script) lee la MAC dentro del guest y configura la IP estática — coincide exactamente con la que OVN-K asignó

```yaml
# VirtualMachine spec — sin "ips" en network interfaces
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: |
          [{"name": "lab-net-vlan10", "interface": "net1"}]
  # ... cloudInitNoCloud con shell script que lee MAC
```

## Referencias

- `D:\HackCTF\Vms\LAB_l2-attacks-01_VERIFICACION.md` §7.1 — Error original del timeout con `"ips"`
- `D:\HackCTF\Vms\PLAYBOOK_NETWORK_FUNCTIONS_L2_ATTACKS.md` §11.7 — Implementación real OVN-K
- `D:\HackCTF\Vms\images\l2-attacks-01-ovn-nads.yaml` — NADs funcionales (IPAM dinámico)
- `D:\HackCTF\Vms\images\l2-ovn-victim-hr-1.yaml` — Pod sin `"ips"` (correcto)
