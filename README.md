# GRIB Downloader

A command-line tool that downloads marine weather (wind, waves, and
ocean currents) for a specific area and time window, and packages it
for **OpenCPN**, **qtVlm**, and **XyGrib**.

It was built because XyGrib's own built-in GRIB downloader stopped
working. This replaces it, using the same public data sources
(NOAA/NOMADS, HYCOM, ECMWF, DWD) directly.

- `grib_downloader.sh` — the tool itself (interactive menu)
- `install_grib_downloader.sh` — checks for, explains, and installs
  everything the tool needs

This document matches **v2.23**. If your copy is newer and has
options not described here (extra models, extra menu items), the
core ideas below still apply — just adjust the specifics to match
what's on your screen.

---

## Why this exists the way it does

**This tool is deliberately built to download only the area, time
window, and fields you actually ask for — never the full global
forecast.**

NOMADS, HYCOM, ECMWF, and DWD publish free, public weather data as a
service to the community, running on shared infrastructure with
finite bandwidth. A full global GFS run at 0.25° resolution, every
variable, every forecast hour, is gigabytes per download. Multiply
that by every sailor who wants a GRIB before heading out, and it adds
up fast — for servers that are free to use precisely because most
people don't do that.

So the whole design of this tool works backward from one rule:
**ask the server to do the subsetting, not your disk.** You tell it
your bounding box (say, a 500 nm cruising area, not the planet), how
many days of forecast you actually need, and which fields matter to
you (wind, waves, currents — not all of GFS's few hundred variables).
It builds a request that asks NOMADS/HYCOM/ECMWF/DWD for *exactly and
only that*, using the same server-side filtering those services
already provide for this purpose. Nothing about "the whole forecast"
ever touches your disk or their bandwidth.

This isn't just politeness for its own sake — it's self-preserving.
NOMADS and HYCOM both rate-limit and can temporarily ban IPs that
hammer them with oversized or excessive requests. Grabbing more data
than you need doesn't just waste everyone's bandwidth, it's also the
most likely way to get *your own* access cut off. A few other things
in the tool exist for the same reason:

- **Parallel-download limits per model**, with a built-in prober
  ([6] Probe parallel limit) that finds your safe ceiling before you
  hit it the hard way.
- **A cycle tracker** that knows when the next GFS run is due, so you
  aren't re-downloading a forecast that hasn't changed yet.
- **Satellite mode**, which throttles itself further for slow links
  instead of retrying aggressively.
- **Aggressive mode exists, but is opt-in and labeled with a warning**
  — it's there for when you genuinely know what you're doing, not
  the default.

If you take one thing from this document: set your area tight, set
your forecast length to what the passage actually needs, and leave
the defaults alone unless you have a reason not to.

---

## What it actually does

1. You set an area (a lat/lon box), pick a model, pick which
   variables you want, and set a forecast length.
2. It builds a NOMADS/HYCOM/ECMWF/DWD request for exactly that
   subset and downloads it with `curl`.
3. For ocean currents, it converts the NetCDF data HYCOM/RTOFS
   publish into GRIB2 (for OpenCPN/qtVlm) *and* a separate GRIB1
   file (for XyGrib, which can't read GRIB2 currents at all).
4. It assembles everything into two folders so each app only ever
   sees a file it can actually read:

```
~/Downloads/Gribs/
  atmos/ waves/ rtofs/ hycom/     raw per-source downloads
  OpenCPN/                        <- point OpenCPN / qtVlm here
    <tags>_<days>d_<stamp>Z.grib2   wind + wave + currents, merged
    GFS_All_latest.grib2            -> symlink to the newest one
  Xygrib/                          <- point XyGrib here
    <tags>_<days>d_<stamp>Z.grib2   wind + wave only, NO currents
    GFS_WindWave_latest.grib2       -> symlink to the newest one
    *_Currents_XyGrib.grb           currents, GRIB1, its own file
```

Models supported: **GFS** (wind), **GFS-Wave**, **RTOFS** and
**HYCOM** (ocean currents), **ECMWF**, and any combination the menu
offers.

---

## Requirements

Built and tested on **Debian/Ubuntu-family Linux** (this includes
Zorin, Mint, Pop!_OS, and similar). It relies on GNU-specific tools
(`date -u -d`, `stat -c`, bash arrays) and is not expected to work on
macOS's default `/bin/bash` or BSD userland without changes.

| Tool | Needed for |
|---|---|
| `curl` | everything — this is the actual downloader |
| `cdo` | converting RTOFS/HYCOM currents, and the ICON model |
| eccodes tools (`grib_get`/`grib_set`/`grib_copy`/`grib_ls`) | building the XyGrib GRIB1 currents file |
| `python3` + `xarray` + `netCDF4` | cleaning missing-data values in current data before conversion |
| `wgrib2` | only if you use the ICON model |
| `ecmwf-opendata` (pip) | only if you use the ECMWF model |

You don't need to track these down yourself — the installer does it.

---

## Installing

1. Put `grib_downloader.sh` and `install_grib_downloader.sh` in the
   same folder.
2. Run the installer:

   ```bash
   chmod +x install_grib_downloader.sh
   ./install_grib_downloader.sh
   ```

   It explains what each dependency does, checks whether you already
   have it, and asks before installing anything. Safe to re-run any
   time — it only ever touches what's still missing.

3. Say yes when it offers to install the command itself. This copies
   `grib_downloader.sh` to `~/.local/bin/grib-downloader` so you can
   just type `grib-downloader` from anywhere. If `~/.local/bin` isn't
   already on your `PATH`, the installer tells you the one line to
   add to `~/.bashrc`.

**Unattended install** (e.g. scripted setup, or piped straight from
wherever you're hosting this):

```bash
./install_grib_downloader.sh --yes
```

**Uninstalling** the command (leaves your system/Python packages and
your downloaded GRIBs alone — only removes the shim):

```bash
./install_grib_downloader.sh --uninstall
```

Full option list: `./install_grib_downloader.sh --help`

---

## Running it

```bash
grib-downloader
```

(or `./grib_downloader.sh` if you're running it in place instead of
installing it)

First run, set these up in order:

| Key | Sets |
|---|---|
| `[1]` | Area — your lat/lon box. Enter the two corners in any order; it sorts them for you. |
| `[2]` | Model — GFS wind, GFS-Wave, currents (RTOFS/HYCOM), ECMWF, or a combination |
| `[N]` | Forecast length — quick picker (1/2/3/5/7/10 days) |
| `[3]` | Variables — toggle which fields you actually want |
| `[5]` | Download options — parallel connections, output folder, timeouts |

Everything you set is saved to `~/.grib_downloader.conf` and reused
next time, so this is mostly a one-time setup.

Then:

| Key | Does |
|---|---|
| `[D]` | Download — runs a pre-check, fetches only what's missing, converts and combines it |
| `[6]` | Probe your safe parallel-download limit for the current model |
| `[7]` | Satellite mode — slower link preset (fewer connections, longer timeouts) |
| `[S]` | Shows the GFS release schedule so you know when the next cycle lands |
| `[C]` | Clean old files |
| `[M]` | Re-combine without re-downloading |
| `[H]` | Full in-app help |
| `[Q]` | Save and quit |

Ctrl+C during a download cancels cleanly back to the menu — whatever
already downloaded is kept, and the next `[D]` picks up from there
instead of starting over.

---

## Being a good citizen of shared weather infrastructure

Worth repeating on its own, since it's the whole point of the tool:

- **Keep your area small.** A bounding box around your actual
  cruising ground, not an ocean basin.
- **Keep the forecast length to what the passage needs.** A weekend
  hop doesn't need 10 days of data.
- **Don't reach for aggressive/high-parallel mode as a default.**
  It exists for people who've already confirmed their connection and
  the server's tolerance can handle it — not as a "download faster"
  button.
- **Let the cycle tracker do its job.** Re-running `[D]` right after
  a previous run won't re-fetch anything already on disk; the next
  new cycle isn't published any faster by asking more often.

None of this is enforced by force — the tool doesn't stop you from
setting a huge area or a long forecast. It's just built so that the
*easy*, default path is the considerate one, and the excessive path
takes deliberate effort (and comes with a warning) to reach.

---

## Troubleshooting

- **"cdo requires..." / "eccodes tools missing"** — run
  `./install_grib_downloader.sh` again; it only installs what's
  still missing.
- **ICON model refuses to run** — needs `wgrib2`, which isn't
  packaged for Debian/Ubuntu. The installer will tell you your
  options (conda-forge, or build from source) when it's missing.
- **ECMWF model refuses to run** — needs the `ecmwf-opendata` Python
  package; same installer handles it.
- **Downloads keep failing / getting throttled** — run `[6]` to find
  your safe parallel-download ceiling for the current model, and
  make sure Aggressive mode `[9]` is off.
- **XyGrib shows currents but OpenCPN/qtVlm don't, or vice versa** —
  make sure each app is pointed at its *own* folder (`OpenCPN/` or
  `Xygrib/`), not at the raw per-source folders or each other's.

---

## Not affiliated with

NOAA/NOMADS, HYCOM, ECMWF, DWD, OpenCPN, qtVlm, or XyGrib. This tool
is an independent client that uses their public data services and
file formats — please use it in a way that keeps those services free
and available for everyone else too.
