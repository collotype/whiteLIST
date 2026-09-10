package oneme

import "testing"

func TestDisconnectedCallRejectsPacket(t *testing.T) {
	handler := &CallHandler{}
	if err := handler.Send([]byte("packet")); err == nil {
		t.Fatal("disconnected MAX call accepted a packet")
	}
}
