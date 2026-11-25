// This independent peer opens one QUIC connection per client on local UDP.
// The caller starts the MoonBit server and supplies its PID for OS accounting.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

type counters struct {
	Connections int   `json:"connections"`
	Polls       int64 `json:"polls,string"`
	Alarms      int64 `json:"alarms,string"`
}
type usage struct {
	CPUSeconds float64 `json:"cpu_seconds"`
	RSSBytes   int64   `json:"rss_bytes"`
	Wakeups    *int64  `json:"os_wakeups"`
	Kind       string  `json:"os_counter"`
}
type client struct {
	conn *quic.Conn
	http *http3.ClientConn
	host string
}

func (c client) get(ctx context.Context, path string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://"+c.host+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.ProtoMajor != 3 || resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected %s %d", resp.Proto, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// For a single GET, discard server datagrams during a controlled outage. QUIC owns
// timers, retransmission, packetization and HTTP stream completion.
var epoch = time.Now()

type lossSocket struct {
	net.PacketConn
	dropUntil atomic.Int64
	dropped   atomic.Int64
}

func (s *lossSocket) ReadFrom(b []byte) (int, net.Addr, error) {
	for {
		n, addr, err := s.PacketConn.ReadFrom(b)
		if err != nil || time.Since(epoch).Nanoseconds() >= s.dropUntil.Load() {
			return n, addr, err
		}
		s.dropped.Add(1)
	}
}

func run() error {
	addr := flag.String("address", "", "127.0.0.1:PORT")
	idles := flag.Int("idle", 0, "number of idle clients")
	pid := flag.Int("server-pid", 0, "observed server PID")
	duration := flag.Duration("duration", 5*time.Second, "length of each phase")
	flag.Parse()
	if *idles < 0 || *duration < time.Second || *pid <= 0 {
		return fmt.Errorf("invalid capacity arguments")
	}
	roots := x509.NewCertPool()
	pem, err := os.ReadFile("tests/fixtures/tls/localhost.cert.pem")
	if err != nil {
		return err
	}
	if !roots.AppendCertsFromPEM(pem) {
		return fmt.Errorf("invalid test root")
	}
	conf := &tls.Config{RootCAs: roots, ServerName: "localhost", NextProtos: []string{"h3"}, MinVersion: tls.VersionTLS13}
	settings := &quic.Config{MaxIdleTimeout: 2 * time.Minute}
	tr := &http3.Transport{}
	defer tr.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute+2*(*duration))
	defer cancel()
	peers := make([]client, 0, *idles+1)
	defer func() {
		for _, p := range peers {
			_ = p.conn.CloseWithError(0x100, "")
		}
	}()
	var activeSocket *lossSocket
	for i := 0; i <= *idles; i++ {
		var conn *quic.Conn
		if i == *idles {
			udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				return err
			}
			defer udp.Close()
			activeSocket = &lossSocket{PacketConn: udp}
			qt := &quic.Transport{Conn: activeSocket}
			defer qt.Close()
			remote, err := net.ResolveUDPAddr("udp4", *addr)
			if err != nil {
				return err
			}
			conn, err = qt.Dial(ctx, remote, conf, settings)
			if err != nil {
				return fmt.Errorf("active dial: %w", err)
			}
		} else {
			conn, err = quic.DialAddr(ctx, *addr, conf, settings)
		}
		if err != nil {
			return fmt.Errorf("dial %d: %w", i, err)
		}
		p := client{conn: conn, http: tr.NewClientConn(conn), host: *addr}
		peers = append(peers, p)
		b, err := p.get(ctx, "/")
		if err != nil {
			return fmt.Errorf("warm %d: %w", i, err)
		}
		if !bytes.Equal(b, []byte("MoonbitHTTP HTTP/3 smoke\n")) {
			return fmt.Errorf("unexpected warmup body")
		}
	}
	active := peers[len(peers)-1]
	snapshot := func() (counters, error) {
		var s counters
		b, err := active.get(ctx, "/capacity")
		if err != nil {
			return s, err
		}
		err = json.Unmarshal(b, &s)
		if err == nil && s.Connections != len(peers) {
			err = fmt.Errorf("expected %d live connections, found %d", len(peers), s.Connections)
		}
		return s, err
	}
	time.Sleep(time.Second)
	for _, phase := range []string{"idle", "mixed"} {
		before, err := snapshot()
		if err != nil {
			return err
		}
		startUsage, err := sampleUsage(*pid)
		if err != nil {
			return err
		}
		start := time.Now()
		var samples []float64
		if phase == "idle" {
			time.Sleep(*duration)
		} else {
			ticker := time.NewTicker(20 * time.Millisecond)
			for time.Since(start) < *duration {
				<-ticker.C
				at := time.Now()
				body, err := active.get(ctx, "/")
				if err != nil {
					ticker.Stop()
					return err
				}
				if !bytes.Equal(body, []byte("MoonbitHTTP HTTP/3 smoke\n")) {
					ticker.Stop()
					return fmt.Errorf("unexpected response")
				}
				samples = append(samples, float64(time.Since(at).Nanoseconds())/1e6)
			}
			ticker.Stop()
		}
		elapsed := time.Since(start).Seconds()
		endUsage, err := sampleUsage(*pid)
		if err != nil {
			return err
		}
		after, err := snapshot()
		if err != nil {
			return err
		}
		row := map[string]any{"phase": phase, "idle_connections": *idles, "observed_connections": after.Connections, "elapsed_seconds": elapsed,
			"transport_polls": after.Polls - before.Polls, "deadline_polls": after.Alarms - before.Alarms, "cpu_seconds": endUsage.CPUSeconds - startUsage.CPUSeconds,
			"cpu_percent": 100 * (endUsage.CPUSeconds - startUsage.CPUSeconds) / elapsed, "rss_end_bytes": endUsage.RSSBytes, "rss_start_bytes": startUsage.RSSBytes,
			"os_counter": endUsage.Kind, "os_wakeups": nil, "latency_ms": samples}
		if startUsage.Wakeups != nil && endUsage.Wakeups != nil {
			row["os_wakeups"] = *endUsage.Wakeups - *startUsage.Wakeups
		}
		if len(samples) > 0 {
			sorted := append([]float64(nil), samples...)
			sort.Float64s(sorted)
			row["p99_ms"] = sorted[(99*len(sorted)+99)/100-1]
		}
		if phase == "mixed" {
			// Keep the recovery case outside throughput/latency windows.
			time.Sleep(100 * time.Millisecond)
			const blackout = 35 * time.Millisecond
			started := time.Now()
			activeSocket.dropUntil.Store(started.Sub(epoch).Nanoseconds() + blackout.Nanoseconds())
			body, err := active.get(ctx, "/")
			if err != nil {
				return fmt.Errorf("blackout recovery: %w", err)
			}
			if activeSocket.dropped.Load() < 1 || !bytes.Equal(body, []byte("MoonbitHTTP HTTP/3 smoke\n")) {
				return fmt.Errorf("blackout recovery did not complete")
			}
			row["blackout_ms"] = blackout.Milliseconds()
			row["server_datagrams_dropped"] = activeSocket.dropped.Load()
			row["blackout_response_ms"] = float64(time.Since(started).Nanoseconds()) / 1e6
		}
		if err := json.NewEncoder(os.Stdout).Encode(row); err != nil {
			return err
		}
	}
	return nil
}
func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
