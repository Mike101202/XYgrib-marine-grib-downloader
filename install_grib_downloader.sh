#!/bin/bash
# ============================================================
#  GRIB Downloader - Setup / Dependency Installer
#  Version: 1.1 - 2026-09-15
# ============================================================
#  Checks for everything grib_downloader.sh needs, explains what
#  each piece does and why it's needed, and - only with your
#  permission - installs whatever is missing.
#
#  Safe to re-run any time; it only ever installs what's missing.
#
#  Tested on Debian/Ubuntu (apt). Other package managers get a
#  best-effort attempt with a clear "unverified" warning, plus the
#  manual install command either way so you're never stuck.
#
#  Options:
#    -y, --yes       Non-interactive: assume yes to every prompt.
#    --uninstall     Remove ~/.local/bin/grib-downloader only.
#    -h, --help      Show usage and exit.
# ============================================================

set -u

# ---------- Display helpers ----------
if [ -t 1 ]; then
    C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"
    C_BOLD="\033[1m";   C_DIM="\033[2m";  C_RESET="\033[0m"
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

heading() { echo; echo -e "${C_BOLD}== $1 ==${C_RESET}"; }
info()    { echo -e "  $1"; }
good()    { echo -e "  ${C_GREEN}[present]${C_RESET} $1"; }
missing() { echo -e "  ${C_RED}[missing]${C_RESET} $1"; }
warn()    { echo -e "  ${C_YELLOW}note:${C_RESET} $1"; }

ASSUME_YES=0

ask_yn() {
    # ask_yn "question" -> returns 0 for yes, 1 for no. Defaults to yes.
    # Under --yes, auto-accepts (and says so) instead of prompting.
    if [ "$ASSUME_YES" -eq 1 ]; then
        echo -e "  ${C_DIM}$1 [Y/n]: y  (auto-accepted: --yes)${C_RESET}"
        return 0
    fi
    local reply
    read -r -p "  $1 [Y/n]: " reply
    case "$reply" in
        n|N|no|No|NO) return 1 ;;
        *) return 0 ;;
    esac
}

do_uninstall() {
    echo "============================================================"
    echo "  GRIB Downloader - Uninstall"
    echo "============================================================"
    local target="$HOME/.local/bin/grib-downloader"
    if [ ! -e "$target" ]; then
        info "Nothing to do: $target doesn't exist."
    elif ask_yn "Remove $target?"; then
        rm -f "$target"
        good "Removed $target"
    else
        warn "Left in place."
    fi
    echo
    echo "This only ever removes the command shim this installer"
    echo "creates. Left untouched, in case anything else depends on"
    echo "them or you want to keep them:"
    echo "  System packages : curl, cdo, wgrib2, libeccodes-tools"
    echo "  Python packages : xarray, netCDF4, ecmwf-opendata"
    echo "  Your config     : ~/.grib_downloader.conf"
    echo "  Your downloads  : wherever OUTPUT_DIR points (e.g. ~/Downloads/Gribs)"
    echo "============================================================"
}

DO_UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        --uninstall) DO_UNINSTALL=1 ;;
        -h|--help)
            cat <<USAGE
Usage: $0 [OPTIONS]

  -y, --yes      Non-interactive: assume yes to every prompt. Installs
                 everything missing, and installs the grib-downloader
                 command if found alongside this script. Useful for
                 piping into a one-liner install.

      --uninstall
                 Remove ~/.local/bin/grib-downloader (the command shim
                 this installer creates). Does not touch any system
                 packages (curl, cdo, wgrib2, eccodes) or Python
                 packages (xarray, netCDF4, ecmwf-opendata) -- only
                 the shim.

  -h, --help     Show this help and exit.
USAGE
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Try: $0 --help" >&2
            exit 1
            ;;
    esac
done

if [ "$DO_UNINSTALL" -eq 1 ]; then
    do_uninstall
    exit 0
fi

# ---------- Privilege / package manager detection ----------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        warn "Not running as root and no 'sudo' found. System package installs below will likely fail; you may need to install those manually as root."
    fi
fi

PKG_MANAGER="none"
if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1;    then PKG_MANAGER="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG_MANAGER="pacman"
elif command -v brew >/dev/null 2>&1;   then PKG_MANAGER="brew"
fi

APT_UPDATED=0
install_system_pkgs() {
    # $1 = space-separated apt package names (also used to derive best-guess
    # equivalents for other managers below).
    local apt_pkgs="$1"
    case "$PKG_MANAGER" in
        apt)
            if [ "$APT_UPDATED" -eq 0 ]; then
                $SUDO apt-get update -qq && APT_UPDATED=1
            fi
            # shellcheck disable=SC2086
            $SUDO apt-get install -y $apt_pkgs
            ;;
        dnf)
            warn "Fedora/RHEL package names can differ from Debian's; this is a best-effort attempt, not verified."
            # shellcheck disable=SC2086
            $SUDO dnf install -y $apt_pkgs
            ;;
        pacman)
            warn "Arch package names can differ from Debian's; this is a best-effort attempt, not verified."
            # shellcheck disable=SC2086
            $SUDO pacman -S --noconfirm $apt_pkgs
            ;;
        brew)
            warn "Homebrew package names can differ from Debian's; this is a best-effort attempt, not verified. Also see the macOS caveat below."
            # shellcheck disable=SC2086
            brew install $apt_pkgs
            ;;
        *)
            echo "  No supported package manager detected (looked for apt-get, dnf, pacman, brew)."
            echo "  Install manually: $apt_pkgs"
            return 1
            ;;
    esac
}

pip_install() {
    # Modern Debian/Ubuntu (PEP 668) refuse a plain "pip install --user"
    # with "externally-managed-environment". Try the normal way first;
    # only fall back to --break-system-packages (still --user, so it
    # only touches this user's own site-packages) if that's why it failed.
    if python3 -m pip install --user "$@" 2>/tmp/pip_err.log; then
        return 0
    fi
    if grep -qi "externally-managed-environment" /tmp/pip_err.log; then
        warn "pip is externally-managed here (PEP 668); retrying with --break-system-packages (still --user, so only your own packages are touched)."
        python3 -m pip install --user --break-system-packages "$@"
        return $?
    fi
    cat /tmp/pip_err.log >&2
    return 1
}

echo "============================================================"
echo "  GRIB Downloader - Setup"
echo "============================================================"
echo "This script checks for the tools grib_downloader.sh needs,"
echo "explains what each one does, and offers to install anything"
echo "that's missing. Nothing is installed without asking first."
echo
echo "Platform note: grib_downloader.sh uses GNU-specific tools"
echo "(date -u -d, stat -c, bash arrays) and was built and tested"
echo "on Debian/Ubuntu-family Linux (this includes Zorin, Mint,"
echo "Pop!_OS, etc.). It is not expected to work on macOS's default"
echo "/bin/bash or BSD userland tools without extra changes."
if [ "$PKG_MANAGER" = "brew" ]; then
    echo
    warn "Homebrew detected -- you're likely on macOS. The installer"
    warn "will still try, but grib_downloader.sh itself may need"
    warn "GNU coreutils (brew install coreutils gnu-sed) to run at all."
fi
if [ "$ASSUME_YES" -eq 1 ]; then
    echo "(--yes given: skipping confirmation, proceeding automatically)"
else
    read -r -p "Press Enter to begin, or Ctrl+C to stop."
fi

# ============================================================
# GROUP 1 - Core (required for anything to work at all)
# ============================================================
heading "1. Core - required for every model"
info "curl"
info "  The actual downloader. Every GRIB file this tool fetches --"
info "  GFS wind, GFS-Wave, RTOFS currents, HYCOM currents, ECMWF,"
info "  ICON -- comes down over HTTP via curl. Nothing downloads"
info "  without it."
info "  How you'd use it yourself: curl -O <url>  (the script does"
info "  this internally; you never need to run it by hand)."
echo
have_curl=0
if command -v curl >/dev/null 2>&1; then good "curl ($(curl --version | head -1))"; have_curl=1
else missing "curl"; fi

if [ "$have_curl" -eq 0 ]; then
    if ask_yn "Install curl now?"; then
        install_system_pkgs "curl"
        command -v curl >/dev/null 2>&1 && good "curl installed" || missing "curl install failed - install manually"
    else
        warn "Skipping curl. The downloader cannot fetch anything without it."
    fi
fi

# ============================================================
# GROUP 2 - Currents conversion (RTOFS / HYCOM -> GRIB2 and GRIB1)
# ============================================================
heading "2. Ocean currents conversion - RTOFS and HYCOM"
info "cdo (Climate Data Operators)"
info "  Converts the NetCDF ocean-current data that HYCOM and RTOFS"
info "  provide into GRIB format, and merges/renames variables along"
info "  the way. Required any time you download RTOFS or HYCOM"
info "  currents, and for the ICON model's own GRIB2 packaging."
info "  How you'd use it yourself: cdo -h  (the script calls it"
info "  internally; direct use isn't needed for normal operation)."
echo
info "eccodes command-line tools (grib_get, grib_set, grib_copy, grib_ls)"
info "  ECMWF's own reference GRIB library tools. Used to rewrite GRIB1"
info "  header fields (originating centre, parameter codes, packing)"
info "  so XyGrib's older GRIB1 reader accepts the current-vector"
info "  files, and to double-check the result before writing it out."
info "  Needed only for the *_Currents_XyGrib.grb companion files."
info "  How you'd use it yourself: grib_ls somefile.grib2  (lists the"
info "  fields in any GRIB file - handy for troubleshooting)."
echo
info "python3 + xarray + netCDF4 (Python packages)"
info "  Reads the NetCDF current files and replaces missing-data"
info "  sentinels (NaN for HYCOM, a -9e33 fill value for RTOFS) before"
info "  conversion, so current vectors don't come out as zero or"
info "  garbage. Required for RTOFS/HYCOM currents."
echo
have_cdo=0; have_eccodes=0; have_py=0; have_pip=0; have_xr=0
command -v cdo >/dev/null 2>&1 && { good "cdo"; have_cdo=1; } || missing "cdo"
if command -v grib_get >/dev/null 2>&1 && command -v grib_set >/dev/null 2>&1 \
   && command -v grib_copy >/dev/null 2>&1 && command -v grib_ls >/dev/null 2>&1; then
    good "eccodes tools"; have_eccodes=1
else
    missing "eccodes tools (grib_get/grib_set/grib_copy/grib_ls)"
fi
if command -v python3 >/dev/null 2>&1; then good "python3 ($(python3 --version 2>&1))"; have_py=1
else missing "python3"; fi
if [ "$have_py" -eq 1 ] && python3 -m pip --version >/dev/null 2>&1; then good "pip"; have_pip=1
else missing "pip (python3-pip)"; fi
if [ "$have_py" -eq 1 ] && python3 -c "import xarray, netCDF4" 2>/dev/null; then
    good "xarray + netCDF4"; have_xr=1
else
    missing "xarray + netCDF4 (Python packages)"
fi

if [ "$have_cdo" -eq 0 ] || [ "$have_eccodes" -eq 0 ] || [ "$have_py" -eq 0 ] \
   || [ "$have_pip" -eq 0 ] || [ "$have_xr" -eq 0 ]; then
    if ask_yn "Install the missing currents-conversion tools now?"; then
        [ "$have_cdo" -eq 0 ] && install_system_pkgs "cdo"
        [ "$have_eccodes" -eq 0 ] && install_system_pkgs "libeccodes-tools"
        [ "$have_py" -eq 0 ] && install_system_pkgs "python3"
        [ "$have_pip" -eq 0 ] && install_system_pkgs "python3-pip"
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "import xarray, netCDF4" 2>/dev/null || \
                pip_install xarray netCDF4
        fi
        echo
        info "Re-checking:"
        command -v cdo >/dev/null 2>&1 && good "cdo" || missing "cdo - install failed, try: sudo apt install cdo"
        if command -v grib_get >/dev/null 2>&1 && command -v grib_set >/dev/null 2>&1 \
           && command -v grib_copy >/dev/null 2>&1 && command -v grib_ls >/dev/null 2>&1; then
            good "eccodes tools"
        else
            missing "eccodes tools - install failed, try: sudo apt install libeccodes-tools"
        fi
        python3 -c "import xarray, netCDF4" 2>/dev/null && good "xarray + netCDF4" || \
            missing "xarray/netCDF4 - install failed, try: python3 -m pip install --user --break-system-packages xarray netCDF4"
    else
        warn "Skipping. RTOFS and HYCOM currents will fail to convert without these."
    fi
fi

# ============================================================
# GROUP 3 - ICON model (DWD)
# ============================================================
heading "3. Optional - only needed for the ICON model"
info "wgrib2"
info "  Repacks GRIB2 output to 'simple' packing, which qtVlm reads"
info "  more reliably, and handles the DWD ICON model's own GRIB2"
info "  processing. Required if you plan to use the ICON model."
info "  Also used, optionally, to repack HYCOM current files for"
info "  qtVlm -- the script skips that step gracefully if wgrib2"
info "  isn't installed, so it's not a hard requirement outside ICON."
info "  How you'd use it yourself: wgrib2 somefile.grib2 -V  (prints"
info "  a detailed inventory of every field in the file)."
echo
have_wgrib2=0
command -v wgrib2 >/dev/null 2>&1 && { good "wgrib2"; have_wgrib2=1; } || missing "wgrib2"

if [ "$have_wgrib2" -eq 0 ]; then
    if ask_yn "Install wgrib2 now? (skip this if you won't use the ICON model)"; then
        install_system_pkgs "wgrib2"
        command -v wgrib2 >/dev/null 2>&1 && good "wgrib2 installed" || {
            warn "wgrib2 didn't install via $PKG_MANAGER."
            if [ "$PKG_MANAGER" = "apt" ]; then
                warn "Debian/Ubuntu don't package wgrib2 at all (confirmed: apt reports"
                warn "'Unable to locate package'). Two working options instead:"
                warn "  1) If you have conda/miniforge: conda install -c conda-forge wgrib2"
                warn "  2) Build from source (NOAA-EMC): https://github.com/NOAA-EMC/wgrib2"
            else
                warn "Fedora/RHEL (via EPEL) do package it; if this is a different distro,"
                warn "try: conda install -c conda-forge wgrib2, or build from source:"
                warn "https://github.com/NOAA-EMC/wgrib2"
            fi
        }
    else
        warn "Skipping wgrib2. The ICON model will refuse to run without it; everything else is unaffected."
    fi
fi

# ============================================================
# GROUP 4 - ECMWF model
# ============================================================
heading "4. Optional - only needed for the ECMWF model"
info "ecmwf-opendata (Python package)"
info "  ECMWF's own client library for pulling their free, public"
info "  open-data forecasts. Only used if you select the ECMWF model;"
info "  every other model ignores it completely."
echo
have_ecmwf_lib=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import ecmwf.opendata" 2>/dev/null; then
    good "ecmwf-opendata"; have_ecmwf_lib=1
else
    missing "ecmwf-opendata"
fi

if [ "$have_ecmwf_lib" -eq 0 ]; then
    if ask_yn "Install ecmwf-opendata now? (skip this if you won't use the ECMWF model)"; then
        if command -v python3 >/dev/null 2>&1; then
            pip_install ecmwf-opendata
            python3 -c "import ecmwf.opendata" 2>/dev/null && good "ecmwf-opendata installed" || \
                missing "install failed - try: python3 -m pip install --user --break-system-packages ecmwf-opendata"
        else
            missing "python3 isn't installed - install that first (see Group 2 above)"
        fi
    else
        warn "Skipping. The ECMWF model will refuse to run without it; everything else is unaffected."
    fi
fi

# ============================================================
# Place the script itself
# ============================================================
heading "5. Install the grib_downloader.sh command itself"
# When piped (curl ... | bash -s -- --yes), BASH_SOURCE has no useful
# value -- there is no on-disk installer file to look "next to". Under
# set -u, ${BASH_SOURCE[0]} on an empty array is itself a hard error, so
# default it instead of letting that crash the whole run.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
CANDIDATE=""
if [ -n "$SCRIPT_DIR" ]; then
    for name in grib_downloader.sh; do
   # for name in grib_downloader.sh grib_downloader_v2_23.sh; do
        [ -f "$SCRIPT_DIR/$name" ] && { CANDIDATE="$SCRIPT_DIR/$name"; break; }
    done
else
    info "Running from a pipe (no installer file on disk), so there's"
    info "nothing to look 'next to'. Download grib_downloader.sh, put"
    info "this installer in the same folder, and run it directly"
    info "(not piped) if you want the command shim installed."
fi
if [ -z "$CANDIDATE" ]; then
    warn "Couldn't find grib_downloader.sh next to this installer, so this step is skipped."
    warn "Put install_grib_downloader.sh in the same folder as grib_downloader.sh and re-run this if you want it installed as a command."
else
    info "Found: $CANDIDATE"
    if ask_yn "Install it as the 'grib-downloader' command in ~/.local/bin?"; then
        mkdir -p "$HOME/.local/bin"
        cp -f "$CANDIDATE" "$HOME/.local/bin/grib-downloader"
        chmod +x "$HOME/.local/bin/grib-downloader"
        good "Installed to ~/.local/bin/grib-downloader"
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) : ;;
            *)
                warn "~/.local/bin isn't on your PATH yet. Add this to ~/.bashrc, then open a new terminal:"
                info "    export PATH=\"\$HOME/.local/bin:\$PATH\""
                ;;
        esac
        echo
        info "Run it with:  grib-downloader"
    fi
fi

# ============================================================
# Summary
# ============================================================
heading "Done"
echo "Final status:"
command -v curl   >/dev/null 2>&1 && good "curl"   || missing "curl (required - nothing downloads without it)"
command -v cdo    >/dev/null 2>&1 && good "cdo"    || missing "cdo (required for RTOFS/HYCOM currents + ICON)"
if command -v grib_get >/dev/null 2>&1 && command -v grib_set >/dev/null 2>&1 \
   && command -v grib_copy >/dev/null 2>&1 && command -v grib_ls >/dev/null 2>&1; then
    good "eccodes tools"
else
    missing "eccodes tools (required for the XyGrib currents companion file)"
fi
python3 -c "import xarray, netCDF4" 2>/dev/null && good "xarray + netCDF4" || \
    missing "xarray + netCDF4 (required for RTOFS/HYCOM currents)"
command -v wgrib2 >/dev/null 2>&1 && good "wgrib2" || missing "wgrib2 (only needed for the ICON model)"
python3 -c "import ecmwf.opendata" 2>/dev/null && good "ecmwf-opendata" || \
    missing "ecmwf-opendata (only needed for the ECMWF model)"
echo
echo "You can re-run this installer any time -- it only touches"
echo "whatever's still missing."
echo "============================================================"
