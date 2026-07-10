package cluster

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
)

// LoadTLSMaterial reads a node's own certificate and key and the CA it trusts
// from PEM files on disk, and is the production loading path for the transport.
// A deployment provisions the certificate, key, and CA out of band from a real
// certificate authority and points the process at the three files; the
// transport then presents that certificate and trusts that CA, so identity is
// never self-generated at startup. The tlstest package writes files in exactly
// this form for the tests and the demo, but a real deployment supplies its own.
//
// It fails if the key pair does not load, if the CA file cannot be read, or if
// the CA file contributes no certificates, so a misconfigured path is a startup
// error rather than a transport that silently trusts nothing.
func LoadTLSMaterial(certFile, keyFile, caFile string) (TLSMaterial, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return TLSMaterial{}, fmt.Errorf("cluster: load certificate and key: %w", err)
	}
	caPEM, err := os.ReadFile(caFile) //nolint:gosec // caFile is an operator-provided path, not untrusted input
	if err != nil {
		return TLSMaterial{}, fmt.Errorf("cluster: read ca %s: %w", caFile, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return TLSMaterial{}, errors.New("cluster: ca file added no certificates; expected one or more PEM encoded certificates")
	}
	return TLSMaterial{Cert: cert, CA: pool}, nil
}
