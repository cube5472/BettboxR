package convert

import (
	"bytes"
	"encoding/base64"
	"testing"
)

// Подписка в URL-safe base64 (алфавит '-'/'_') должна декодироваться.
func TestDecodeBase64URLSafe(t *testing.T) {
	plain := "vless://uuid@example.com:443?security=reality#node"
	std := []byte(base64.StdEncoding.EncodeToString([]byte(plain)))
	urlSafe := bytes.ReplaceAll(bytes.ReplaceAll(std, []byte("+"), []byte("-")), []byte("/"), []byte("_"))

	if got := DecodeBase64(urlSafe); string(got) != plain {
		t.Fatalf("urlsafe base64 not decoded: got %q want %q", got, plain)
	}
	if got := DecodeBase64(std); string(got) != plain {
		t.Fatalf("std base64 broken: got %q want %q", got, plain)
	}
	if got := DecodeBase64([]byte(plain)); string(got) != plain {
		t.Fatalf("plain text must pass through: got %q", got)
	}
}

// Текстовый список share-ссылок с дублирующимися именами: каждая ссылка
// должна распарситься, дубликаты имён — уникализироваться.
func TestConvertsV2RayDuplicateNames(t *testing.T) {
	sub := "vless://uuid1@1.1.1.1:443#Россия\n" +
		"vless://uuid2@2.2.2.2:443#Россия\n" +
		"vless://uuid3@3.3.3.3:443#Россия\n" +
		"ss://YWVzLTI1Ni1nY206cGFzcw@4.4.4.4:8388#США\n" +
		"hysteria2://pass@5.5.5.5:443#США\n" +
		"# комментарий без ссылки\n" +
		"мусорная строка без схемы\n"

	proxies, err := ConvertsV2Ray([]byte(sub))
	if err != nil {
		t.Fatalf("ConvertsV2Ray: %v", err)
	}
	if len(proxies) != 5 {
		t.Fatalf("want 5 proxies, got %d", len(proxies))
	}
	names := map[string]bool{}
	for _, p := range proxies {
		n, _ := p["name"].(string)
		if names[n] {
			t.Fatalf("duplicate name after uniquify: %q", n)
		}
		names[n] = true
	}
	if !names["Россия"] || !names["Россия-01"] || !names["Россия-02"] {
		t.Fatalf("expected uniquified names, got %v", names)
	}
}
