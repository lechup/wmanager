// Command wmtrial runs the trials of stage 0 (docs/trials.md) on a test virtual machine. It is not part of
// wmanager: it goes away when the stages take over its code.
//
//	wmtrial settag <in.exe> <out.exe> <text>   put a tag into a signed exe (on any system)
//	wmtrial append <in.exe> <out.exe> <text>   append data after the signature, the old way (a control)
//	wmtrial tag                                print the tag of this exe
//	wmtrial tpm                                make, use and delete a key in the TPM (Windows)
package main

import (
	"fmt"
	"os"

	"github.com/lechup/wmanager/internal/certtag"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: wmtrial settag|append <in.exe> <out.exe> <text> | tag | tpm")
	}
	switch os.Args[1] {
	case "settag":
		if len(os.Args) != 5 {
			fail("usage: wmtrial settag <in.exe> <out.exe> <text>")
		}
		in, err := os.ReadFile(os.Args[2])
		check(err)
		out, err := certtag.Set(in, []byte(os.Args[4]))
		check(err)
		check(os.WriteFile(os.Args[3], out, 0o644))
		fmt.Printf("tagged: %d -> %d bytes\n", len(in), len(out))
	case "append":
		if len(os.Args) != 5 {
			fail("usage: wmtrial append <in.exe> <out.exe> <text>")
		}
		in, err := os.ReadFile(os.Args[2])
		check(err)
		out, err := certtag.AppendAfterSignature(in, []byte(os.Args[4]))
		check(err)
		check(os.WriteFile(os.Args[3], out, 0o644))
		fmt.Printf("appended: %d -> %d bytes\n", len(in), len(out))
	case "tag":
		exe, err := os.Executable()
		check(err)
		b, err := os.ReadFile(exe)
		check(err)
		tag, ok, err := certtag.Get(b)
		check(err)
		if !ok {
			fmt.Println("no tag")
			return
		}
		fmt.Printf("tag: %s\n", tag)
	case "tpm":
		check(tpmTrial())
	default:
		fail("unknown command " + os.Args[1])
	}
}

func check(err error) {
	if err != nil {
		fail(err.Error())
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "wmtrial:", msg)
	os.Exit(1)
}
