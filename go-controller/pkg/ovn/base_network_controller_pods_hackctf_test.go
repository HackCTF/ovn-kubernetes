package ovn

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestStaticIPMatchKey covers the HackCTF static-IP match key: the
// kumi.io/static-ip-key label wins (identical on containers and VMIs), then the
// KubeVirt VM name, then the pod name. See base_network_controller_pods.go.
func TestStaticIPMatchKey(t *testing.T) {
	podWith := func(name string, labels map[string]string) *corev1.Pod {
		return &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "user-x", Labels: labels},
		}
	}

	tests := []struct {
		name    string
		pod     *corev1.Pod
		wantKey string
		wantVia string
	}{
		{
			name:    "label takes precedence over vm name and pod name",
			pod:     podWith("virt-launcher-d-abc-xyz", map[string]string{"kumi.io/static-ip-key": "d-abc", "vm.kubevirt.io/name": "d-abc"}),
			wantKey: "d-abc",
			wantVia: "label",
		},
		{
			name:    "vm name fallback when label absent (VM pod, random name)",
			pod:     podWith("virt-launcher-d-abc-xyz", map[string]string{"vm.kubevirt.io/name": "d-abc"}),
			wantKey: "d-abc",
			wantVia: "vm",
		},
		{
			name:    "pod name default (plain container, no labels)",
			pod:     podWith("d-abc-0", nil),
			wantKey: "d-abc-0",
			wantVia: "pod",
		},
		{
			name:    "empty label is ignored, falls through to pod name",
			pod:     podWith("d-abc-0", map[string]string{"kumi.io/static-ip-key": ""}),
			wantKey: "d-abc-0",
			wantVia: "pod",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			key, via := staticIPMatchKey(tt.pod)
			if key != tt.wantKey || via != tt.wantVia {
				t.Errorf("staticIPMatchKey() = (%q, %q), want (%q, %q)", key, via, tt.wantKey, tt.wantVia)
			}
		})
	}
}
