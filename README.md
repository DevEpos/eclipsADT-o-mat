# eclipsADT-o-Mat

A Windows PowerShell wizard that builds you a ready-to-use ABAP development
environment: it downloads a chosen Eclipse release, installs SAP's
[ABAP Development Tools (ADT)](https://tools.hana.ondemand.com/#abap), and
lets you pick additional ADT features to install alongside it:

> See the [step-by-step walkthrough](docs/walkthrough.md) for a visual tour
> of the wizard.

| Name                                     | Publisher          | URL                                                                              |
| ---------------------------------------- | ------------------ | -------------------------------------------------------------------------------- |
| ABAP Search and Analysis Tools           | DevEpos            | <https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/search-tools> |
| ABAP Tags                                | DevEpos            | <https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/tags>         |
| ABAP Code Search                         | DevEpos            | <https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/code-search>  |
| PDT Tools (ADT Plugin Development Tools) | DevEpos            | <https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/pdt-tools>    |
| ABAP cleaner                             | SAP                | <https://github.com/SAP/abap-cleaner>                                            |
| abapGit for ABAP Development Tools (ADT) | abapGit            | <https://eclipse.abapgit.org/>                                                   |
| ABAP Favorites                           | ABAPBlog           | <https://github.com/fidley/ABAPFavorites>                                        |
| ABAP Quick Fix                           | ABAPBlog           | <https://github.com/fidley/ABAPQuickFix>                                         |
| ADT Classic Outline                      | ABAPBlog           | <https://github.com/fidley/ADT-Classic-Outline-Frontend>                         |
| ADT Extensions - Commands                | ABAPBlog           | <https://github.com/fidley/ABAP-Project-Extensions>                              |
| Vertical Tabs                            | ABAPBlog           | <https://github.com/fidley/VerticalTabs>                                         |
| Vertical Tabs ABAP Specific Features     | ABAPBlog           | <https://github.com/fidley/VerticalTabs>                                         |
| GitHub Copilot                           | Microsoft          | <https://github.com/microsoft/copilot-for-eclipse/>                              |
| Eclipse Marketplace Client               | Eclipse Foundation | <https://marketplace.eclipse.org/>                                               |
| Enhanced Class Decompiler                | Pascal Bihler      | <https://ecd-plugin.github.io/> (requires the RCP base package)                  |

It is a lightweight alternative to an Eclipse Installer/Oomph setup: no
external tooling is required beyond PowerShell and the Eclipse package itself
(which bundles the `p2 director` used to drive the actual installation).

## Requirements

- Windows with PowerShell 7+ (`pwsh`).
- Internet access to `download.eclipse.org` / `archive.eclipse.org`,
  `tools.hana.ondemand.com`, `eclipse.devepos.com`, and any third-party
  plugin sites you select.
- Because script execution is disabled by default on many Windows machines,
  you may need to allow the script to run, e.g.:

  ```shell
  pwsh -ExecutionPolicy Bypass -File .\Setup-EclipsAdtOMat.ps1
  ```

  or once per user session: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## Usage

### Single-file download (recommended)

Download `eclipsADT-o-mat.cmd` from the
[latest release](https://github.com/DevEpos/eclipsADT-o-mat/releases/latest)
and **double-click it** - no command line and no execution-policy setup
needed (the launcher starts PowerShell 7 with `-ExecutionPolicy Bypass`
itself; only [PowerShell 7](https://aka.ms/powershell) must be installed).
It bundles all scripts and the catalog into one file.

Prefer a plain PowerShell script? Download `eclipsADT-o-mat.ps1` instead and
run:

```shell
pwsh -ExecutionPolicy Bypass -File .\eclipsADT-o-mat.ps1
```

On startup the single-file release checks GitHub for a newer release and
offers to update itself in place. All parameters described below work
identically.

### Interactive wizard

```shell
.\Setup-EclipsAdtOMat.ps1
```

You can also start the wizard from Windows Explorer by double-clicking
`Start-EclipsAdtOMat.cmd`. It opens PowerShell 7, runs from the repo folder,
and keeps the console window open after the run so errors and the log location
remain visible.

You'll be prompted for:

1. Whether to create a new Eclipse installation or add ADT and plugins to an
   existing one. When modifying an existing installation, you only pick its
   folder - the Eclipse version and base package are detected automatically
   and the base package / release selection steps are skipped.
2. The base Eclipse package to install: "Eclipse IDE for Java Developers"
   (default), "Eclipse IDE for RCP and RAP Developers" (for Eclipse
   plug-in/PDE development), or "Eclipse Platform" (minimal core runtime
   only, no language tooling - everything, including ADT, is added via p2
   afterwards). Unlike the other packages, the "Eclipse Platform" package
   ships without an embedded JRE; if no Java 21+ runtime is found on the
   machine, the wizard automatically downloads an
   [Eclipse JustJ](https://eclipse.dev/justj/) JRE into the installation's
   `jre` folder so Eclipse can launch.
3. The Eclipse release train to install (e.g. `2026-09`) - the latest
   version supported by the chosen base package is preselected. Note that
   the "Eclipse Platform" package is only available for a curated subset of
   release trains (see `catalog.json`'s `basePackages[].downloads`).
4. The install directory. Press `B` at this prompt to choose a folder in
  Windows Explorer, or type a path directly. If it already exists, Eclipse
  is placed in an `eclipse` subfolder; a new directory is used as the
  Eclipse root. Folders that already contain an Eclipse installation are
  rejected - use the "modify" mode for those.
5. Which additional plugins to install alongside ADT (multi-select: toggle a
   number, `a` = all, `n` = none, Enter to confirm).
6. If you selected any DevEpos plugin: which DevEpos channel to use for all
   selected DevEpos plugins: `dev` or `latest`.

The wizard then downloads the matching base Eclipse package (cached locally
so re-runs don't re-download it), extracts it, and runs the Eclipse p2
director headlessly to install ADT and your chosen plugins.

### Unattended / scripted usage

```shell
.\Setup-EclipsAdtOMat.ps1 -NonInteractive -BasePackage java -EclipseVersion 2026-09 `
    -InstallPath C:\dev\eclipse-adt `
    -Features devepos-search-tools,devepos-tags
```

  Use `-BasePackage rcp` or `-BasePackage platform` to install onto a
  different base package. Defaults to `java` when omitted.

  Use `-Mode Modify` to add ADT and plugins to an existing installation at
  `-InstallPath` - its Eclipse version and base package are detected
  automatically, so `-EclipseVersion` is not required. The default
  `-Mode New` fails if the target folder already contains an Eclipse
  installation.

  Use `-DevEposChannel dev` to install selected DevEpos plugins from the
  development channel. The default is `latest`, and one channel is always used
  for all selected DevEpos plugins.

Use `-ListFeatures` to print all available base packages, Eclipse versions and
plugin ids without installing anything:

```shell
.\Setup-EclipsAdtOMat.ps1 -ListFeatures
```

### Parameters

| Parameter          | Description                                                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-Mode`            | `New` (default) creates a fresh installation and fails if the target contains an Eclipse; `Modify` adds ADT/plugins to an existing one.                                    |
| `-InstallPath`     | Target directory (`New`: an `eclipse` subfolder is used when the target already exists; `Modify`: folder of the existing installation). Defaults to `~\Documents\eclipse`. |
| `-BasePackage`     | Base Eclipse package id from `catalog.json`: `java` (default), `rcp` or `platform`. Auto-detected with `-Mode Modify`.                                                     |
| `-EclipseVersion`  | Eclipse release train id, e.g. `2026-09`. Required with `-NonInteractive` unless `-Mode Modify` (auto-detected). Must be supported by `-BasePackage`.                      |
| `-Features`        | Array of plugin ids from `catalog.json` to install (non-interactive mode only).                                                                                            |
| `-DevEposChannel`  | DevEpos channel for all selected DevEpos plugins: `dev` or `latest` (default: `latest`).                                                                                   |
| `-NonInteractive`  | Suppresses all prompts.                                                                                                                                                    |
| `-CacheDirectory`  | Where downloaded Eclipse zips are cached. Defaults to `%LOCALAPPDATA%\eclipsADT-o-Mat\cache`.                                                                              |
| `-ListFeatures`    | Prints the catalog contents and exits.                                                                                                                                     |
| `-SkipUpdateCheck` | Skips the startup check for a newer release (single-file distribution only; also skipped with `-NonInteractive`).                                                          |

### Updating the sources

The single-file release checks the GitHub releases on startup and, after
confirmation, downloads the newer version over itself and restarts.

When running from a repo checkout, update the sources manually with
`git pull` (or re-download the repository zip from GitHub).

## How it works / architecture

```shell
Setup-EclipsAdtOMat.ps1   # main wizard entry point (interactive + unattended)
Start-EclipsAdtOMat.cmd   # Explorer-friendly launcher for the interactive wizard
catalog.json            # data-driven catalog: base packages, Eclipse versions,
                         # ADT repo(s) + installable units, DevEpos channels/plugins
                         # + third-party plugins
lib/
  Catalog.ps1             # catalog loading + base-package/version lookup helpers
  Download.ps1            # cache-aware download + Eclipse zip extraction
  EclipseInstall.ps1      # detects/validates existing Eclipse installations (Mode Modify)
  EclipseReleaseCheck.ps1 # scrapes Eclipse for new release trains, updates catalog.json
  JreProvision.ps1        # downloads a JustJ JRE for the JVM-less 'platform' package
  P2Director.ps1          # wrapper around eclipsec.exe's p2 director
  Menu.ps1                # console menu / multi-select prompt helpers
  Logging.ps1             # console + file logging
  Ui.ps1                  # banner, theming, spinner, notifications
  Wizard.ps1              # orchestrates the interactive/unattended wizard steps
  ReleaseUpdate.ps1       # release-based self-update (single-file distribution)
build/
  New-Bundle.ps1          # builds the single-file release script (CI: release.yml)
logs/                     # created at runtime, one log file per run
```

Under the hood, the wizard downloads the official Eclipse "Java Developers"
package for the selected release train, extracts it, then repeatedly invokes:

```shell
eclipsec.exe -application org.eclipse.equinox.p2.director ^
    -repository <repo1,repo2,...> -installIU <iu1,iu2,...> ^
    -destination <path-to-eclipse> -profile epp.package.java -followReferences
```

- `epp.package.java` is the p2 profile id used by "Eclipse IDE for Java
  Developers" downloads (confirmed via the extracted install's `config.ini`
  and `p2/.../profileRegistry` folder name). Other base packages use their
  own profile id (e.g. `epp.package.rcp`); `Invoke-P2Director` auto-detects
  the correct profile from the extracted install, so no per-package script
  changes are needed.
- ADT's p2 repo (`https://tools.hana.ondemand.com/<version>`) **must** be
  paired with the matching Eclipse release train - mixing versions causes
  core platform bundle version-range failures.
- ADT's full feature set (`com.sap.adt.core.feature.group`, which includes
  CDS/DDIC/debugger tooling - DevEpos's own features depend on some of these)
  transitively requires a few EMF sub-features
  (`org.eclipse.emf.workspace.feature.group`,
  `org.eclipse.emf.databinding.edit.feature.group`,
  `org.eclipse.emf.validation.feature.group`) that are **not** bundled in the
  base Java Developers package. They must be requested from
  `https://download.eclipse.org/releases/<version>` **in the same director
  call** as ADT itself - requesting them one at a time across separate calls
  only ever surfaces the next missing dependency instead of resolving
  cleanly. `catalog.json`'s `adt` entry already encodes this (see
  `additionalRepoUrlTemplates` and the extra entries in `installableUnits`).

This was all verified end-to-end against real Eclipse/ADT release pairs
(2024-09, 2024-12, 2026-09): full ADT install and a DevEpos feature both
install successfully into a fresh "Eclipse IDE for Java Developers"
download with no manual repository configuration beyond what's already in
`catalog.json`.

## Extending the catalog

`catalog.json` is fully data-driven - no script changes are needed to add a
new Eclipse release train, base package or plugin.

- **New Eclipse version**: add an entry to `eclipseVersions`. For
  template-based base packages (`java`, `rcp`), the download URL is built
  from that package's `urlTemplate` with `{version}` replaced - nothing else
  to do. The `platform` package instead uses a `downloads` map keyed by the
  version id, because its zip filenames embed a build-specific timestamp
  (e.g. `R-4.36-202505281830`) that can't be derived from `{version}` alone;
  find the matching build under
  [download.eclipse.org/eclipse/downloads/drops4](https://download.eclipse.org/eclipse/downloads/drops4/)
  (or its [archive](https://archive.eclipse.org/eclipse/downloads/drops4/)),
  then add its "Platform Runtime Binary" Windows x86_64 zip URL (plus an
  `archive.eclipse.org` fallback) to `platform.downloads` for the new version
  id. If no entry is added, the `platform` package simply won't offer that
  version.
- **New base package**: add an entry to `basePackages` with `id`, `name`,
  `description`, and either `urlTemplate`/`fallbackUrlTemplate` (if the
  package follows the EPP release naming pattern) or a `downloads` map (for
  packages needing per-version URLs).
- **New plugin**: add an entry to `plugins` with `id`, `name`, `description`,
  `publisher`, `repoUrl` (the plugin's p2 update site) and `installableUnits`
  (the feature group id(s) to install, e.g. `com.example.foo.feature.group`).
  `repoUrl` may be omitted if the feature ships as part of the standard
  `https://download.eclipse.org/releases/<version>` release train repo
  already paired with every plugin install (e.g. the Eclipse Marketplace
  Client).
  If the plugin needs Eclipse's Terminal view (absent from the minimal
  `platform` base package), set `"requiresTerminal": true` instead of adding
  a fixed terminal feature id - the script resolves the correct id for the
  selected Eclipse version from the top-level `terminalFeature` entry (Eclipse
  replaced the old `org.eclipse.tm.terminal` feature with `org.eclipse.terminal`
  starting with the 2025-09 release train).
  If the plugin only works with certain base packages, set `"requiresBasePackage"`
  to an array of the allowed base package id(s) (e.g. `["rcp"]`) - it is then
  hidden from the interactive multi-select and rejected via `-Features` unless
  a matching base package was chosen.
- DevEpos plugins use the channel repository selected in the `devepos.channels`
  section. Do not add a per-plugin DevEpos repository, since mixing channels is
  unsupported.
  You can find a plugin's feature group id by browsing its p2 repository's
  `content.xml` (inside `content.xml.xz`/`content.jar`) for
  `<unit id='...feature.group' ...>` entries, or by adding the site in the
  Eclipse UI (Help > Install New Software) and inspecting the available
  features there.

## Troubleshooting

- **"Cannot complete the install... could not be found"**: usually means the
  Eclipse release train and the ADT/plugin repo versions don't correspond, or
  a transitive dependency isn't available from the repos listed for that
  entry in `catalog.json`. Check the run's log file under `logs/`
  for the exact missing requirement id, and see if it needs to be added to
  `additionalRepoUrlTemplates`/`installableUnits` for that catalog entry.
  Note: every third-party plugin install is already paired with the
  matching `https://download.eclipse.org/releases/<version>` repo (in
  addition to the plugin's own `repoUrl`) so bundles like
  `org.eclipse.lsp4e` or `com.ibm.icu` - present in the full EPP packages
  but missing from the minimal `platform` base package - can still resolve.
- **Script won't run ("execution of scripts is disabled")**: see the
  Requirements section above.
- **Slow/failed downloads**: re-run the script - completed downloads are
  cached in `-CacheDirectory` and won't be re-fetched; partial downloads are
  cleaned up automatically and retried.
