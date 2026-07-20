package main

import (
	"reflect"
	"testing"
)

func TestAssignments(t *testing.T) {
	t.Parallel()
	want := [][2]string{{"BINDIR", "/sdk/erts/bin"}, {"EMU", "beam=smp"}}
	got, err := assignments("BINDIR=/sdk/erts/bin\nEMU=beam=smp")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("assignments() = %#v, want %#v", got, want)
	}
}

func TestAssignmentsRejectsMalformedInput(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"missing-separator", "=missing-key"} {
		if _, err := assignments(value); err == nil {
			t.Fatalf("assignments(%q) unexpectedly succeeded", value)
		}
	}
}
