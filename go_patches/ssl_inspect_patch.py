#!/usr/bin/env python3
"""
Patch itun2socks with SSL bumping detection + CA cert endpoints.
"""
import os

ITUN = os.path.expanduser('~/itun2socks')

def write(rel_path, content):
    full = os.path.join(ITUN, rel_path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w') as f:
        f.write(content)
    print(f'  wrote {rel_path}')

# ── 1. SSL bump detector ───────────────────────────────────────────────────────
write('internal/ssl_inspect/detect.go', r"""package ssl_inspect

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"net"
	"time"
)

const (
	probeHost = "captive.apple.com"
	probePort = "443"
)

// BumpStatus is the result of an SSL-bump detection probe.
type BumpStatus struct {
	Detected    bool   `json:"detected"`
	InterceptCA []byte `json:"interceptCa,omitempty"`
	Error       string `json:"error,omitempty"`
}

// Detect probes captive.apple.com via a direct TLS connection and checks
// whether the certificate chain contains an unexpected root CA, which
// indicates SSL bumping / interception.
func Detect() BumpStatus {
	systemRoots, err := x509.SystemCertPool()
	if err != nil {
		systemRoots = x509.NewCertPool()
	}

	rawConn, err := net.DialTimeout("tcp", net.JoinHostPort(probeHost, probePort), 8*time.Second)
	if err != nil {
		return BumpStatus{Error: fmt.Sprintf("dial failed: %v", err)}
	}
	defer rawConn.Close()

	// InsecureSkipVerify so we capture the chain even when it's untrusted
	tlsConn := tls.Client(rawConn, &tls.Config{
		ServerName:         probeHost,
		InsecureSkipVerify: true, //nolint:gosec
	})
	_ = tlsConn.SetDeadline(time.Now().Add(8 * time.Second))
	if err := tlsConn.Handshake(); err != nil {
		return BumpStatus{Error: fmt.Sprintf("tls handshake failed: %v", err)}
	}
	chain := tlsConn.ConnectionState().PeerCertificates
	if len(chain) == 0 {
		return BumpStatus{Error: "empty certificate chain"}
	}

	// Collect fingerprints from the verified (trusted) chain
	systemFingerprints := map[string]bool{}
	if verifiedChains, verErr := chain[0].Verify(x509.VerifyOptions{
		DNSName: probeHost,
		Roots:   systemRoots,
	}); verErr == nil {
		for _, ch := range verifiedChains {
			for _, c := range ch {
				h := sha256.Sum256(c.Raw)
				systemFingerprints[hex.EncodeToString(h[:])] = true
			}
		}
	}

	// The last cert presented is the root/near-root of the intercepting chain
	interceptRoot := chain[len(chain)-1]
	rootFP := sha256.Sum256(interceptRoot.Raw)
	rootFPHex := hex.EncodeToString(rootFP[:])

	if !systemFingerprints[rootFPHex] {
		return BumpStatus{
			Detected:    true,
			InterceptCA: interceptRoot.Raw,
		}
	}
	return BumpStatus{Detected: false}
}
""")

# ── 2. CA cert in-memory store ─────────────────────────────────────────────────
write('internal/ssl_inspect/ca_store.go', r"""package ssl_inspect

import (
	"encoding/pem"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	mu         sync.RWMutex
	cachedCert []byte
	cachedAt   time.Time
)

// Cache stores the detected intercept CA cert (DER encoded).
func Cache(der []byte) {
	mu.Lock()
	defer mu.Unlock()
	cachedCert = der
	cachedAt = time.Now()
}

// Cached returns the stored DER cert and when it was cached.
func Cached() ([]byte, time.Time) {
	mu.RLock()
	defer mu.RUnlock()
	return cachedCert, cachedAt
}

// PEM returns the cached cert as PEM-encoded bytes, or nil if none cached.
func PEM() []byte {
	der, _ := Cached()
	if len(der) == 0 {
		return nil
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

// SaveToHomeDir writes the cert PEM to homeDir/ssl_inspect_ca.pem.
func SaveToHomeDir(homeDir string) error {
	p := PEM()
	if len(p) == 0 {
		return nil
	}
	return os.WriteFile(filepath.Join(homeDir, "ssl_inspect_ca.pem"), p, 0o644)
}
""")

# ── 3. Route handlers ──────────────────────────────────────────────────────────
write('api/routes/ssl_inspect_route.go', r"""package routes

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	ssl "github.com/igoogolx/itun2socks/internal/ssl_inspect"
)

var (
	lastSslCheck  time.Time
	lastSslStatus ssl.BumpStatus
)

// sslInspectRouter returns a chi.Router for /ssl-inspect/*.
func sslInspectRouter() chi.Router {
	r := chi.NewRouter()
	r.Get("/status", sslInspectStatus)
	r.Get("/cert", sslInspectCert)
	return r
}

// sslInspectStatus probes for SSL bumping and returns JSON:
//
//	{"detected": bool, "checkedAt": "RFC3339", "error": "...", "hasCert": bool}
func sslInspectStatus(w http.ResponseWriter, r *http.Request) {
	const minInterval = 30 * time.Second
	if time.Since(lastSslCheck) > minInterval {
		status := ssl.Detect()
		if status.Detected && len(status.InterceptCA) > 0 {
			ssl.Cache(status.InterceptCA)
		}
		lastSslCheck = time.Now()
		lastSslStatus = status
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"detected":  lastSslStatus.Detected,
		"checkedAt": lastSslCheck.Format(time.RFC3339),
		"error":     lastSslStatus.Error,
		"hasCert":   len(ssl.PEM()) > 0,
	})
}

// sslInspectCert returns the intercepting CA cert as PEM text.
// Returns 404 if no cert has been captured yet.
func sslInspectCert(w http.ResponseWriter, r *http.Request) {
	p := ssl.PEM()
	if len(p) == 0 {
		http.Error(w, "no certificate captured", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/x-pem-file")
	w.Header().Set("Content-Disposition", `attachment; filename="lux_intercept_ca.pem"`)
	_, _ = w.Write(p)
}
""")

# ── 4. Patch routes.go ─────────────────────────────────────────────────────────
routes_path = os.path.join(ITUN, 'api/routes/routes.go')
try:
    with open(routes_path) as f:
        content = f.read()

    if 'ssl-inspect' in content or 'sslInspectRouter' in content:
        print('  routes.go already patched — skipping')
    else:
        # Insert r.Mount("/ssl-inspect", sslInspectRouter()) just before the auth mount
        # which is the last r.Mount inside the authenticated group
        old = '\t\t\t\tr.Mount("/auth", authRouter())'
        new = '\t\t\t\tr.Mount("/ssl-inspect", sslInspectRouter())\n' + old
        if old in content:
            content = content.replace(old, new)
            with open(routes_path, 'w') as f:
                f.write(content)
            print('  patched api/routes/routes.go (added /ssl-inspect mount)')
        else:
            # Fallback: insert before go FileServer(r)
            old2 = '\tgo FileServer(r)'
            new2 = '\tr.Mount("/ssl-inspect", sslInspectRouter())\n' + old2
            if old2 in content:
                content = content.replace(old2, new2)
                with open(routes_path, 'w') as f:
                    f.write(content)
                print('  patched api/routes/routes.go (fallback insertion before FileServer)')
            else:
                print('  WARNING: could not auto-patch routes.go')
                print('  Add this manually inside the authenticated r.Group:')
                print('    r.Mount("/ssl-inspect", sslInspectRouter())')
except FileNotFoundError:
    print(f'  WARNING: routes.go not found at {routes_path}')
    print('  Add manually: r.Mount("/ssl-inspect", sslInspectRouter())')

print('\nDone. Verify with: cd ~/itun2socks && go build ./...')
