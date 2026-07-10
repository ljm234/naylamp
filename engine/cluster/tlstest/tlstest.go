// Package tlstest issues in-memory certificate material for the mutual TLS
// transport: a self-signed CA and node leaf certificates whose common name is
// the decimal node id. It exists so the cluster tests, the naylamp tests, and
// the demo gencerts command all mint identity from one place, with the exact
// convention the transport verifies, that a peer's common name equals its node
// id.
//
// This material is for tests and the hands-on demo only. The generation here is
// never for production deployments: a real deployment provisions its
// certificates from a real certificate authority out of band and loads them
// from disk with cluster.LoadTLSMaterial, and never mints its own identity or
// trusts a CA created at startup.
//
// The package imports only the standard library, never any package of this
// repository. That is deliberate: a cluster test lives in package cluster, so a
// helper that imported cluster could not be imported back by that test without
// an import cycle. Keeping tlstest free of repo imports lets every test and the
// demo share one generator.
package tlstest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// CA is an in-memory certificate authority: a self-signed ecdsa root that signs
// node leaf certificates, plus the pool that trusts exactly that root.
type CA struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pool *x509.CertPool
}

// NewCA builds a fresh in-memory CA with an ecdsa P-256 root.
func NewCA() (*CA, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("tlstest: ca key: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "naylamp test ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, fmt.Errorf("tlstest: ca cert: %w", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, fmt.Errorf("tlstest: parse ca: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return &CA{cert: cert, key: key, pool: pool}, nil
}

// Pool returns the certificate pool that trusts this CA, for the CA field of a
// transport's TLS material.
func (ca *CA) Pool() *x509.CertPool { return ca.pool }

// NodeCert issues a leaf certificate for one node id, usable as both a server
// and a client credential, with the decimal node id as its common name. That
// common name is the exact identity the transport reads back off the verified
// certificate, so the id here is the id a peer will be attributed as.
func (ca *CA) NodeCert(id uint64) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("tlstest: node %d key: %w", id, err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: new(big.Int).SetUint64(id + 2),
		Subject:      pkix.Name{CommonName: strconv.FormatUint(id, 10)},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("tlstest: node %d cert: %w", id, err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

// WritePEM writes the CA certificate and one certificate and key pair per node
// id to dir as PEM files, the on-disk form the demo loads back with
// cluster.LoadTLSMaterial. The layout is:
//
//	<dir>/ca.pem             the CA certificate
//	<dir>/node-<id>.pem      node <id>'s certificate
//	<dir>/node-<id>-key.pem  node <id>'s private key
//
// dir is created if it does not exist. The files carry the same generated
// material this package issues in memory, so a process that loads them presents
// the identity of its node id.
func (ca *CA) WritePEM(dir string, ids ...uint64) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("tlstest: mkdir %s: %w", dir, err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca.cert.Raw})
	if err := os.WriteFile(filepath.Join(dir, "ca.pem"), caPEM, 0o600); err != nil {
		return fmt.Errorf("tlstest: write ca: %w", err)
	}
	for _, id := range ids {
		cert, err := ca.NodeCert(id)
		if err != nil {
			return err
		}
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
		keyDER, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
		if err != nil {
			return fmt.Errorf("tlstest: marshal node %d key: %w", id, err)
		}
		keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
		certPath := filepath.Join(dir, fmt.Sprintf("node-%d.pem", id))
		keyPath := filepath.Join(dir, fmt.Sprintf("node-%d-key.pem", id))
		if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
			return fmt.Errorf("tlstest: write node %d cert: %w", id, err)
		}
		if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
			return fmt.Errorf("tlstest: write node %d key: %w", id, err)
		}
	}
	return nil
}
