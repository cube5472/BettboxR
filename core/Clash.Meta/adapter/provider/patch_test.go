package provider

import (
	"testing"
)

// Одна невалидная запись в подписке не должна ронять весь провайдер:
// битые прокси пропускаются, остальные загружаются.
func TestSkipInvalidProxies(t *testing.T) {
	sub := []byte(`proxies:
  - name: ok1
    type: ss
    server: 1.2.3.4
    port: 443
    cipher: aes-128-gcm
    password: pass
  - name: bad-cipher
    type: ss
    server: 1.2.3.4
    port: 443
    cipher: not-a-real-cipher
    password: pass
  - name: bad-port
    type: ss
    server: 1.2.3.4
    port: not-a-port
    cipher: aes-128-gcm
    password: pass
  - name: ok2
    type: ss
    server: 5.6.7.8
    port: 8388
    cipher: chacha20-ietf-poly1305
    password: pass
`)

	parser, err := NewProxiesParser("test", nil, "", "", "", "", overrideSchema{}, "")
	if err != nil {
		t.Fatalf("NewProxiesParser: %v", err)
	}
	proxies, err := parser(sub)
	if err != nil {
		t.Fatalf("parse failed (invalid entries must be skipped, not fatal): %v", err)
	}
	if len(proxies) != 2 {
		t.Fatalf("want 2 valid proxies, got %d", len(proxies))
	}
}

// YAML/JSON без ключа proxies, но с share-ссылками внутри: раньше
// провайдер умирал с "file must have a `proxies` field", теперь
// срабатывает fallback на парсер share-ссылок.
func TestFallbackToShareLinksWhenNoProxiesKey(t *testing.T) {
	sub := []byte(`update: 2026-01-01
notice: привет
vless://uuid1@1.1.1.1:443#Нода-1
vless://uuid2@2.2.2.2:443#Нода-2
`)

	parser, err := NewProxiesParser("test", nil, "", "", "", "", overrideSchema{}, "")
	if err != nil {
		t.Fatalf("NewProxiesParser: %v", err)
	}
	proxies, err := parser(sub)
	if err != nil {
		t.Fatalf("fallback failed: %v", err)
	}
	if len(proxies) != 2 {
		t.Fatalf("want 2 proxies from fallback, got %d", len(proxies))
	}
}

// Маппинг без proxies и без ссылок — внятная ошибка, а не паника.
func TestNoProxiesStillErrors(t *testing.T) {
	sub := []byte(`update: 2026-01-01
notice: привет
`)

	parser, err := NewProxiesParser("test", nil, "", "", "", "", overrideSchema{}, "")
	if err != nil {
		t.Fatalf("NewProxiesParser: %v", err)
	}
	if _, err := parser(sub); err == nil {
		t.Fatal("expected error for content without proxies/links")
	}
}

// Текстовый список ссылок (типичный формат v2ray-подписок): раньше
// терялся, если случайно был валидным YAML-скаляром; теперь парсится.
func TestPlainTextSubscription(t *testing.T) {
	sub := []byte("#announce: привет\n" +
		"#profile-title: test\n" +
		"vless://uuid1@1.1.1.1:443?security=reality&sni=x.com&pbk=JqmkP6Fys7jN2Fu1iDJuWKVNPhlgHfy_pj1DHFVKVhw#Россия\n" +
		"vless://uuid2@2.2.2.2:443?type=ws#Россия\n" +
		"ss://YWVzLTI1Ni1nY206cGFzcw@3.3.3.3:8388#США\n" +
		"hysteria2://pass@4.4.4.4:443#Германия\n")

	parser, err := NewProxiesParser("test", nil, "", "", "", "", overrideSchema{}, "")
	if err != nil {
		t.Fatalf("NewProxiesParser: %v", err)
	}
	proxies, err := parser(sub)
	if err != nil {
		t.Fatalf("plain text subscription failed: %v", err)
	}
	if len(proxies) != 4 {
		t.Fatalf("want 4 proxies, got %d", len(proxies))
	}
}
