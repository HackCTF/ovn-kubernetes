# Codificación MAC/IP para redes OVN-K Layer 2

## Descripción general

Por defecto, OVN-K obtiene la dirección MAC de un pod de forma determinista a partir de su
dirección IPv4 asignada. Esto funciona bien para máquinas virtuales que leen su propia IP
desde la MAC de la interfaz (por ejemplo, Cirros sin DHCP funcional).

Para laboratorios multi-tenant donde múltiples NADs comparten el espacio de direcciones
`10.x.x.x`, la codificación por defecto puede causar colisiones MAC entre subredes. Esta
funcionalidad agrega un toggle a nivel de NAD para controlar la codificación de forma explícita.

## Configuración

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

## Valores

| Valor | Comportamiento |
|-------|----------------|
| `true` | Codificación activada. Subredes `/16-/32` usan codificación de longitud variable (sin colisiones). `/8-/15` usan el método heredado `IPAddrToHWAddr`. |
| `false` | Codificación desactivada. MAC aleatorio por pod (`GenerateRandMAC`). El OUI `0a:58` se mantiene. |
| _(omitido)_ | Por defecto: codificación activada (preserva el comportamiento anterior). |

## Precedencia

La anotación `MacRequest` del pod **siempre tiene prioridad** sobre el toggle del NAD:

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"lab-net","mac":"aa:bb:cc:dd:ee:ff"}]'
```

Este pod obtendrá `aa:bb:cc:dd:ee:ff` independientemente de `mac_ip_encoding`.

## Formato de codificación (cuando está activada)

Codificación de longitud variable (`EncodeMACFromIP`):

```
MAC[0:2] = 0a:58                       (OUI de OVN-K)
MAC[2]   = 0x10 + (prefijo - 16)       (indicador de longitud de prefijo)
MAC[3:6] = bits_subred << bits_host | bits_host_del_IP
```

Ejemplos:

| Subred | IP | MAC |
|--------|-----|-----|
| `10.10.10.0/24` | `10.10.10.99` | `0a:58:18:0a:0a:63` |
| `10.10.0.0/16` | `10.10.10.99` | `0a:58:10:0a:0a:63` |
| `10.10.10.0/25` | `10.10.10.99` | `0a:58:19:00:0a:63` |

El indicador de prefijo (`MAC[2]`) previene colisiones: un pod en `/16` obtiene
el indicador `0x10`, mientras que uno en `/24` obtiene `0x18`. Misma IP, MAC diferente.

Para subredes más pequeñas que `/16` (por ejemplo, `/8`), el toggle funciona pero usa
la codificación heredada `IPAddrToHWAddr` (que asume `/32`).

## Limitaciones

- Prefijos soportados para codificación de longitud variable: `/16` a `/32`. Prefijos
  más pequeños usan codificación heredada.
- IPv6 no está soportado (rango OUI separado, fuera de alcance).
- Laboratorios existentes sin el campo configurado se comportan exactamente igual —
  no se necesita migración.

## Cuándo desactivar la codificación

- Laboratorios multi-tenant donde la unicidad MAC es más importante que la autoconfiguración
- Pods que necesitan aparecer como hosts físicos separados (MAC diferentes)
- Escenarios de cumplimiento donde los MACs determinísticos son una preocupación de privacidad

## Cuándo mantener la codificación activada

- Máquinas virtuales que leen su IP desde la MAC (Cirros, distribuciones Linux antiguas)
- Laboratorios donde la reproducibilidad importa (misma IP → mismo MAC entre recreaciones)
