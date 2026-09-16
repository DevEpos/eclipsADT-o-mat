# eclipse ADT Bundler

A Windows PowerShell wizard that builds you a ready-to-use ABAP development
environment: it downloads a chosen Eclipse release, installs SAP's
[ABAP Development Tools (ADT)](https://tools.hana.ondemand.com/#abap), and
lets you pick additional ADT features to install alongside it - this repo's
own [DevEpos features](../README.md) plus a small curated list of well-known
third-party ADT extensions.

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
  pwsh -ExecutionPolicy Bypass -File .\Setup-AdtEclipse.ps1
  ```

  or once per user session: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## Usage

### Interactive wizard

```shell
cd installer
.\Setup-AdtEclipse.ps1
```

You can also start the wizard from Windows Explorer by double-clicking
`Start-AdtEclipse.cmd`. It opens PowerShell 7, runs from the installer folder,
and keeps the console window open after the run so errors and the log location
remain visible.

You'll be prompted for:
1. The Eclipse release train to install (e.g. `2025-06`) - the latest
   supported version is preselected.
2. The install directory (an `eclipse` subfolder is created there).
3. Which additional plugins to install alongside ADT (multi-select: toggle a
   number, `a` = all, `n` = none, Enter to confirm).

The wizard then downloads the matching "Eclipse IDE for Java Developers"
package (cached locally so re-runs don't re-download), extracts it, and runs
the Eclipse p2 director headlessly to install ADT and your chosen plugins.

### Unattended / scripted usage

```shell
.\Setup-AdtEclipse.ps1 -NonInteractive -EclipseVersion 2025-06 `
    -InstallPath C:\dev\eclipse-adt `
    -Features devepos-search-tools,devepos-tags
```

Use `-ListFeatures` to print all available Eclipse versions and plugin ids
without installing anything:

```shell
.\Setup-AdtEclipse.ps1 -ListFeatures
```

### Parameters

| Parameter          | Description                                                                 |
|---------------------|-------------------------------------------------------------------------------|
| `-InstallPath`      | Target directory (an `eclipse` subfolder is created inside it). Defaults to `.\eclipse-adt`. |
| `-EclipseVersion`   | Eclipse release train id, e.g. `2025-06`. Required with `-NonInteractive`.   |
| `-Features`         | Array of plugin ids from `catalog.json` to install (non-interactive mode only). |
| `-NonInteractive`   | Suppresses all prompts.                                                      |
| `-CacheDirectory`   | Where downloaded Eclipse zips are cached. Defaults to `%LOCALAPPDATA%\AdtBundler\cache`. |
| `-ListFeatures`     | Prints the catalog contents and exits.                                       |

## How it works / architecture

```shell
installer/
  Setup-AdtEclipse.ps1   # main wizard entry point (interactive + unattended)
  Start-AdtEclipse.cmd   # Explorer-friendly launcher for the interactive wizard
  catalog.json            # data-driven catalog: Eclipse versions, ADT repo(s)
                           # + installable units, DevEpos + third-party plugins
  lib/
    Download.ps1           # cache-aware download + Eclipse zip extraction
    P2Director.ps1          # wrapper around eclipsec.exe's p2 director
    Menu.ps1                # console menu / multi-select prompt helpers
    Logging.ps1             # console + file logging
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
  and `p2/.../profileRegistry` folder name).
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
(2023-09, 2024-12, 2025-06): full ADT install and a DevEpos feature both
install successfully into a fresh "Eclipse IDE for Java Developers"
download with no manual repository configuration beyond what's already in
`catalog.json`.

## Extending the catalog

`catalog.json` is fully data-driven - no script changes are needed to add a
new Eclipse release train or a new plugin.

- **New Eclipse version**: add an entry to `eclipseVersions`. The download
  URL is built from `eclipseDownload.urlTemplate` with `{version}` replaced.
- **New plugin**: add an entry to `plugins` with `id`, `name`, `description`,
  `category`, `repoUrl` (the plugin's p2 update site) and `installableUnits`
  (the feature group id(s) to install, e.g. `com.example.foo.feature.group`).
  You can find a plugin's feature group id by browsing its p2 repository's
  `content.xml` (inside `content.xml.xz`/`content.jar`) for
  `<unit id='...feature.group' ...>` entries, or by adding the site in the
  Eclipse UI (Help > Install New Software) and inspecting the available
  features there.

## Troubleshooting

- **"Cannot complete the install... could not be found"**: usually means the
  Eclipse release train and the ADT/plugin repo versions don't correspond, or
  a transitive dependency isn't available from the repos listed for that
  entry in `catalog.json`. Check the run's log file under `installer/logs/`
  for the exact missing requirement id, and see if it needs to be added to
  `additionalRepoUrlTemplates`/`installableUnits` for that catalog entry.
- **Script won't run ("execution of scripts is disabled")**: see the
  Requirements section above.
- **Slow/failed downloads**: re-run the script - completed downloads are
  cached in `-CacheDirectory` and won't be re-fetched; partial downloads are
  cleaned up automatically and retried.
