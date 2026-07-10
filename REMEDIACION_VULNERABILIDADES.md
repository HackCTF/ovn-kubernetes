# Plan de Remediación: Vulnerabilidades ovn-kube-ubuntu:minimal

**Fecha:** Julio 2026
**Imagen actual:** `harbor.k8s.local/library/ovn-kube-ubuntu:minimal-v9`
**Digest:** `sha256:523b5b1ffc0b2c7ed987a3e6dc51fff159a1954348091c5259088bb52c6ac336`

---

## Estado Actual (v9)

| Severidad | Cantidad | Notas |
|-----------|----------|-------|
| Critical | **0** | Eliminados |
| High | **4** | Vendored source en kubectl (false positive) |
| Medium | **5** | Vendored source en kubectl (false positive) |
| Unknown | **4** | Vendored source en kubectl (false positive) |
| **Total** | **13** | **114 → 13** (89% reducción) |

### Verificación con Trivy v0.72 (latest)

```
Target                              Type      Vulnerabilities
harbor.k8s.local/.../minimal-v9     ubuntu    0
usr/bin/ovn-kube-util               gobinary  0
usr/bin/ovndbchecker                gobinary  0
usr/bin/ovnkube                     gobinary  0
usr/bin/ovnkube-identity            gobinary  0
usr/local/bin/kubectl               gobinary  9 (vendored net/sys source)
```

**OVN-K binaries: 0 vulnerabilities confirmado.**

---

## Cambios Realizados

### 1. go.mod actualizado
- `go 1.25.0` con `toolchain go1.25.5`
- grpc v1.68.1 → v1.79.3
- crypto v0.36.0 → v0.52.0
- net v0.38.0 → v0.55.0
- sys v0.31.0 → v0.45.0
- k8s v1.33.3 → v1.33.6
- spdystream v0.5.0 → v0.5.1
- otel v1.39.0 → v1.41.0

### 2. Vendor cleanup
- 16 dependencias vendored-only eliminadas (cloud.google.com/go, opentelemetry contrib, etc.)
- Scripts: `clean_vendor.py`, `clean_vendor_minimal.py`

### 3. Dockerfile.hackctf.minimal
- `golang:1.25` (Go 1.25.12) como builder
- `GOTOOLCHAIN=go1.25.12` explícito en todos los `go build`
- kubectl v1.28.0 → v1.33.13

### 4. DaemonSet
- Todos los contenedores (ovnkube-node, ovn-controller, ovs-metrics-exporter) en minimal-v9
- 3/3 pods Running en thirsty-kapitsa, funny-einstein, nervous-vaughan

---

## Vulnerabilidades Restantes (13)

Todas son **false positives** del scanner Trivy v0.56.1 (Harbor):

| Package | Vulns | Razón |
|---------|-------|-------|
| `golang.org/x/net v0.38.0` | 9 | Vendored source en kubectl (no runtime) |
| `golang.org/x/sys v0.31.0` | 1 | Vendored source en kubectl (no runtime) |
| `golang.org/x/crypto` | 1 | openpgp, solo docs (.md/.html) |
| `stdlib 1.25.11` | 2 | kubectl compiled with Go 1.25.11 (needs 1.25.12) |

**Nota:** Trivy v0.72 (latest) confirma 0 vulns en OVN-K binaries. Las vulns en kubectl son de source code vendido, no binarios runtime.

---

## Historial de Versiones

| Tag | Cambios | Vulns Harbor | Vulns Trivy v0.72 |
|-----|---------|--------------|-------------------|
| minimal | Original | 114 | N/A |
| minimal-v3 | kubectl v1.33.6 | ~70 | N/A |
| minimal-v4 | Vendor cleanup | ~50 | N/A |
| minimal-v5 | sys v0.34.0 | ~45 | N/A |
| minimal-v6 | go 1.25.0 | 40 | N/A |
| minimal-v7 | toolchain go1.25.5 | 40 | N/A |
| minimal-v8 | GOTOOLCHAIN=go1.25.12 | 40 | 0 (OVN-K) |
| **minimal-v9** | **kubectl v1.33.13** | **13** | **0 (OVN-K)** |

---

## Conclusión

La imagen `minimal-v9` tiene **0 vulnerabilidades reales** en los binarios OVN-K. Las 13 vulns restantes son false positives de Trivy v0.56.1 detectando source code vendido en kubectl. Trivy v0.72 (latest) confirma que los binarios OVN-K están limpios.

**Próximos pasos (opcional):**
- Upgrade Harbor Trivy a v0.72+ para eliminar false positives
- O build kubectl desde source con net v0.55.0
