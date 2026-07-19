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

func TestOmittedStaticNIFCopies(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		{
			name: "crypto shared copy",
			path: "opt/fips-elixir/lib/erlang/lib/crypto-5.9.1/priv/lib/crypto.so",
			want: true,
		},
		{
			name: "crypto test engine",
			path: "opt/fips-elixir/lib/erlang/lib/crypto-5.9.1/priv/lib/otp_test_engine.so",
			want: true,
		},
		{
			name: "ASN.1 shared copy",
			path: "opt/fips-elixir/lib/erlang/lib/asn1-5.5/priv/lib/asn1rt_nif.so",
			want: true,
		},
		{
			name: "FIPS provider",
			path: "opt/fips-elixir/lib/ossl-modules/fips.so",
			want: false,
		},
		{
			name: "static NIF build helper",
			path: "opt/fips-elixir/lib/erlang/erts-17.0.3/bin/yielding_c_fun",
			want: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := omitted(test.path); got != test.want {
				t.Fatalf("omitted(%q) = %t, want %t", test.path, got, test.want)
			}
		})
	}
}

func TestDynamicInterpreterAllowed(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		{
			name: "BEAM",
			path: "opt/fips-elixir/lib/erlang/erts-17.0.3/bin/beam.smp",
			want: true,
		},
		{
			name: "OpenSSL command",
			path: "opt/fips-elixir/bin/openssl",
			want: true,
		},
		{
			name: "OTP child helper",
			path: "opt/fips-elixir/lib/erlang/erts-17.0.3/bin/erl_child_setup",
			want: false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := dynamicInterpreterAllowed(test.path); got != test.want {
				t.Fatalf("dynamicInterpreterAllowed(%q) = %t, want %t", test.path, got, test.want)
			}
		})
	}
}
