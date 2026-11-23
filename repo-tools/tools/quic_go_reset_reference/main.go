package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime/debug"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

func run() error {
	if len(os.Args) != 4 {
		return fmt.Errorf("expected certificate, private key and restart key")
	}
	cert, err := tls.LoadX509KeyPair(os.Args[1], os.Args[2])
	if err != nil {
		return err
	}
	key, err := os.ReadFile(os.Args[3])
	if err != nil {
		return err
	}
	if len(key) != 32 {
		return fmt.Errorf("expected a 32-byte restart key")
	}
	if build, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range build.Deps {
			if dep.Path == "github.com/quic-go/quic-go" {
				fmt.Println("PEER", dep.Path, dep.Version, dep.Sum)
			}
		}
	}
	socket, err := net.ListenPacket("udp4", "127.0.0.1:18448")
	if err != nil {
		return err
	}
	defer socket.Close()
	tr := &quic.Transport{Conn: socket, StatelessResetKey: (*quic.StatelessResetKey)(key)}
	ln, err := tr.ListenEarly(http3.ConfigureTLSConfig(&tls.Config{Certificates: []tls.Certificate{cert}}), nil)
	if err != nil {
		return err
	}
	srv := http3.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("REQUEST", r.URL.Path)
		if r.URL.Path == "/hold" {
			<-r.Context().Done()
			return
		}
		fmt.Fprint(w, "ready")
	})}
	fmt.Println("LISTENING")
	return srv.ServeListener(ln)
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
