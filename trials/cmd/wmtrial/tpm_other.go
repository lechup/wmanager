//go:build !windows

package main

import "errors"

func tpmTrial() error { return errors.New("the TPM trial runs on Windows") }
