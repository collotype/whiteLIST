package transport

import (
	"bytes"
	"testing"
)

func TestCompressionRoundTrip(t *testing.T) {
	want := bytes.Repeat([]byte("OpenFlux packet payload"), 100)
	encoded := compress(want)
	got, err := decompress(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("packet changed after compression round trip")
	}
}
