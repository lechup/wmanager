# Languages

The screen (console lines, questions, notifications) speaks one of: English (`en`, the default), German (`de`),
French (`fr`), Spanish (`es`), Italian (`it`), Polish (`pl`), Dutch (`nl`), Portuguese (`pt`), Romanian (`ro`) and
Czech (`cs`). The first of these that is set wins:

1. `-Lang` of the script: `run.cmd -Lang de`, `init.cmd -Lang fr`, `pwsh ./init.ps1 -Lang it`, or `-Lang pl` for the
   internet installer;
2. the environment variable `WMANAGER_LANG`, set before the run (`set WMANAGER_LANG=de`, `$env:WMANAGER_LANG = 'de'`)
   in a console that already runs as administrator: `run.cmd` started from a normal console asks for administrator
   rights and continues in a new console, which doesn't get the variable (use `run.cmd -Lang de` there);
3. the Windows display language: the system's for the scheduled tasks (they run as SYSTEM), the signed-in user's for
   the restart notification;
4. English.

The log file and Loki are always in English, so every computer reads the same in Grafana and searches and alerts don't
depend on the language. Yes/no questions take the answer in the chosen language and in English (`y`, `yes`).
The internet installer's own few lines are English (`install.ps1` must stay plain ASCII).

The messages are in `lang\<code>\<area>.psd1`; English is the source, and a message missing in another language falls
back to English. `tests\Lang.Tests.ps1` checks that every language has every message with the same placeholders.
To add a language: copy `lang\en` to `lang\<code>`, translate it and add the code to `$WmLanguages` in `lib\Lang.ps1`.

## wmanager-server's panel and wmanager-sign

The panel speaks the same ten, chosen by `?lang=` (kept in a cookie) or the browser's language, its messages in
`server/internal/web/lang/<code>.json`. `wmanager-sign` speaks them too: `-lang`, then `WMANAGER_LANG`, then the
system's locale (`LC_ALL`, `LC_MESSAGES`, `LANG`), else English; its messages are in
`sign/internal/app/lang/<code>.json`, checked the same way (`TestLanguages`: every message, the same arguments, the
same lines). Signing asks for the word "yes" in the language shown (`word.yes`), or in English; an accent may be
left out.
