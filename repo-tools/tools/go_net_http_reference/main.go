// This file is a source fixture for the repository's external net/http
// reference runner. It deliberately uses only the Go standard library. The
// MoonBit runner builds it in an ephemeral evidence directory and never puts
// the binary or raw windows in the module archive.
package main

import (
	"bytes"
	"crypto/tls"
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
	sort.Float64s(values)
	index := int(float64(len(values)-1) * p)
	return values[index]
}

func probe(protocol, target string, payloadBytes, concurrency, durationSec int) summary {
	transport := &http.Transport{ForceAttemptHTTP2: protocol == "h2"}
	if protocol == "h2" {
		// The reference server is an in-process loopback httptest fixture with a
		// self-signed certificate; this is never a production client setting.
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS13}
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	payload := bytes.Repeat([]byte{'x'}, payloadBytes)
	deadline := time.Now().Add(time.Duration(durationSec) * time.Second)
	latencies := make([]float64, 0, 100000)
	var mu sync.Mutex
	var requests, errors int64
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
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
						if resp.StatusCode != http.StatusOK || !bytes.Equal(got, payload) {
							err = fmt.Errorf("oracle mismatch: status=%d bytes=%d", resp.StatusCode, len(got))
						}
					}
				}
				if err != nil {
					atomic.AddInt64(&errors, 1)
					continue
				}
				atomic.AddInt64(&requests, 1)
				mu.Lock()
				if len(latencies) < cap(latencies) {
					latencies = append(latencies, float64(time.Since(started).Microseconds())/1000)
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	elapsed := float64(durationSec)
	return summary{
		Status: "measured", Protocol: protocol, Target: target,
		PayloadBytes: payloadBytes, Concurrency: concurrency, DurationSec: durationSec,
		Requests: requests, Errors: errors, Throughput: float64(requests) / elapsed,
		P50Ms: percentile(latencies, .50), P95Ms: percentile(latencies, .95),
		Oracle: "POST response body and HTTP 200 verified for every successful request",
	}
}

func reference(payloadBytes, concurrency, durationSec int) map[string]summary {
	h1 := httptest.NewServer(http.HandlerFunc(handler))
	defer h1.Close()
	h2 := httptest.NewUnstartedServer(http.HandlerFunc(handler))
	h2.EnableHTTP2 = true
	h2.StartTLS()
	defer h2.Close()
	return map[string]summary{
		"h1": probe("h1", h1.URL+"/echo", payloadBytes, concurrency, durationSec),
		"h2": probe("h2", h2.URL+"/echo", payloadBytes, concurrency, durationSec),
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
	flag.Parse()
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
		_ = json.NewEncoder(os.Stdout).Encode(reference(*payload, *concurrency, *duration))
		return
	}
	if *target == "" || (*protocol != "h1" && *protocol != "h2") || *duration <= 0 || *concurrency <= 0 {
		log.Fatal("probe requires target, h1/h2 protocol, positive duration and concurrency")
	}
	value := probe(*protocol, *target, *payload, *concurrency, *duration)
	if value.Errors > 0 || value.Requests == 0 {
		value.Status = "failed"
	}
	_ = json.NewEncoder(os.Stdout).Encode(value)
}
