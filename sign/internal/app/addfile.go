package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"maps"
	"os"
	"path/filepath"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// MaxAddFile is the largest file add-file takes, as the server does.
const MaxAddFile = 4 << 30

// addFile adds a file from the administrator's own disk (an installer, a driver) to the company's next state at a
// path, and signs that state: the file is hashed as it is read here, given to the server, and kept in mind as added
// here, so a later state may name it without showing its content.
func (a *App) addFile(ctx context.Context, which, path, local string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	c, h, ch, err := a.held(ctx, s, which)
	if err != nil {
		return err
	}
	if c.Role != "admin" {
		return a.fail("err.notadmin", show.Visible(h.Name))
	}
	b, err := a.loadState(ctx, s, c, h, ch)
	if err != nil {
		return err
	}
	if b.st == nil {
		return a.fail("err.nostate", show.Visible(h.Name))
	}
	if abs, err := filepath.Abs(local); err == nil {
		local = abs
	}
	f, err := os.Open(local)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	if !fi.Mode().IsRegular() || fi.Size() > MaxAddFile {
		return a.fail("err.addfile", show.Visible(local))
	}
	sum := sha256.New()
	n, err := io.Copy(sum, f)
	if err != nil {
		return err
	}
	if n != fi.Size() {
		return a.fail("err.filechanged", show.Visible(local))
	}
	hash := [32]byte(sum.Sum(nil))
	hexHash := hex.EncodeToString(hash[:])

	serial, err := a.nextSerial(b)
	if err != nil {
		return err
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	next := *b.st
	next.SignedAt, next.Serial, next.Server = a.signedAt(), serial, s.client.Server
	next.Files = maps.Clone(b.st.Files)
	next.Files[path] = hexHash
	next.Secrets = maps.Clone(b.st.Secrets)
	if raw, err := verify.Marshal(next); err != nil {
		return err
	} else if _, err := verify.ParseState(raw); err != nil {
		return a.fail("err.badstate", err.Error())
	}
	typed, err := a.lackingValues(ctx, s, c, next.Secrets, nil)
	if err != nil {
		return err
	}

	// The server gets the file first: what it doesn't take isn't signed. It checks the hash again.
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	a.say("addfile.sending", show.Visible(local), n)
	if err := s.client.UploadFile(ctx, c.ID, hash, f, n); err != nil {
		if api.Status(err) == 503 {
			return a.fail("err.nofilesdir", err.Error())
		}
		return a.apiErr(s, err)
	}
	// Shown as added here while it is signed; kept as such only once it is (a file refused here isn't trusted).
	if h.Added == nil {
		h.Added = map[string]home.AddedFile{}
	}
	_, before := h.Added[hexHash]
	h.Added[hexHash] = home.AddedFile{From: local, Size: n, At: a.Now().UTC()}
	keep := false
	defer func() {
		if !keep && !before {
			delete(h.Added, hexHash)
		}
	}()

	a.say("state.next", serial, show.Visible(h.Name), verify.Fingerprint(ch.Company))
	if !a.showNext(ctx, s, c, h, b, &next) {
		return a.fail("err.unshown")
	}
	var secrets []api.Secret
	for _, name := range typed {
		v, err := a.ReadSecret(a.t("state.secretvalue", show.Visible(name)))
		if err != nil {
			return err
		}
		again, err := a.ReadSecret(a.t("state.secretagain"))
		if err != nil {
			return err
		}
		if v == "" || v != again {
			return a.fail("err.secretmismatch", show.Visible(name))
		}
		salt := make([]byte, verify.SecretSaltSize)
		rand.Read(salt)
		next.Secrets[name] = verify.SecretHash(ch.CompanyID(), name, salt, []byte(v))
		secrets = append(secrets, api.Secret{Name: name, Salt: salt, Value: []byte(v)})
	}
	raw, err := verify.Marshal(next)
	if err != nil {
		return err
	}
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	signed, err := a.signAsAdmin(s, ch, raw)
	if err != nil {
		return err
	}
	keep = true
	return a.submitState(ctx, s, c, h, ch, b, signed, "", secrets)
}
