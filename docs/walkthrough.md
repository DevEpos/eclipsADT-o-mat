# Step-by-Step Walkthrough

This page shows what running the eclipsADT-o-Mat wizard actually looks like,
step by step, from launch to a ready-to-use Eclipse + ADT installation.

## Installation mode (1/7)

Choose whether to create a new Eclipse installation or add ADT and plugins
to an existing one. When modifying an existing installation, you only pick
its folder - the Eclipse version and base package are detected automatically
and steps 2 and 3 below are skipped.

## Base Eclipse package selection (2/7)

Choose the base Eclipse package to install: "Eclipse IDE for Java
Developers", "Eclipse IDE for RCP and RAP Developers", or "Eclipse Platform"
(core runtime only).

![Eclipse type selection](1-eclipse-type-selection.png)

## Eclipse release train selection (3/7)

Pick the Eclipse release train to install. The latest version supported by
the chosen base package is preselected.

![Eclipse version selection](2-eclipse-version-selection.png)

## Installation folder selection (4/7)

Choose where Eclipse should be installed, or accept the suggested default
path. Folders that already contain an Eclipse installation are rejected -
restart and choose the "modify" mode to add ADT and plugins to one.

![Installation folder selection](3-installation-folder-selection.png)

## Plugin selection (5/7)

Select which additional ADT plugins to install alongside ADT itself, which
is always installed.

![Plugin selection](4-plugin-selection.png)

## Confirmation (6/7)

Review a summary of all selections before the download and installation
begins.

![Confirmation](5-confirmation.png)

## Installation summary (7/7)

Once installation finishes, a summary shows the status of every installed
component and the path to launch Eclipse.

![Installation summary](6-summary.png)
