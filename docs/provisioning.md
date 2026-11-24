# Provisioning

What a run does to a computer, the backup and how to undo it, the package list and the scheduled update.

## Provisioning steps

1. Check for Windows 11 and administrator rights, the management settings and signing certificate (if set),
   determine the computer name.
2. Check that the Chocolatey, package-list and management servers answer. Without internet the script asks whether
   to go on without installing programs (Enter = stop, nothing changed yet); the scheduled update installs them later.
3. System restore point. If it can't be created, the script asks whether to go on without it (Enter = stop).
   `run.cmd -SkipRestorePoint` skips the restore point and the question.
4. Backup of Store apps and the registry, and the start of the undo journal (see [Backup and restore](#backup-and-restore)).
   If it fails, the script asks the same way.
5. Copy files to `C:\ProgramData\wmanager` and set permissions.
6. Rename the computer (if a name was given; takes effect after a restart).
7. Debloat: apps from the `RemoveAppx` list (from the system image and for all users), OneDrive, policies, Edge.
   For DevHome and the new Outlook it also removes the Windows Update entries (`UScheduler_Oobe`) that would install
   them again minutes after removal. An installation Windows has already started (in the first minutes after setup)
   can still finish once; the next scheduled update removes the app again.
8. Privacy: telemetry, the `DiagTrack` and `dmwappushservice` services, ads, suggestions, local-only search.
9. Chocolatey, package sources, installing the packages from the list (with a management source: the common list
   plus the lists of the computer's groups).
10. Chrome as the default browser for new accounts (DISM); existing users get the Settings page once.
11. Register the scheduled tasks (folder `\wmanager\`; `wmanager-Jobs` and `wmanager-Logon` only with a management
    source).

With a management source, provisioning doesn't run the group scripts itself: it runs as the person at the console,
and scripts must run as SYSTEM. `wmanager-Jobs` runs them a few minutes after provisioning (or right after the restart).

User settings are applied to every existing profile and to the default profile (new accounts).

### OneDrive

If Desktop, Documents or Pictures are redirected to OneDrive in any profile (local, domain or Entra ID account),
or a profile's registry cannot be checked, the script **does not remove** OneDrive on that computer
and writes a warning to the log.

## Backup and restore

Before changing anything, provisioning writes a backup to `C:\ProgramData\wmanager\state\backup\<date>\`
(readable only by Administrators and SYSTEM; the first backup, marked with `first.txt`, and the latest one are kept):

| File | Content |
| --- | --- |
| `appx-installed.csv`, `appx-provisioned.csv` | Store apps installed for users and in the system image |
| `oem-default-associations.xml` or `.none` | Default apps for new accounts (`System32\OEMDefaultAssociations.xml`, which DISM import writes), or a marker that there were none |
| `machine-NN.reg`, `user-pNN-<profile>-NN.reg` | Registry branches that debloat and privacy change; user files use `HKEY_CURRENT_USER`, so that user can import them |
| `manifest.txt` | Which key went to which file, and which keys did not exist |

The undo journal `state\backup\journal.jsonl` records, for every registry value wmanager changes during provisioning,
its state before the very first change (old value and type, or "did not exist"); for a key it deletes (the
`UScheduler_Oobe` entries) that means every value in it, so the key comes back on restore. Each entry is written the moment the
value changes, so an interrupted run loses nothing. It is shared by all provisioning runs.

To undo, run on the computer as administrator:

```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\wmanager\Restore-Backup.ps1
```

It asks for confirmation, then puts every journaled value back (or removes it, and removes keys wmanager created
if they are empty) for the computer and for every profile that still exists. Changes users made later in the same
keys are left alone. It also restores the default apps for new accounts from the first backup (or the Windows defaults
if there were none), lists Store apps
removed since then, and offers to disable the wmanager tasks (otherwise the scheduled update applies debloat again).
With the tasks disabled it also removes the wmanager signing certificate from the trusted root store.
Restart the computer afterwards.

Not undone: removed Store apps (reinstall from the Store) and OneDrive (reinstall from Microsoft), installed
Chocolatey packages, what group scripts changed, the computer name. Settings the scheduled update applies to profiles created after provisioning
are not in the journal, nor are `UScheduler_Oobe` entries that Windows created after provisioning and the scheduled update deleted. Programs and system files can be rolled back with the system restore point.

## choco-reqs.txt

```
googlechrome !noupdate        # install the latest, don't update (it updates itself)
libreoffice-fresh             # latest, kept up to date
libreoffice-fresh@latest      # same thing, written explicitly
7zip@24.8.0                   # pinned version (choco pin), never updated
vlc | --params "/NoDesktopShortcut"   # extra choco parameters
```

- Write a pinned version exactly as `choco list` shows it (e.g. `24.8.0`).
- Changing the version number in the list changes the installed version on the next run (downgrades too).
- A new package on the list is installed on the next run. Packages removed from the list are not uninstalled.
- The list is validated before use; an invalid line (unknown option, duplicate) rejects the whole source and the script moves on to the next one.

The list sources (`ReqsSources`) are tried in order: URL, share, file next to the script.
The last valid copy is kept in `C:\ProgramData\wmanager\state\choco-reqs.cache.txt` and is used when no source responds.

> Anyone who can change the list behind the URL can install programs as SYSTEM on every computer
> (the part after `|` goes straight to choco, so even `--source` pointing to their own server).
> Use HTTPS only, and a repository with restricted write access, or better a signed management source:
> with `Management.Source` set, `ReqsSources` is not used.

## Scheduled update

- `wmanager-Update` (SYSTEM): scheduled by `UpdateDays` and `UpdateTime`, every day at 12:00 by default
  (`UpdateDays = @('Monday')` makes it weekly). After a missed run it starts right after boot, so a computer that was
  off for a few days catches up with one run.
  It installs Chocolatey if it is missing, fetches the list, installs new packages, upgrades packages that are neither pinned nor `!noupdate`,
  reruns debloat and the privacy settings (`RerunDebloat`; the older name `RerunDebloatWeekly` still works) and
  updates its own schedule if the configuration changed.
- Computers set up before the daily default keep `UpdateDays = @('Monday')` in their `provision.config.psd1`; they
  switch when that file gets the new `UpdateDays` (or loses it), at their next update.
- A computer that is usually off at `UpdateTime` runs the missed update about 10 minutes after every boot (Windows waits
  that long with missed tasks), next to the hourly jobs. Pick an `UpdateTime` when the computers are usually on.
- A package whose program is running (`RunningProcessMap`) is deferred; `wmanager-Retry` tries again 2 minutes after sign-in.
  An empty process list (as for `rustdesk`, which always runs as a service) means the package is never deferred.
- When a restart is needed, `wmanager-Notify` shows the user a notification. The computer never restarts on its own.
- With a management source it also fetches and checks the source and runs the group scripts whose content changed
  or that failed before (after debloat). When the source names another wmanager version, it first switches to it
  (see [Updating wmanager](groups.md#updating-wmanager)).
- Runs never overlap. When the hourly `wmanager-Jobs` is busy (e.g. both start after a boot), the update waits up
  to 50 minutes for it; if it is still busy, `wmanager-Retry` does the full run at the next sign-in. The hourly
  run skips its turn when another run is busy, and provisioning waits up to 10 minutes.
- Without internet (the Chocolatey, package-list or management servers don't answer) the update changes nothing
  and reports nothing; `wmanager-Retry` does the full run at the next sign-in.

Manual run: `Start-ScheduledTask -TaskPath '\wmanager\' -TaskName 'wmanager-Update'`.
