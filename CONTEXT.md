# MacCast domain glossary

## Capture source

Something the host can stream now: a display, a running application, or a window.

## Running application

A user-facing application process that currently owns capturable content. It has a process
identity and can therefore be selected as a capture source.

## Installed application

A user-facing application available on the host but not currently running. It can be launched,
but it is not a capture source until it becomes a running application.

## Application catalogue

The host's current, user-facing list of running and installed applications. Background agents,
menu extras, helper processes, and duplicate instances are not applications in this catalogue.

## Recent session history

The newest twenty finished connections shown on one device. It is a bounded troubleshooting and
usage window, not an all-time ledger. Its summary counts those visible sessions, their connected
time, and their video bytes. The iPhone may temporarily retain additional hidden records that still
overlap the relay's current 24-hour allowance window; they exist only to keep quota estimates
correct and are pruned when that window moves on.
