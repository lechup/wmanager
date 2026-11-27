package main

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/lechup/wmanager/internal/tpmkey"
)

const keyName = "wmanager-trial"

func tpmTrial() error {
	for _, provider := range []string{tpmkey.PlatformProvider, tpmkey.SoftwareProvider} {
		fmt.Printf("== %s\n", provider)
		if err := oneProvider(provider); err != nil {
			fmt.Printf("   FAILED: %v\n", err)
		}
	}
	return nil
}

func oneProvider(provider string) error {
	start := time.Now()
	k, err := tpmkey.Create(provider, keyName)
	if err != nil {
		return err
	}
	fmt.Printf("   created in %v\n", time.Since(start).Round(time.Millisecond))
	if pt := k.PlatformType(); pt != "" {
		fmt.Printf("   platform: %s\n", pt)
	}
	spki, err := x509.MarshalPKIXPublicKey(k.Public())
	if err != nil {
		return err
	}
	id := sha256.Sum256(spki)
	fmt.Printf("   computer id (SHA-256 of the public key): %s\n", hex.EncodeToString(id[:]))
	digest := sha256.Sum256([]byte("wmanager request\x00trial"))
	start = time.Now()
	sig, err := k.SignDigest(digest[:])
	if err != nil {
		return err
	}
	fmt.Printf("   signed in %v, verify: %v\n", time.Since(start).Round(time.Millisecond),
		ecdsa.VerifyASN1(k.Public(), digest[:], sig))
	k.Close()

	again, err := tpmkey.Open(provider, keyName)
	if err != nil {
		return fmt.Errorf("open again: %w", err)
	}
	same := again.Public().Equal(k.Public())
	sig, err = again.SignDigest(digest[:])
	if err != nil {
		return err
	}
	fmt.Printf("   opened again: same key %v, verify: %v\n", same, ecdsa.VerifyASN1(again.Public(), digest[:], sig))
	if err := again.Delete(); err != nil {
		return err
	}
	if _, err := tpmkey.Open(provider, keyName); err == nil {
		return fmt.Errorf("the key is still there after delete")
	}
	fmt.Println("   deleted")
	return nil
}
