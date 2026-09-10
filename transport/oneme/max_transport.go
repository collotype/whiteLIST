package oneme

import (
	"fmt"

	"universal-bypass-tool/transport"
	"universal-bypass-tool/utils"
)

type OneMeTransport struct {
	b     *transport.BaseTransport
	token string
	uid   int64
	exit  bool

	oneMeClient MaxClient
	ch          *CallHandler
}

func (t *OneMeTransport) Receive(callback func([]byte)) {
	t.b.Receive(callback)
}

func (t *OneMeTransport) Stats() transport.TransportStats {
	return t.b.Stats()
}

func NewOneMeTransport(isExit bool, maxToken string, maxUid int64, config transport.TransportConfig) *OneMeTransport {
	return &OneMeTransport{
		b:     transport.NewBaseTransport(config),
		token: maxToken,
		uid:   maxUid,
		exit:  isExit,
	}
}

func (t *OneMeTransport) Start() error {
	utils.Debugf("creating max client ...")
	t.oneMeClient = *NewMaxClient()
	if err := t.oneMeClient.Connect(); err != nil {
		return err
	}
	if err := t.oneMeClient.LoginByToken(t.token); err != nil {
		t.oneMeClient.Close()
		return err
	}
	if err := t.b.Start(); err != nil {
		t.oneMeClient.Close()
		return err
	}

	if t.exit {
		utils.Debugf("configured ch for exit node")
		t.ch = startIncomingListener(&t.oneMeClient)
	} else {
		utils.Debugf("configured ch for client mode")
		t.ch = startOutgoingCall(&t.oneMeClient, t.uid)
	}

	utils.Debugf("configured dc inbound")
	t.ch.SetDCInbound(func(data []byte) {
		t.b.RecordReceive(len(data))
		t.b.CallReceive(data)
	})
	t.ch.SetOnConnected(func() { t.b.SetConnected(true) })

	return nil
}

func (t *OneMeTransport) Stop() error {
	if t.ch != nil {
		t.ch.Close()
	}
	t.oneMeClient.Close()
	return t.b.Stop()
}

func (t *OneMeTransport) IsConnected() bool {
	return t.b.IsConnected() && t.ch != nil && t.ch.IsConnected()
}

func (t *OneMeTransport) Send(data []byte) error {
	if t.ch == nil {
		return fmt.Errorf("MAX call is not connected")
	}
	if err := t.ch.Send(data); err != nil {
		t.b.SetConnected(false)
		return err
	}
	t.b.RecordSend(len(data))
	return nil
}
