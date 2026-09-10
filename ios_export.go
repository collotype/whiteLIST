//go:build ios

package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
	"unsafe"

	"universal-bypass-tool/transport"
	"universal-bypass-tool/transport/oneme"
	"universal-bypass-tool/transport/yandex"
	"universal-bypass-tool/utils"
)

const mobileQueueSize = 2048

type mobileStatus struct {
	Running       bool   `json:"running"`
	Transport     string `json:"transport"`
	Connected     bool   `json:"connected"`
	LastError     string `json:"lastError"`
	BytesSent     uint64 `json:"bytesSent"`
	BytesReceived uint64 `json:"bytesReceived"`
	PacketsSent   uint64 `json:"packetsSent"`
	PacketsRecv   uint64 `json:"packetsRecv"`
	DroppedRecv   uint64 `json:"droppedRecv"`
	Reconnects    uint64 `json:"reconnects"`
	UptimeMS      int64  `json:"uptimeMs"`
}

var mobileState = struct {
	sync.Mutex
	running     bool
	kind        string
	trans       transport.Transport
	inbound     chan []byte
	lastError   string
	droppedRecv uint64
}{}

func setMobileError(message string) {
	mobileState.Lock()
	mobileState.lastError = message
	mobileState.Unlock()
	if message != "" {
		log.Printf("[iOS] %s", message)
	}
}

func startMobileTransport(kind string, trans transport.Transport) C.int {
	mobileState.Lock()
	if mobileState.running {
		mobileState.Unlock()
		setMobileError("OpenFlux is already running")
		return -1
	}
	queue := make(chan []byte, mobileQueueSize)
	mobileState.running = true
	mobileState.kind = kind
	mobileState.trans = trans
	mobileState.inbound = queue
	mobileState.lastError = ""
	mobileState.droppedRecv = 0
	mobileState.Unlock()

	trans.Receive(func(packet []byte) {
		copyOfPacket := append([]byte(nil), packet...)
		select {
		case queue <- copyOfPacket:
		default:
			mobileState.Lock()
			mobileState.droppedRecv++
			mobileState.Unlock()
		}
	})

	utils.EnableDebug()
	if err := trans.Start(); err != nil {
		mobileState.Lock()
		mobileState.running = false
		mobileState.kind = ""
		mobileState.trans = nil
		mobileState.inbound = nil
		mobileState.Unlock()
		setMobileError(fmt.Sprintf("transport start failed: %v", err))
		return -2
	}

	log.Printf("[iOS] OpenFlux transport started: %s", kind)
	return 0
}

//export OFStartYandex
func OFStartYandex(rawURL *C.char) (result C.int) {
	defer func() {
		if value := recover(); value != nil {
			setMobileError(fmt.Sprintf("Yandex startup panic: %v", value))
			result = -90
		}
	}()

	if rawURL == nil {
		setMobileError("Yandex Docs URL is empty")
		return -10
	}
	url := strings.TrimSpace(C.GoString(rawURL))
	if !strings.HasPrefix(url, "https://") {
		setMobileError("Yandex Docs URL must start with https://")
		return -11
	}
	return startMobileTransport(
		"yandex",
		transport.NewCompressedTransport(yandex.NewYandexDocsTransport(url, transport.DefaultConfig())),
	)
}

//export OFStartMax
func OFStartMax(rawToken *C.char, uid C.longlong) (result C.int) {
	defer func() {
		if value := recover(); value != nil {
			setMobileError(fmt.Sprintf("MAX startup panic: %v", value))
			result = -90
		}
	}()

	if rawToken == nil {
		setMobileError("MAX token is empty")
		return -20
	}
	token := strings.TrimSpace(C.GoString(rawToken))
	if token == "" || int64(uid) <= 0 {
		setMobileError("MAX token or exit-node UID is invalid")
		return -21
	}
	return startMobileTransport(
		"max",
		transport.NewCompressedTransport(oneme.NewOneMeTransport(false, token, int64(uid), transport.DefaultConfig())),
	)
}

//export OFStop
func OFStop() C.int {
	mobileState.Lock()
	if !mobileState.running {
		mobileState.Unlock()
		return 0
	}
	trans := mobileState.trans
	mobileState.running = false
	mobileState.kind = ""
	mobileState.trans = nil
	mobileState.inbound = nil
	mobileState.Unlock()

	if trans != nil {
		if err := trans.Stop(); err != nil {
			setMobileError(fmt.Sprintf("transport stop failed: %v", err))
			return -1
		}
	}
	log.Printf("[iOS] OpenFlux transport stopped")
	return 0
}

// OFSendPacket forwards one IPv4 packet from NEPacketTunnelFlow to OpenFlux.
//
//export OFSendPacket
func OFSendPacket(data unsafe.Pointer, length C.int) C.int {
	if data == nil || length <= 0 || length > 65535 {
		return -1
	}
	mobileState.Lock()
	running := mobileState.running
	trans := mobileState.trans
	mobileState.Unlock()
	if !running || trans == nil || !trans.IsConnected() {
		return -2
	}
	packet := C.GoBytes(data, length)
	if err := trans.Send(packet); err != nil {
		setMobileError(fmt.Sprintf("packet send failed: %v", err))
		return -3
	}
	return 0
}

// OFReceivePacket waits for one packet from OpenFlux. The caller owns the
// returned allocation and must release it with OFFreeBuffer.
//
//export OFReceivePacket
func OFReceivePacket(length *C.int, timeoutMS C.int) unsafe.Pointer {
	if length == nil {
		return nil
	}
	*length = 0
	mobileState.Lock()
	running := mobileState.running
	queue := mobileState.inbound
	mobileState.Unlock()
	if !running || queue == nil {
		return nil
	}

	timeout := time.Duration(timeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = 100 * time.Millisecond
	}
	select {
	case packet := <-queue:
		if len(packet) == 0 {
			return nil
		}
		*length = C.int(len(packet))
		return C.CBytes(packet)
	case <-time.After(timeout):
		return nil
	}
}

//export OFStatusJSON
func OFStatusJSON() *C.char {
	mobileState.Lock()
	running := mobileState.running
	kind := mobileState.kind
	trans := mobileState.trans
	lastError := mobileState.lastError
	dropped := mobileState.droppedRecv
	mobileState.Unlock()

	status := mobileStatus{
		Running:     running,
		Transport:   kind,
		LastError:   lastError,
		DroppedRecv: dropped,
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

	encoded, err := json.Marshal(status)
	if err != nil {
		return C.CString(`{"running":false,"connected":false,"lastError":"status encode failed"}`)
	}
	return C.CString(string(encoded))
}

//export OFFreeBuffer
func OFFreeBuffer(value unsafe.Pointer) {
	if value != nil {
		C.free(value)
	}
}

//export OFFreeString
func OFFreeString(value *C.char) {
	OFFreeBuffer(unsafe.Pointer(value))
}
