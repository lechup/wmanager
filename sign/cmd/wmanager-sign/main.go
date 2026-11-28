// Command wmanager-sign signs what the computers of a company act on, with the administrator's security key, after
// showing it (docs/architecture.md, "wmanager-sign"). Built with -tags fido2 it uses security keys through
// libfido2; without, it can do everything but sign.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"

	"github.com/lechup/wmanager/sign/internal/app"
	"github.com/lechup/wmanager/sign/internal/fido"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
)

func main() {
	fs := flag.NewFlagSet("wmanager-sign", flag.ContinueOnError)
	server := fs.String("server", "", "the server, if not the one connected last")
	lang := fs.String("lang", "", "the language")
	fs.Usage = func() {}
	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	h, err := home.Default()
	if err != nil {
		fmt.Fprintln(os.Stderr, "wmanager-sign:", err)
		os.Exit(1)
	}
	in := bufio.NewReader(os.Stdin)
	a := &app.App{
		Home:   h,
		In:     in,
		Out:    os.Stdout,
		HTTP:   &http.Client{Timeout: time.Minute},
		Lang:   app.Language(*lang),
		Server: *server,
		ReadSecret: func(prompt string) (string, error) {
			fmt.Print(prompt)
			if term.IsTerminal(int(os.Stdin.Fd())) {
				b, err := term.ReadPassword(int(os.Stdin.Fd()))
				fmt.Println()
				return string(b), err
			}
			line, err := in.ReadString('\n')
			if err != nil && line == "" {
				return "", err
			}
			return strings.TrimRight(line, "\r\n"), nil
		},
	}
	a.OpenDevice = func() (fido.Device, error) {
		return fido.Open(func(names []string) (int, error) {
			for i, n := range names {
				fmt.Printf("%d) %s\n", i+1, show.Visible(n))
			}
			fmt.Printf("(1-%d)? ", len(names))
			line, err := in.ReadString('\n')
			if err != nil && line == "" {
				return 0, err
			}
			n, err := strconv.Atoi(strings.TrimSpace(line))
			return n - 1, err
		})
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	err = a.Run(ctx, fs.Args())
	switch {
	case err == nil:
	case errors.Is(err, app.ErrUsage):
		a.Run(ctx, []string{"help"})
		os.Exit(2)
	default:
		fmt.Fprintln(os.Stderr, "wmanager-sign:", err)
		os.Exit(1)
	}
}
