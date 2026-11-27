// The panel's only script: passkeys (navigator.credentials), on the pages that offer them. It talks only to the
// panel itself; the page's Content Security Policy allows no other script and no other address.
"use strict";
(() => {
  const enc = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const dec = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)),
    (c) => c.charCodeAt(0)).buffer;

  async function post(url, csrf, body) {
    const r = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
      body: JSON.stringify(body ?? {}),
    });
    if (!r.ok) throw new Error(r.status);
    return r.status === 204 ? {} : r.json();
  }

  function asJSON(cred) {
    if (typeof cred.toJSON === "function") return cred.toJSON();
    const r = cred.response, out = { id: cred.id, rawId: enc(cred.rawId), type: cred.type, response: {} };
    for (const k of ["clientDataJSON", "attestationObject", "authenticatorData", "signature", "userHandle"]) {
      if (r[k]) out.response[k] = enc(r[k]);
    }
    return out;
  }

  async function register(el) {
    const name = document.getElementById(el.dataset.nameField).value.trim();
    if (!name) return;
    const { publicKey } = await post(el.dataset.begin, el.dataset.csrf);
    publicKey.challenge = dec(publicKey.challenge);
    publicKey.user.id = dec(publicKey.user.id);
    for (const c of publicKey.excludeCredentials ?? []) c.id = dec(c.id);
    const cred = await navigator.credentials.create({ publicKey });
    return post(el.dataset.finish + "?name=" + encodeURIComponent(name), el.dataset.csrf, asJSON(cred));
  }

  async function signin(el) {
    const { publicKey } = await post(el.dataset.begin, el.dataset.csrf);
    publicKey.challenge = dec(publicKey.challenge);
    for (const c of publicKey.allowCredentials ?? []) c.id = dec(c.id);
    const cred = await navigator.credentials.get({ publicKey });
    return post(el.dataset.finish, el.dataset.csrf, asJSON(cred));
  }

  for (const el of document.querySelectorAll("[data-passkey]")) {
    if (!window.PublicKeyCredential) { el.hidden = true; continue; }
    el.addEventListener("click", async (ev) => {
      ev.preventDefault();
      const status = document.getElementById(el.dataset.status);
      el.disabled = true;
      try {
        const res = await (el.dataset.passkey === "register" ? register(el) : signin(el));
        location.assign(res?.redirect ?? location.pathname);
      } catch (e) {
        if (status) status.textContent = el.dataset.failed;
        el.disabled = false;
      }
    });
  }
})();
