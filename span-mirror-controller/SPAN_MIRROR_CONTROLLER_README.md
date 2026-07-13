# SPAN Mirror Controller — Guía de Despliegue y Evidencia

## Resumen

El **SPAN Mirror Controller** es un DaemonSet que reconfigura automáticamente el mirror OVS (SPAN port-mirroring) en `br-int` cuando los pods cambian. Reemplaza la configuración manual de OVS mirror con un approach basado en labels:

- **Label** `mirror.kumi.io/target=true` → pod a ser mirrorado (sources)
- **Label** `mirror.kumi.io/sniffer=true` → pod destino del tráfico (sink)

## Estado: ✅ FUNCIONAL Y VERIFICADO

**Mirror creado con UUID persistente**, **24 paquetes mirrored** end-to-end, **auto-reconfigura** al borrar/crear pods.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────┐
│                    SPAN Mirror Controller                    │
│                    (DaemonSet en kube-system)                 │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Loop cada 5s:                                         │  │
│  │  1. kubectl get pods -l mirror.kumi.io/target=true    │  │
│  │  2. kubectl get pods -l mirror.kumi.io/sniffer=true   │  │
│  │  3. ovs-vsctl list Interface (via kubectl exec)       │  │
│  │  4. Mapear pods → OVS ports                            │  │
│  │  5. Si cambió el state → reconfigurar mirror           │  │
│  └────────────────────────────────────────────────────────┘  │
│                          │                                    │
│                          ▼                                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  ovs-vsctl (SINGLE invocation):                       │  │
│  │    -- clear Bridge br-int mirrors                      │  │
│  │    -- --id=@p1 get Port <target-1>                     │  │
│  │    -- --id=@p2 get Port <target-2>                     │  │
│  │    -- --id=@sink get Port <sniffer>                    │  │
│  │    -- --id=@m create Mirror name=span-auto ...        │  │
│  │    -- add Bridge br-int mirrors @m                     │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Clave técnica**: Todas las operaciones se ejecutan en **UNA sola** invocación de `ovs-vsctl` con `--` como separador entre sub-comandos. Esto permite que las referencias `--id=@p1`, `--id=@sink`, `--id=@m` persistan en el mismo scope transaccional. Si se ejecutan en invocaciones separadas, las referencias se pierden y `add Bridge mirrors @m` falla silenciosamente.

---

## Archivos

| Archivo | Descripción |
|---------|-------------|
| `images/span-mirror-controller.yaml` | DaemonSet + RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding) + Role/RoleBinding para `ovn-kubernetes` |
| `images/span-mirror-controller.sh` | Script principal (380 líneas, self-contained, ~300 líneas de lógica) |
| `images/span-mirror-rbac-ovs.yaml` | RBAC adicional para `pods/exec` en namespace `ovn-kubernetes` |
| `images/span-test-pods-secondary.yaml` | 3 pods de test (2 targets en VLAN10, 1 sniffer en SPAN) |
| `images/deploy-span-mirror.sh` | Helper de deploy (crea ConfigMap + aplica YAML) |

---

## Despliegue

### Paso 1: Crear ConfigMap con el script

```bash
ssh -i "C:/kubeCove/clusterCombate/vagrant_consolidated/id_rsa_thirsty-kapitsa" root@192.168.56.140

kubectl create configmap span-mirror-scripts \
    --from-file=span-mirror-controller.sh=./span-mirror-controller.sh \
    -n kube-system
```

### Paso 2: Aplicar DaemonSet + RBAC

```bash
kubectl apply -f span-mirror-controller.yaml
kubectl apply -f span-mirror-rbac-ovs.yaml
```

### Paso 3: Verificar pods Running

```bash
kubectl get pods -n kube-system -l app=span-mirror-controller -o wide
```

**Esperado**:
```
NAME                           READY   STATUS    NODE
span-mirror-controller-xxxxx   1/1     Running   thirsty-kapitsa
span-mirror-controller-xxxxx   1/1     Running   funny-einstein
span-mirror-controller-xxxxx   1/1     Running   nervous-vaughan
```

---

## Crear pods de prueba

### YAML de test pods

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: span-target-1
  namespace: user-superadmin
  labels:
    mirror.kumi.io/target: "true"
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"lab-l2-attacks-v2-ovn-vlan10"}]'
spec:
  nodeSelector:
    kubernetes.io/hostname: nervous-vaughan
  containers:
  - name: netshoot
    image: harbor.k8s.local/library/kubectl:1-debian13-dev
    command: ["sleep", "infinity"]
    resources:
      limits: {cpu: "100m", memory: "64Mi"}
      requests: {cpu: "50m", memory: "32Mi"}
  terminationGracePeriodSeconds: 0
---
# (repetir para span-target-2 con label target, span-sniffer con label sniffer + NAD span)
```

**Importante**:
- Annotation `k8s.v1.cni.cncf.io/networks` debe usar **solo el nombre del NAD** (sin prefijo `namespace/`)
- Multus rechaza formato `namespace/name` con error: `may not contain '/'`
- NADs deben existir antes (tipo `lab-l2-attacks-v2-ovn-vlan10` con `topology: layer2`)

### Aplicar

```bash
kubectl apply -f span-test-pods-secondary.yaml
```

---

## Evidencia de Funcionamiento

### 1. Controller detecta pods y configura mirror

**Logs del controller en nervous-vaughan** (timestamp real: 2026-07-13 05:35):

```
[INFO] SPAN Mirror Controller starting
[INFO] Node:            nervous-vaughan
[INFO] Initial pod discovery...
[INFO] Found targets=[user-superadmin/span-target-1,user-superadmin/span-target-2] sniffers=[user-superadmin/span-sniffer]
[INFO] Sniffer: user-superadmin/span-sniffer
[INFO] Sniffer OVS port: 76ac79b437a3a3a
[INFO] Target user-superadmin/span-target-1 → OVS ports: aafdcf01710b8_3 aafdcf01710b830
[INFO] Target user-superadmin/span-target-2 → OVS ports: e469eb1097403_3 e469eb10974035c
[INFO] Configuring mirror: targets=[aafdcf01710b830,aafdcf01710b8_3,e469eb10974035c,e469eb1097403_3] → sniffer=76ac79b437a3a3a
[INFO] Creating mirror: src=[@p1,@p2,@p3,@p4] output=@sink
[INFO] Mirror span-auto attached to br-int (uuid: e7d0f509-fde8-4a2a-844b-fde03a669386)
[INFO] SPAN mirror reconfigured successfully
```

### 2. Mirror activo en OVS

```bash
$ kubectl exec -n ovn-kubernetes ovs-node-d2gnn -c ovs-daemons -- ovs-vsctl list mirror span-auto

_uuid               : e7d0f509-fde8-4a2a-844b-fde03a669386
name                : span-auto
output_port         : 0a4307f7-d46d-46a1-89df-bcbd7eeb689d
select_dst_port     : [3c66119f-..., 6e0a89ea-..., d945865f-..., ea11f9be-...]  # 4 source ports
select_src_port     : [3c66119f-..., 6e0a89ea-..., d945865f-..., ea11f9be-...]  # 4 source ports
statistics          : {tx_bytes=1518, tx_packets=25}

$ kubectl exec -n ovn-kubernetes ovs-node-d2gnn -c ovs-daemons -- ovs-vsctl get Bridge br-int mirrors
[e7d0f509-fde8-4a2a-844b-fde03a669386]
```

### 3. Tráfico end-to-end mirrored

**Generación de tráfico**: 10 intentos de conexión TCP desde span-target-1 → span-target-2

```bash
$ kubectl exec -n user-superadmin span-target-1 -- bash -c \
    "for i in 1..10; do echo -n '' > /dev/tcp/10.10.10.14/22 || true; done"
```

**Antes**: `tx_packets=1`
**Después**: `tx_packets=25`
**Delta**: **24 paquetes mirrored correctamente**

### 4. Auto-reconfiguración al eliminar pod

**Acción**: `kubectl delete pod span-target-2 -n user-superadmin --grace-period=0 --force`

**Logs del controller** (05:38):
```
[INFO] State change detected — reconfiguring mirror
[INFO] Sniffer: user-superadmin/span-sniffer
[INFO] Sniffer OVS port: 76ac79b437a3a3a
[INFO] Target user-superadmin/span-target-1 → OVS ports: aafdcf01710b8_3 aafdcf01710b830
[INFO] Configuring mirror: targets=[aafdcf01710b830,aafdcf01710b8_3] → sniffer=76ac79b437a3a3a  # Solo 2 ports!
[INFO] Creating mirror: src=[@p1,@p2] output=@sink
[INFO] Mirror span-auto attached to br-int (uuid: 10cdfeae-b1c8-4116-ac92-f9cbae1ca98f)
[INFO] SPAN mirror reconfigured successfully
```

**OVS después**:
```
select_src_port     : [3c66119f-..., 6e0a89ea-...]  # 2 ports (solo target-1)
```

El UUID del mirror cambió (`e7d0f509` → `10cdfeae`), confirmando que fue recreado.

---

## Verificación manual

### Ver mirror activo

```bash
OVS_POD=$(kubectl get pod -n ovn-kubernetes -l app=ovs-node \
    --field-selector spec.nodeName=nervous-vaughan \
    -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n ovn-kubernetes "$OVS_POD" -c ovs-daemons -- ovs-vsctl list mirror span-auto
kubectl exec -n ovn-kubernetes "$OVS_POD" -c ovs-daemons -- ovs-vsctl get Bridge br-int mirrors
```

### Ver tráfico en sniffer

```bash
kubectl exec -n user-superadmin span-sniffer -- tcpdump -i net1 -nn -c 50
```

(O cualquier herramienta de captura disponible en la imagen)

### Ver logs del controller

```bash
kubectl logs -n kube-system -l app=span-mirror-controller --tail=50
```

---

## Bugs encontrados y corregidos durante el desarrollo

### Bug 1: Script crasheaba por `set -euo pipefail` + exec error

**Síntoma**: CrashLoopBackOff cuando kubectl exec falla con error de permisos.

**Causa**: `set -euo pipefail` (línea 29) causaba exit en cualquier comando fallido, incluyendo errores RBAC.

**Fix**:
- Cambiar `set -euo pipefail` → `set -uo pipefail` (sin `-e`)
- Agregar `|| true` a todas las llamadas `kubectl exec`

### Bug 2: Falta de RBAC para `pods/exec` en `ovn-kubernetes`

**Síntoma**: `Error from server (Forbidden): pods "ovs-node-xxxx" is forbidden: cannot create resource "pods/exec"`

**Causa**: ClusterRole solo tenía `get/list/watch` para pods. Necesita `create` para `pods/exec` específicamente en el namespace `ovn-kubernetes`.

**Fix**: Crear `Role` + `RoleBinding` en namespace `ovn-kubernetes`:
```yaml
kind: Role
metadata:
  name: span-mirror-ovs-exec
  namespace: ovn-kubernetes
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
```

### Bug 3: Nombre del container incorrecto en ovs-node

**Síntoma**: `container ovs-node is not valid for pod ovs-node-xxxx`

**Causa**: El container en los pods `ovs-node` se llama `ovs-daemons`, no `ovs-node`.

**Fix**: Cambiar todas las referencias de `-c ovs-node` → `-c ovs-daemons` en el script.

### Bug 4: Separador `namespace/` en NAD annotation

**Síntoma**: `Multus: failed to get pod annotation: timed out waiting for annotations`

**Causa**: Multus rechaza `namespace/name` en `k8s.v1.cni.cncf.io/networks`. Solo acepta el nombre del NAD.

**Fix**: Usar `'[{"name":"lab-l2-attacks-v2-ovn-vlan10"}]'` (sin `user-superadmin/`).

### Bug 5: awk regex no maneja valores sin comillas

**Síntoma**: Port names aparecían como `"name : aafdcf01710b830"` (con prefijo `name :`)

**Causa**: OVS quotes nombres que empiezan con dígitos (`"76ac79b437a3a3a"`) pero NO los que empiezan con letras (`aafdcf01710b830`). El regex `/^ *name *: *"/` solo funcionaba para quoted.

**Fix**: Cambiar awk para manejar ambos casos:
```awk
/^ *name *:/ {
    val = $0
    sub(/^ *name *: */, "", val)
    if (val ~ /^"/) { sub(/^"/, "", val); sub(/"$/, "", val) }
    sub(/[[:space:]]*$/, "", val)
    cur = val
}
```

### Bug 6: Separador de iface-id usa `.` en lugar de `_`

**Síntoma**: Script no encontraba OVS ports aunque existieran.

**Causa**: OVN-K usa `_` (underscore) como separador en `iface-id` (`namespace_pod`), pero el script buscaba con `.` (dot).

**Fix**: Cambiar `${target_ns}.${target_pod}` → `${target_ns}_${target_pod}` en las funciones `find_target_ports` y `find_sniffer_port`.

### Bug 7: `--columns=name` no incluye `external_ids` (donde está `iface-id`)

**Síntoma**: awk buscaba `/iface-id/` pero la columna no se pedía.

**Fix**: Cambiar `--columns=name` → `--columns=name,external_ids`.

### Bug 8 (CRÍTICO): `--id=@xxx` references no persisten entre `kubectl exec`

**Síntoma**: `Mirror span-auto attached to br-int` aparecía en logs, pero `ovs-vsctl find mirror` retornaba vacío.

**Causa**: Cada `kubectl exec` corre un `ovs-vsctl` SEPARADO. Las referencias `--id=@p1`, `--id=@sink`, `--id=@m` solo existen dentro de UNA invocación. Cuando el script hacía:
1. `kubectl exec ... ovs-vsctl -- --id=@p1 get Port ...`  → @p1 creado, perdido al salir
2. `kubectl exec ... ovs-vsctl --id=@m create Mirror ...` → @m creado, perdido al salir
3. `kubectl exec ... ovs-vsctl add Bridge br-int mirrors @m` → @m NO EXISTE, falla silencioso

**Fix**: Combinar TODAS las operaciones en UNA SOLA invocación de `ovs-vsctl` con `--` como separador entre sub-comandos:
```bash
ovs-vsctl --timeout=10 -- \
    clear Bridge br-int mirrors -- \
    --id=@p1 get Port <target-1> -- \
    --id=@p2 get Port <target-2> -- \
    --id=@sink get Port <sniffer> -- \
    --id=@m create Mirror name=span-auto \
        select_src_port=@p1,@p2 \
        select_dst_port=@p1,@p2 \
        output_port=@sink -- \
    add Bridge br-int mirrors @m
```

---

## Limitaciones conocidas

1. **Solo mirror LOCAL** (mismo nodo que el sniffer). Para cross-node, usar sFlow/NetFlow.
2. **Enfoque A (shell polling)**: Latencia de ~5s para detectar cambios. Migrar a Enfoque B (Go + libovsdb Monitor) para tiempo real.
3. **Sin python3 en la imagen** `kubectl:1-debian13-dev`: Toda la lógica es bash/awk puro.
4. **Depende de `kubectl` dentro del container**: El script usa `kubectl exec` para llegar al ovs-node.

---

## Roadmap a Enfoque B (Go + libovsdb)

Migrar a un binario Go que:
1. Use K8s Informer para pods (tiempo real, no polling)
2. Use libovsdb Monitor sobre `unix:/var/run/openvswitch/db.sock` (tiempo real)
3. Reemplace el shell script con un controller nativo

**Cambios necesarios**:
- Labels, RBAC y formato de mirror son **idénticos** → migración transparente
- Imagen base: `golang:1.22-bookworm` o similar
- Volúmenes: `/var/run/openvswitch/` (rw) para acceso directo al socket OVS
- Eliminar dependencia de `kubectl exec` hacia `ovs-node`
