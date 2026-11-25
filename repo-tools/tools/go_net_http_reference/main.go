// This file is a source fixture for the repository's external net/http
// reference runner. It deliberately uses only the Go standard library. The
// MoonBit runner builds it in an ephemeral evidence directory and never puts
// the binary or raw windows in the module archive.
package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type summary struct {
	ElapsedSec   float64 `json:"elapsed_seconds"`
	Samples      int     `json:"latency_samples"`
	Status       string  `json:"status"`
	Protocol     string  `json:"protocol"`
	Target       string  `json:"target"`
	PayloadBytes int     `json:"payload_bytes"`
	Concurrency  int     `json:"concurrency"`
	DurationSec  int     `json:"duration_seconds"`
	Requests     int64   `json:"requests"`
	Errors       int64   `json:"errors"`
	Throughput   float64 `json:"throughput_per_second"`
	P50Ms        float64 `json:"p50_ms"`
	P95Ms        float64 `json:"p95_ms"`
	P99Ms        float64 `json:"p99_ms"`
	Oracle       string  `json:"behavior_oracle"`
}

func handler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "read failed", http.StatusBadRequest)
			return
		}
		w.Header().Set("content-type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
		return
	}
	w.Header().Set("content-type", "text/plain")
	_, _ = io.WriteString(w, "Go net/http reference\n")
}

func serve(protocol, listen, cert, key string) error {
	s := &http.Server{Addr: listen, Handler: http.HandlerFunc(handler)}
	log.Printf("ready protocol=%s listen=%s", protocol, listen)
	if protocol == "h2" {
		// ListenAndServeTLS enables HTTP/2 through ALPN in supported Go
		// releases. Set the protocols explicitly so the oracle can assert h2.
		s.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS13, NextProtos: []string{"h2", "http/1.1"}}
		return s.ListenAndServeTLS(cert, key)
	}
	return s.ListenAndServe()
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	index := int(float64(len(values)-1) * p)
	return values[index]
}

func probe(protocol, target string, payloadBytes, concurrency, durationSec int, roots *x509.CertPool) summary {
	major, maxConnections := 1, concurrency
	if protocol == "h2" {
		major, maxConnections = 2, 1
	}
	transport := &http.Transport{
		ForceAttemptHTTP2: protocol == "h2", MaxConnsPerHost: maxConnections,
		MaxIdleConnsPerHost: maxConnections,
		TLSClientConfig:     &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	payload := bytes.Repeat([]byte{'x'}, payloadBytes)
	windowStart := time.Now()
	deadline := windowStart.Add(time.Duration(durationSec) * time.Second)
	var latencies []float64
	var mu sync.Mutex
	var requests, errors int64
	var firstFailure sync.Once
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var samples []float64
			defer func() {
				mu.Lock()
				latencies = append(latencies, samples...)
				mu.Unlock()
			}()
			for time.Now().Before(deadline) {
				started := time.Now()
				req, err := http.NewRequest(http.MethodPost, target, bytes.NewReader(payload))
				if err == nil {
					req.Header.Set("content-type", "application/octet-stream")
					var resp *http.Response
					resp, err = client.Do(req)
					if err == nil {
						var got []byte
						got, err = io.ReadAll(resp.Body)
						_ = resp.Body.Close()
						if resp.ProtoMajor != major || resp.StatusCode != http.StatusOK || !bytes.Equal(got, payload) {
							err = fmt.Errorf("oracle mismatch: protocol=%s status=%d bytes=%d", resp.Proto, resp.StatusCode, len(got))
						}
					}
				}
				if err != nil {
					firstFailure.Do(func() { log.Printf("probe request failed: %v", err) })
					atomic.AddInt64(&errors, 1)
					continue
				}
				atomic.AddInt64(&requests, 1)
				samples = append(samples, float64(time.Since(started))/float64(time.Millisecond))
			}
		}()
	}
	wg.Wait()
	elapsed := time.Since(windowStart).Seconds()
	sort.Float64s(latencies)
	status := "measured"
	if errors != 0 || requests == 0 {
		status = "failed"
	}
	return summary{
		Status: status, ElapsedSec: elapsed, Samples: len(latencies), Protocol: protocol, Target: target,
		PayloadBytes: payloadBytes, Concurrency: concurrency, DurationSec: durationSec,
		Requests: requests, Errors: errors, Throughput: float64(requests) / elapsed,
		P50Ms: percentile(latencies, .50), P95Ms: percentile(latencies, .95), P99Ms: percentile(latencies, .99),
		Oracle: "HTTP version, HTTP 200 and exact POST echo verified for every successful request",
	}
}

func reference(payloadBytes, concurrency, durationSec int) map[string]summary {
	h1 := httptest.NewServer(http.HandlerFunc(handler))
	defer h1.Close()
	h2 := httptest.NewUnstartedServer(http.HandlerFunc(handler))
	h2.EnableHTTP2 = true
	h2.StartTLS()
	defer h2.Close()
	roots := x509.NewCertPool()
	roots.AddCert(h2.Certificate())
	return map[string]summary{
		"h1": probe("h1", h1.URL+"/echo", payloadBytes, concurrency, durationSec, nil),
		"h2": probe("h2", h2.URL+"/echo", payloadBytes, concurrency, durationSec, roots),
	}
}

func main() {
	mode := flag.String("mode", "server", "server or probe")
	protocol := flag.String("protocol", "h1", "h1 or h2")
	listen := flag.String("listen", "127.0.0.1:18081", "listen address")
	target := flag.String("target", "", "probe target URL")
	cert := flag.String("cert", "", "PEM certificate for h2 server")
	key := flag.String("key", "", "PEM private key for h2 server")
	payload := flag.Int("payload-bytes", 65536, "POST payload size")
	concurrency := flag.Int("concurrency", 4, "probe workers")
	duration := flag.Int("duration-seconds", 10, "probe duration")
	caFile := flag.String("cacert", "", "PEM trust anchors for the probe")
	flag.Parse()
	if *payload < 0 || *payload > 1<<20 {
		log.Fatal("payload must fit the 1 MiB echo limit")
	}
	if *mode == "server" {
		if err := serve(*protocol, *listen, *cert, *key); err != nil {
			log.Fatal(err)
		}
		return
	}
	if *mode == "reference" {
		if *duration <= 0 || *concurrency <= 0 {
			log.Fatal("reference requires positive duration and concurrency")
		}
		results := reference(*payload, *concurrency, *duration)
		_ = json.NewEncoder(os.Stdout).Encode(results)
		if results["h1"].Status != "measured" || results["h2"].Status != "measured" {
			os.Exit(1)
		}
		return
	}
	if *target == "" || (*protocol != "h1" && *protocol != "h2") || *duration <= 0 || *concurrency <= 0 {
		log.Fatal("probe requires target, h1/h2 protocol, positive duration and concurrency")
	}
	var roots *x509.CertPool
	if *caFile != "" {
		pem, err := os.ReadFile(*caFile)
		if err != nil {
			log.Fatal(err)
		}
		roots = x509.NewCertPool()
		if !roots.AppendCertsFromPEM(pem) {
			log.Fatal("invalid probe trust anchors")
		}
	}
	value := probe(*protocol, *target, *payload, *concurrency, *duration, roots)
	_ = json.NewEncoder(os.Stdout).Encode(value)
	if value.Status != "measured" {
		os.Exit(1)
	}
}
