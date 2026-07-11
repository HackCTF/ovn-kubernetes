package util

import (
	"net"
	"testing"
)

func TestEncodeMACFromIP_24(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")

	mac, err := EncodeMACFromIP(ip, subnet)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	expected := "0a:58:18:0a:0a:63"
	if mac.String() != expected {
		t.Fatalf("expected %s, got %s", expected, mac.String())
	}
}

func TestEncodeMACFromIP_16(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.0.0/16")

	mac, err := EncodeMACFromIP(ip, subnet)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	expected := "0a:58:10:0a:0a:63"
	if mac.String() != expected {
		t.Fatalf("expected %s, got %s", expected, mac.String())
	}
}

func TestEncodeMACFromIP_25(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/25")

	mac, err := EncodeMACFromIP(ip, subnet)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// /25: 9 subnet bits beyond /16 + 7 host bits, packed into 24 bits value
	// For 10.10.10.0/25: subnetPart = 0x140, hostPart = 0x63, value24 = 0xa063
	expected := "0a:58:19:0a:0a:63"
	if mac.String() != expected {
		t.Fatalf("expected %s, got %s", expected, mac.String())
	}
}

func TestEncodeMACFromIP_UnsupportedPrefix(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.0.0.0/8")

	_, err := EncodeMACFromIP(ip, subnet)
	if err == nil {
		t.Fatal("expected error for /8 prefix, got nil")
	}
}

func TestEncodeMACFromIP_IPv6Rejected(t *testing.T) {
	ip := net.ParseIP("::1")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")

	_, err := EncodeMACFromIP(ip, subnet)
	if err == nil {
		t.Fatal("expected error for IPv6, got nil")
	}
}

func TestDecodeIPFromMAC_Roundtrip24(t *testing.T) {
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")
	ip := net.ParseIP("10.10.10.99")

	mac, err := EncodeMACFromIP(ip, subnet)
	if err != nil {
		t.Fatalf("encode failed: %v", err)
	}
	decoded, err := DecodeIPFromMAC(mac, subnet)
	if err != nil {
		t.Fatalf("decode failed: %v", err)
	}
	if !decoded.Equal(ip) {
		t.Fatalf("roundtrip mismatch: encoded %s, decoded %s", ip, decoded)
	}
}

func TestDecodeIPFromMAC_WrongPrefix(t *testing.T) {
	mac, _ := net.ParseMAC("0a:58:18:0a:0a:63")
	_, subnet16, _ := net.ParseCIDR("10.10.0.0/16")

	_, err := DecodeIPFromMAC(mac, subnet16)
	if err == nil {
		t.Fatal("expected error for mismatched prefix indicator, got nil")
	}
}

func TestDecodeIPFromMAC_NonOvnOUI(t *testing.T) {
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")
	mac, _ := net.ParseMAC("aa:bb:cc:dd:ee:ff")

	_, err := DecodeIPFromMAC(mac, subnet)
	if err == nil {
		t.Fatal("expected error for non-OVN OUI, got nil")
	}
}

func TestResolveMAC_Explicit(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")

	mac, err := ResolveMAC(ip, subnet, true, "aa:bb:cc:dd:ee:ff")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if mac.String() != "aa:bb:cc:dd:ee:ff" {
		t.Fatalf("expected aa:bb:cc:dd:ee:ff, got %s", mac)
	}
}

func TestResolveMAC_EncodingEnabled_24(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")

	mac, err := ResolveMAC(ip, subnet, true, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	expected := "0a:58:18:0a:0a:63"
	if mac.String() != expected {
		t.Fatalf("expected %s, got %s", expected, mac)
	}
}

func TestResolveMAC_EncodingDisabled(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")

	mac, err := ResolveMAC(ip, subnet, false, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Verify it's NOT the encoded form (different MAC each call due to randomness)
	expected := "0a:58:18:0a:0a:63"
	if mac.String() == expected {
		t.Fatalf("expected random MAC, got encoded %s", mac)
	}
	// Verify unicast + locally-administered bits are set (per GenerateRandMAC)
	if mac[0]&0x01 != 0 {
		t.Fatalf("multicast bit should be 0, got %02x", mac[0])
	}
	if mac[0]&0x02 == 0 {
		t.Fatalf("locally-administered bit should be 1, got %02x", mac[0])
	}
}

func TestResolveMAC_EncodingEnabled_Fallback8(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.0.0.0/8")

	mac, err := ResolveMAC(ip, subnet, true, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	expected := "0a:58:0a:0a:0a:63"
	if mac.String() != expected {
		t.Fatalf("expected %s (legacy fallback), got %s", expected, mac)
	}
}

func TestResolveMAC_InvalidExplicit(t *testing.T) {
	ip := net.ParseIP("10.10.10.99")
	_, subnet, _ := net.ParseCIDR("10.10.10.0/24")

	_, err := ResolveMAC(ip, subnet, true, "not-a-mac")
	if err == nil {
		t.Fatal("expected error for invalid MAC, got nil")
	}
}