package main

import "testing"

func TestSymlinkResolvesToSelf(t *testing.T) {
	tests := []struct {
		name        string
		destination string
		target      string
		want        bool
	}{
		{
			name:        "Bazel input transport symlink",
			destination: "opt/fips-elixir/lib/erlang/bin/erl",
			target:      "erl",
			want:        true,
		},
		{
			name:        "OTP runtime symlink",
			destination: "opt/fips-elixir/lib/erlang/bin/epmd",
			target:      "../erts-17.0.3/bin/epmd",
			want:        false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := symlinkResolvesToSelf(test.destination, test.target)
			if got != test.want {
				t.Fatalf("symlinkResolvesToSelf() = %t, want %t", got, test.want)
			}
		})
	}
}
