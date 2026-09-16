# eclipsADT-o-Mat

A Windows PowerShell wizard that builds you a ready-to-use ABAP development
environment: it downloads a chosen Eclipse release, installs SAP's
[ABAP Development Tools (ADT)](https://tools.hana.ondemand.com/#abap), and
lets you pick additional ADT features to install alongside it:

| Name                                    | Publisher | URL                                                                                     |
|------------------------------------------|-----------|------------------------------------------------------------------------------------------|
| ABAP Search and Analysis Tools           | DevEpos   | https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/search-tools           |
| ABAP Tags                                | DevEpos   | https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/tags                   |
| ABAP Code Search                         | DevEpos   | https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/code-search            |
| PDT Tools (ADT Plugin Development Tools) | DevEpos   | https://github.com/DevEpos/eclipse-adt-plugins/tree/main/features/pdt-tools              |
| ABAP cleaner                             | SAP       | https://github.com/SAP/abap-cleaner                                                      |
| ABAP Favorites                           | ABAPBlog  | https://github.com/fidley/ABAPFavorites                                                  |
| ABAP Quick Fix                           | ABAPBlog  | https://github.com/fidley/ABAPQuickFix                                                   |
| ADT Classic Outline                      | ABAPBlog  | https://github.com/fidley/ADT-Classic-Outline-Frontend                                   |
| ADT Extensions - Commands                | ABAPBlog  | https://github.com/fidley/ABAP-Project-Extensions                                        |
| Vertical Tabs                            | ABAPBlog  | https://github.com/fidley/VerticalTabs                                                   |
| Vertical Tabs ABAP Specific Features     | ABAPBlog  | https://github.com/fidley/VerticalTabs                                                   |
| GitHub Copilot                           | Microsoft | https://github.com/microsoft/copilot-for-eclipse/                                        |

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

### Interactive wizard

```shell
.\Setup-EclipsAdtOMat.ps1
```

You can also start the wizard from Windows Explorer by double-clicking
`Start-EclipsAdtOMat.cmd`. It opens PowerShell 7, runs from the repo folder,
and keeps the console window open after the run so errors and the log location
remain visible.

You'll be prompted for:
1. The base Eclipse package to install: "Eclipse IDE for Java Developers"
   (default), "Eclipse IDE for RCP and RAP Developers" (for Eclipse
   plug-in/PDE development), or "Eclipse Platform" (minimal core runtime
   only, no language tooling - everything, including ADT, is added via p2
   afterwards).
2. The Eclipse release train to install (e.g. `2026-09`) - the latest
   version supported by the chosen base package is preselected. Note that
   the "Eclipse Platform" package is only available for a curated subset of
   release trains (see `catalog.json`'s `basePackages[].downloads`).
3. The install directory. Press `B` at this prompt to choose a folder in
  Windows Explorer, or type a path directly. If it already exists, Eclipse
  is placed in an `eclipse` subfolder; a new directory is used as the
  Eclipse root.
4. Which additional plugins to install alongside ADT (multi-select: toggle a
   number, `a` = all, `n` = none, Enter to confirm).
5. If you selected any DevEpos plugin: which DevEpos channel to use for all
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

  Use `-DevEposChannel dev` to install selected DevEpos plugins from the
  development channel. The default is `latest`, and one channel is always used
  for all selected DevEpos plugins.

Use `-ListFeatures` to print all available base packages, Eclipse versions and
plugin ids without installing anything:

```shell
.\Setup-EclipsAdtOMat.ps1 -ListFeatures
```

### Parameters

| Parameter          | Description                                                                 |
|---------------------|-------------------------------------------------------------------------------|
| `-InstallPath`      | Target directory. An `eclipse` subfolder is used only when the target already exists. Defaults to `.\eclipse-adt`. |
| `-BasePackage`      | Base Eclipse package id from `catalog.json`: `java` (default), `rcp` or `platform`. |
| `-EclipseVersion`   | Eclipse release train id, e.g. `2026-09`. Required with `-NonInteractive`. Must be supported by `-BasePackage`. |
| `-Features`         | Array of plugin ids from `catalog.json` to install (non-interactive mode only). |
| `-DevEposChannel`   | DevEpos channel for all selected DevEpos plugins: `dev` or `latest` (default: `latest`). |
| `-NonInteractive`   | Suppresses all prompts.                                                      |
| `-CacheDirectory`   | Where downloaded Eclipse zips are cached. Defaults to `%LOCALAPPDATA%\eclipsADT-o-Mat\cache`. |
| `-ListFeatures`     | Prints the catalog contents and exits.                                       |

## How it works / architecture

```shell
Setup-EclipsAdtOMat.ps1   # main wizard entry point (interactive + unattended)
Start-EclipsAdtOMat.cmd   # Explorer-friendly launcher for the interactive wizard
catalog.json            # data-driven catalog: base packages, Eclipse versions,
                         # ADT repo(s) + installable units, DevEpos channels/plugins
                         # + third-party plugins
lib/
  Download.ps1           # cache-aware download + Eclipse zip extraction
  P2Director.ps1          # wrapper around eclipsec.exe's p2 director
  Menu.ps1                # console menu / multi-select prompt helpers
  Logging.ps1             # console + file logging
  Ui.ps1                  # banner, theming, spinner, notifications
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
(2023-09, 2024-12, 2026-09): full ADT install and a DevEpos feature both
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
  `category`, `repoUrl` (the plugin's p2 update site) and `installableUnits`
  (the feature group id(s) to install, e.g. `com.example.foo.feature.group`).
  If the plugin needs Eclipse's Terminal view (absent from the minimal
  `platform` base package), set `"requiresTerminal": true` instead of adding
  a fixed terminal feature id - the script resolves the correct id for the
  selected Eclipse version from the top-level `terminalFeature` entry (Eclipse
  replaced the old `org.eclipse.tm.terminal` feature with `org.eclipse.terminal`
  starting with the 2025-09 release train).
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
