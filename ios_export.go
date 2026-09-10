//go:build ios
// +build ios

package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"
	"unsafe"

	"universal-bypass-tool/transport"
	"universal-bypass-tool/transport/oneme"
	"universal-bypass-tool/transport/yandex"
	"universal-bypass-tool/tunnel"
	"universal-bypass-tool/utils"
)

type mobileDialer interface {
	DialTCP(address string) (net.Conn, error)
}

// iOS wrapper uses its own small stoppable SOCKS5 listener.
// The upstream SOCKS5 implementation has no Stop method, which makes
// Connect -> Disconnect -> Connect impossible inside one iOS process.
type mobileSOCKSServer struct {
	addr   string
	dialer mobileDialer

	mu      sync.Mutex
	ln      net.Listener
	stopped bool
	conns   map[net.Conn]struct{}
}

func newMobileSOCKSServer(addr string, dialer mobileDialer) *mobileSOCKSServer {
	return &mobileSOCKSServer{
		addr:   addr,
		dialer: dialer,
		conns:  make(map[net.Conn]struct{}),
	}
}

func (s *mobileSOCKSServer) Listen() error {
	ln, err := net.Listen("tcp", s.addr)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.ln = ln
	s.stopped = false
	s.mu.Unlock()
	return nil
}

func (s *mobileSOCKSServer) Serve() {
	log.Printf("[iOS/SOCKS5] Listening on %s", s.addr)
	for {
		s.mu.Lock()
		ln := s.ln
		stopped := s.stopped
		s.mu.Unlock()

		if stopped || ln == nil {
			return
		}

		conn, err := ln.Accept()
		if err != nil {
			s.mu.Lock()
			stopped = s.stopped
			s.mu.Unlock()
			if stopped {
				return
			}
			log.Printf("[iOS/SOCKS5] Accept error: %v", err)
			continue
		}

		s.mu.Lock()
		s.conns[conn] = struct{}{}
		s.mu.Unlock()

		go s.handle(conn)
	}
}

func (s *mobileSOCKSServer) Stop() {
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return
	}
	s.stopped = true
	ln := s.ln
	s.ln = nil
	conns := make([]net.Conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.mu.Unlock()

	if ln != nil {
		_ = ln.Close()
	}
	for _, c := range conns {
		_ = c.Close()
	}
	log.Printf("[iOS/SOCKS5] Stopped")
}

func (s *mobileSOCKSServer) untrack(c net.Conn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
}

func (s *mobileSOCKSServer) handle(client net.Conn) {
	defer func() {
		s.untrack(client)
		_ = client.Close()
	}()

	_ = client.SetDeadline(time.Now().Add(30 * time.Second))

	// Greeting: VER, NMETHODS, METHODS...
	header := make([]byte, 2)
	if _, err := io.ReadFull(client, header); err != nil || header[0] != 0x05 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return
	}
	hasNoAuth := false
	for _, m := range methods {
		if m == 0x00 {
			hasNoAuth = true
			break
		}
	}
	if !hasNoAuth {
		_, _ = client.Write([]byte{0x05, 0xFF})
		return
	}
	if _, err := client.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	// Request: VER CMD RSV ATYP
	req := make([]byte, 4)
	if _, err := io.ReadFull(client, req); err != nil || req[0] != 0x05 || req[1] != 0x01 {
		return
	}

	var host string
	switch req[3] {
	case 0x01: // IPv4
		ip := make([]byte, 4)
		if _, err := io.ReadFull(client, ip); err != nil {
			return
		}
		host = net.IP(ip).String()

	case 0x03: // domain
		l := make([]byte, 1)
		if _, err := io.ReadFull(client, l); err != nil {
			return
		}
		name := make([]byte, int(l[0]))
		if _, err := io.ReadFull(client, name); err != nil {
			return
		}
		host = string(name)

	case 0x04: // IPv6 - upstream tunnel currently supports IPv4 only.
		_, _ = client.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return

	default:
		return
	}

	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(client, portBytes); err != nil {
		return
	}
	port := int(portBytes[0])<<8 | int(portBytes[1])
	target := fmt.Sprintf("%s:%d", host, port)

	log.Printf("[iOS/SOCKS5] CONNECT %s", target)
	remote, err := s.dialer.DialTCP(target)
	if err != nil {
		log.Printf("[iOS/SOCKS5] Dial failed: %v", err)
		_, _ = client.Write([]byte{0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer remote.Close()

	if _, err := client.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}

	// Clear handshake deadline for the actual proxied connection.
	_ = client.SetDeadline(time.Time{})

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		_, _ = io.Copy(remote, client)
		_ = remote.Close()
	}()

	go func() {
		defer wg.Done()
		_, _ = io.Copy(client, remote)
		_ = client.Close()
	}()

	wg.Wait()
}

var mobileState = struct {
	sync.Mutex
	running   bool
	kind      string
	trans     transport.Transport
	tun       *tunnel.TCPTunnel
	socks     *mobileSOCKSServer
	lastError string
}{
	lastError: "",
}

func setMobileError(err string) {
	mobileState.Lock()
	mobileState.lastError = err
	mobileState.Unlock()
	if err != "" {
		log.Printf("[iOS] ERROR: %s", err)
	}
}

func startMobileClient(kind string, trans transport.Transport) C.int {
	mobileState.Lock()
	if mobileState.running {
		mobileState.Unlock()
		setMobileError("OpenFlux client is already running")
		return -1
	}
	mobileState.lastError = ""
	mobileState.Unlock()

	utils.EnableDebug()
	log.Printf("[iOS] Starting OpenFlux transport=%s", kind)

	if err := trans.Start(); err != nil {
		setMobileError(fmt.Sprintf("transport start failed: %v", err))
		return -2
	}

	tun := tunnel.NewTCPTunnel(trans, false)
	socks := newMobileSOCKSServer("127.0.0.1:1080", tun)

	if err := socks.Listen(); err != nil {
		_ = trans.Stop()
		setMobileError(fmt.Sprintf("SOCKS5 listen failed: %v", err))
		return -3
	}

	mobileState.Lock()
	mobileState.running = true
	mobileState.kind = kind
	mobileState.trans = trans
	mobileState.tun = tun
	mobileState.socks = socks
	mobileState.lastError = ""
	mobileState.Unlock()

	go socks.Serve()
	log.Printf("[iOS] Client started; SOCKS5=127.0.0.1:1080")
	return 0
}

//export OFStartYandex
func OFStartYandex(url *C.char) (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			setMobileError(fmt.Sprintf("panic while starting Yandex transport: %v", r))
			ret = -90
		}
	}()

	if url == nil {
		setMobileError("Yandex Docs URL is empty")
		return -10
	}

	value := strings.TrimSpace(C.GoString(url))
	if value == "" {
		setMobileError("Yandex Docs URL is empty")
		return -10
	}

	cfg := transport.DefaultConfig()
	trans := yandex.NewYandexDocsTransport(value, cfg)
	return startMobileClient("yandex", trans)
}

//export OFStartMax
func OFStartMax(token *C.char, uid C.longlong) (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			setMobileError(fmt.Sprintf("panic while starting MAX transport: %v", r))
			ret = -90
		}
	}()

	if token == nil {
		setMobileError("MAX token is empty")
		return -20
	}
	value := strings.TrimSpace(C.GoString(token))
	if value == "" {
		setMobileError("MAX token is empty")
		return -20
	}
	if int64(uid) <= 0 {
		setMobileError("MAX UID must be a positive number")
		return -21
	}

	cfg := transport.DefaultConfig()
	trans := oneme.NewOneMeTransport(false, value, int64(uid), cfg)
	return startMobileClient("max", trans)
}

//export OFStop
func OFStop() C.int {
	mobileState.Lock()
	if !mobileState.running {
		mobileState.Unlock()
		return 0
	}

	socks := mobileState.socks
	trans := mobileState.trans

	mobileState.running = false
	mobileState.kind = ""
	mobileState.trans = nil
	mobileState.tun = nil
	mobileState.socks = nil
	mobileState.Unlock()

	if socks != nil {
		socks.Stop()
	}
	if trans != nil {
		if err := trans.Stop(); err != nil {
			setMobileError(fmt.Sprintf("transport stop failed: %v", err))
			return -1
		}
	}

	log.Printf("[iOS] Client stopped")
	return 0
}

type mobileStatus struct {
	Running       bool   `json:"running"`
	Transport     string `json:"transport"`
	Connected     bool   `json:"connected"`
	SocksListening bool  `json:"socksListening"`
	LastError     string `json:"lastError"`

	BytesSent     uint64 `json:"bytesSent"`
	BytesReceived uint64 `json:"bytesReceived"`
	PacketsSent   uint64 `json:"packetsSent"`
	PacketsRecv   uint64 `json:"packetsRecv"`
	Reconnects    uint64 `json:"reconnects"`
	UptimeMS      int64  `json:"uptimeMs"`
}

//export OFStatusJSON
func OFStatusJSON() *C.char {
	mobileState.Lock()
	running := mobileState.running
	kind := mobileState.kind
	trans := mobileState.trans
	socks := mobileState.socks
	lastErr := mobileState.lastError
	mobileState.Unlock()

	status := mobileStatus{
		Running:        running,
		Transport:      kind,
		Connected:      false,
		SocksListening: running && socks != nil,
		LastError:      lastErr,
	}

	if running && trans != nil {
		stats := trans.Stats()
		status.Connected = trans.IsConnected()
		status.BytesSent = stats.BytesSent
		status.BytesReceived = stats.BytesReceived
		status.PacketsSent = stats.PacketsSent
		status.PacketsRecv = stats.PacketsRecv
		status.Reconnects = stats.Reconnects
		status.UptimeMS = stats.Uptime.Milliseconds()
	}

	data, err := json.Marshal(status)
	if err != nil {
		return C.CString(`{"running":false,"connected":false,"lastError":"status encode failed"}`)
	}
	return C.CString(string(data))
}

// OFTestTunnel checks the tunnel itself, not Safari/system-wide routing.
// A successful TCP connection means traffic traversed TCPTunnel -> transport -> exit node.
//
//export OFTestTunnel
func OFTestTunnel() *C.char {
	mobileState.Lock()
	running := mobileState.running
	tun := mobileState.tun
	trans := mobileState.trans
	mobileState.Unlock()

	if !running || tun == nil || trans == nil {
		return C.CString("ERROR: OpenFlux is not running")
	}
	if !trans.IsConnected() {
		return C.CString("ERROR: transport is not connected yet")
	}

	done := make(chan string, 1)
	go func() {
		conn, err := tun.DialTCP("1.1.1.1:80")
		if err != nil {
			done <- fmt.Sprintf("ERROR: tunnel TCP test failed: %v", err)
			return
		}
		_ = conn.Close()
		done <- "OK: tunnel opened TCP connection to 1.1.1.1:80"
	}()

	select {
	case result := <-done:
		return C.CString(result)
	case <-time.After(12 * time.Second):
		return C.CString("ERROR: tunnel test timed out after 12 seconds")
	}
}

//export OFFreeString
func OFFreeString(value *C.char) {
	if value != nil {
		C.free(unsafe.Pointer(value))
	}
}

// Compatibility with the original build_ios.sh fallback header.

//export RunMain
func RunMain() {
	main()
}

//export RunMainClient
func RunMainClient(url *C.char) {
	_ = OFStartYandex(url)
	select {}
}

//export RunMainExitNode
func RunMainExitNode() {
	// Exit node mode is intentionally not run inside iOS.
}
