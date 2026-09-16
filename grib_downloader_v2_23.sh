#!/bin/bash
# ============================================================
# GRIB Downloader for XyGrib / OpenCPN / qtVlm
# Version: 2.23 - 2026-09-15
#
# v2.23 change:
#   * New output layout: OpenCPN/ and Xygrib/ destination folders.
#     combine_all() now writes the full merged GRIB2 (wind+wave+
#     currents) into OpenCPN/, and writes a SEPARATE wind/wave-only
#     GRIB2 plus the standalone GRIB1 currents companion into Xygrib/
#     -- currents are never merged into the XyGrib wind/wave file.
#     Raw per-source folders (atmos/, waves/, hycom/, rtofs/) and the
#     flat intermediate per-model files are unchanged. Stale GRIB1
#     companions from a previously-selected current source are cleared
#     from Xygrib/ before writing the current model's own file.
#
# v2.22 fix:
#   * convert_nc_to_xygrib_grib1(): the RTOFS-only identity check
#     compared every message to timeRangeIndicator==0 and P2==10.
#     A byte-level dump of a known-good Saildocs RTOFS GRIB1 file
#     shows timeRangeIndicator=10 with P2 holding the actual
#     forecast hour (0/24/48/72...), never a fixed 10 -- so the
#     check rejected 100% of messages regardless of input, which
#     is why RTOFS conversion always failed while HYCOM (which
#     skips this rtofs-only block) worked. The check now only
#     verifies centre/process/grid (confirmed correct from the
#     same dump) and warns instead of hard-failing on the rest.
#
# v2.16 fix:
#   * convert_nc_to_xygrib_grib1(): RTOFS GRIB2 uses a FINITE
#     fill sentinel (-9e33) rather than IEEE NaN. The Python
#     sanitizer's ~np.isfinite() check did not catch it, so cdo
#     packed GRIB1 across the range -9e33..+1.7, collapsing every
#     real value (order 0.1) to 0. The Python block now also
#     replaces any value outside ±1e10 with the same _FillValue
#     used for HYCOM's NaNs. HYCOM was already working because
#     its fill is true IEEE NaN.
#
# v2.15 fix:
#   * Python NaN cleanup removes pre-existing _FillValue from
#     attrs before setting it in encoding (RTOFS cdo-produced
#     NetCDF carries it in attrs; HYCOM does not).
#
# v2.14 fixes:
#   * Python sanitizer added for HYCOM's untagged IEEE NaNs.
#   * Invalid CF shortName/cfName assignments removed.
#   * GRIB1 failure reported as failure; no empty companion kept.
#   * RTOFS walks back up to 4 days for actual trop_paci files.
#   * pre_download_check: A && B || C replaced with if.
#   * probe_parallel: renamed local variable shadowing ls.
#
# Currents are produced in two formats:
#   <MODEL>_Currents.grib2        GRIB2 U/V  (OpenCPN, qtVlm)
#   <MODEL>_Currents_XyGrib.grb   GRIB1 U/V  (XyGrib)
#
# XyGrib GRIB1 target format (verified against working Saildocs
# RTOFS files):
#   edition=1, centre=kwbc(7), subCentre=0, table2Version=2,
#   indicatorOfParameter=49 (U) / 50 (V), typeOfLevel=surface,
#   level=0, gridType=regular_ll, packingType=grid_simple
# ============================================================

set -u
CONF="$HOME/.grib_downloader.conf"
STATUS="$HOME/.grib_downloader_status"
UA="XyGrib_unx/1.2.6 (compatible; grib-downloader/2.23)"

WAVE_PARALLEL_MAX="4"
RTOFS_PARALLEL_MAX="1"
HYCOM_PARALLEL_MAX="1"
ICON_PARALLEL_MAX="4"
ECMWF_PARALLEL_MAX="2"

LEFT_LON="145.22";  RIGHT_LON="156.04"
TOP_LAT="-15.67";   BOTTOM_LAT="-28.32"
RESOLUTION="0.25"
WAVE_RES="0p16"
ICON_RES="0p125"
MODEL="gfs_plus_wave"
VAR_PRECIP="y"; VAR_WIND="y"; VAR_WAVES="y"; VAR_SWELL="y"
VAR_GUST="y"; VAR_TEMP="y"; VAR_CAPE="n"; VAR_CLOUD="y"
VAR_HUMIDITY="n"; VAR_CURRENTS="n"; VAR_SEATEMP="n"
FORECAST_HOURS="240"; INTERVAL="3"
PARALLEL="4"; SLEEP="1"
OUTPUT_DIR="$HOME/Downloads/Gribs"
AGGRESSIVE="n"
SATELLITE="n"
COMPRESS="y"; RESUME="y"
CONNECT_TIMEOUT="20"; MAX_TIMEOUT="300"
RETRIES="2"
HYCOM_CONNECT_TIMEOUT="30"
HYCOM_MAX_TIMEOUT="900"
HYCOM_RETRIES="4"
HYCOM_DAYS="1"
AUTO_CLEAN="n"

SAFE_PARALLEL_gfs="4"
SAFE_PARALLEL_gfs_wave="4"
SAFE_PARALLEL_gfs_plus_wave="4"
SAFE_PARALLEL_gfs_plus_wave_rtofs="4"
SAFE_PARALLEL_gfs_plus_wave_hycom="4"
SAFE_PARALLEL_gfs_plus_wave_seatemp="4"
SAFE_PARALLEL_rtofs="2"
SAFE_PARALLEL_hycom="1"
SAFE_PARALLEL_ecmwf="2"
SAFE_PARALLEL_icon="4"
BANNED_PARALLEL_gfs="0"
BANNED_PARALLEL_gfs_wave="0"
BANNED_PARALLEL_gfs_plus_wave="0"
BANNED_PARALLEL_rtofs="0"
BANNED_PARALLEL_hycom="0"
BANNED_PARALLEL_ecmwf="0"
BANNED_PARALLEL_icon="0"
LAST_RATE="0"
LAST_CYCLE=""
BATCH_BYTES=0
BATCH_ERRORS=0

# ============================================================
# SECTION 1 - Config
# ============================================================
load_config() { [ -f "$CONF" ] && . "$CONF"; }
save_config() {
    {
        echo "# GRIB downloader config - auto $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for v in LEFT_LON RIGHT_LON TOP_LAT BOTTOM_LAT RESOLUTION WAVE_RES ICON_RES MODEL \
                 VAR_PRECIP VAR_WIND VAR_WAVES VAR_SWELL VAR_GUST VAR_TEMP \
                 VAR_CAPE VAR_CLOUD VAR_HUMIDITY VAR_CURRENTS VAR_SEATEMP \
                 FORECAST_HOURS INTERVAL PARALLEL SLEEP OUTPUT_DIR AGGRESSIVE \
                 SATELLITE COMPRESS RESUME CONNECT_TIMEOUT MAX_TIMEOUT RETRIES \
                 HYCOM_CONNECT_TIMEOUT HYCOM_MAX_TIMEOUT HYCOM_RETRIES HYCOM_DAYS AUTO_CLEAN \
                 WAVE_PARALLEL_MAX RTOFS_PARALLEL_MAX HYCOM_PARALLEL_MAX \
                 ICON_PARALLEL_MAX ECMWF_PARALLEL_MAX \
                 SAFE_PARALLEL_gfs SAFE_PARALLEL_gfs_wave SAFE_PARALLEL_gfs_plus_wave \
                 SAFE_PARALLEL_gfs_plus_wave_rtofs SAFE_PARALLEL_gfs_plus_wave_hycom \
                 SAFE_PARALLEL_rtofs SAFE_PARALLEL_hycom SAFE_PARALLEL_ecmwf SAFE_PARALLEL_icon \
                 BANNED_PARALLEL_gfs BANNED_PARALLEL_gfs_wave \
                 BANNED_PARALLEL_gfs_plus_wave BANNED_PARALLEL_rtofs BANNED_PARALLEL_hycom \
                 BANNED_PARALLEL_ecmwf BANNED_PARALLEL_icon \
                 LAST_RATE LAST_CYCLE; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$CONF"
}

# ============================================================
# SECTION 2 - Helpers
# ============================================================
ask() {
    local prompt="$1" default="$2" var
    read -r -p "$prompt [$default]: " var
    [ -z "$var" ] && var="$default"
    echo "$var"
}
yn() { [ "$1" = "y" ] && echo "Y" || echo "N"; }
size_of() { [ -f "$1" ] && stat -c %s "$1" 2>/dev/null || echo 0; }
human() {
    local b="$1"
    if [ "$b" -lt 1024 ]; then echo "${b} B"
    elif [ "$b" -lt 1048576 ]; then echo "$((b / 1024)) KB"
    elif [ "$b" -lt 1073741824 ]; then echo "$((b / 1048576)) MB"
    else echo "$((b / 1073741824)) GB"; fi
}
secs_to_hms() {
    printf "%02d:%02d:%02d" $(( $1/3600 )) $(( ($1%3600)/60 )) $(( $1%60 ))
}
res_token() {
    case "$RESOLUTION" in
        0.25) echo "0p25" ;;
        0.5)  echo "0p50" ;;
        1.0)  echo "1p00" ;;
        *)    echo "0p25" ;;
    esac
}
pretty_res() { echo "${1/0p/0.}"; }
num_min() { awk -v a="$1" -v b="$2" 'BEGIN{print (a<b)?a:b}'; }
num_max() { awk -v a="$1" -v b="$2" 'BEGIN{print (a>b)?a:b}'; }

effective_parallel() {
    local kind="$1"
    case "$kind" in
        atmos) echo "$PARALLEL" ;;
        wave)
            local w="$PARALLEL"
            [ "$w" -gt "$WAVE_PARALLEL_MAX" ] && w="$WAVE_PARALLEL_MAX"
            [ "$w" -lt 1 ] && w=1
            echo "$w" ;;
        rtofs) echo "$RTOFS_PARALLEL_MAX" ;;
        hycom) echo "$HYCOM_PARALLEL_MAX" ;;
        icon)  echo "$ICON_PARALLEL_MAX" ;;
        ecmwf) echo "$ECMWF_PARALLEL_MAX" ;;
        *)     echo "$PARALLEL" ;;
    esac
}

estimate_ecmwf_gb() {
    local ts=$(( FORECAST_HOURS / INTERVAL + 1 ))
    awk -v mb="$(( ts * 85 ))" 'BEGIN{printf "%.1f", mb/1024}'
}

estimate_icon_gb() {
    local ts=$(( FORECAST_HOURS / INTERVAL + 1 ))
    local params=0
    [ "$VAR_TEMP" = "y" ]   && params=$((params + 1))
    [ "$VAR_WIND" = "y" ]   && params=$((params + 2))
    [ "$VAR_GUST" = "y" ]   && params=$((params + 1))
    [ "$VAR_CAPE" = "y" ]   && params=$((params + 1))
    [ "$VAR_CLOUD" = "y" ]  && params=$((params + 1))
    [ "$VAR_PRECIP" = "y" ] && params=$((params + 1))
    [ "$params" -eq 0 ] && params=1
    awk -v mb="$(( ts * params * 6 ))" 'BEGIN{printf "%.1f", mb/1024}'
}

check_cdo()     { command -v cdo      >/dev/null 2>&1; }
check_wgrib2()  { command -v wgrib2   >/dev/null 2>&1; }
check_gribcpy() { command -v grib_copy >/dev/null 2>&1; }
check_gribset() { command -v grib_set  >/dev/null 2>&1; }

# ============================================================
# SECTION 2b - XyGrib GRIB1 currents conversion
# ============================================================
#
# Handles both HYCOM and RTOFS NetCDF sources.
#
# Pipeline:
#   1. Merge separate U/V NetCDF files if needed.
#   2. Normalise RTOFS ocu/ocv variable names to water_u/water_v.
#   3. Use Python (xarray) to replace every non-finite value AND
#      every value outside +/-1e10 with a GRIB-encodable fill
#      value, then set _FillValue in encoding. This catches:
#        - HYCOM's IEEE NaNs (via ~np.isfinite)
#        - RTOFS's -9e33 finite fill sentinel (via the range check)
#      Without the range check, cdo packs GRIB1 across the full
#      -9e33..+1.7 span, collapsing every real value (order 0.1)
#      to zero.
#   4. Encode U and V in two independent cdo passes with
#      -setparam,49 and -setparam,50.
#   5. Rewrite PDS keys with grib_set to match Saildocs RTOFS.
#   6. Verify every message carries the expected parameter code.
convert_nc_to_xygrib_grib1() (
    # Run the converter in a subshell.  The EXIT trap is therefore local
    # to this conversion and cannot fire later from another function.
    local nc_u="$1" nc_v="$2" out_grb="$3" source_model="${4:-generic}"

    [ -s "$nc_u" ] || { echo "    convert: U input missing" >&2; return 1; }
    if ! check_cdo || ! check_gribset || ! command -v grib_get >/dev/null 2>&1; then
        echo "    convert: needs cdo, grib_set and grib_get" >&2
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d) || return 1
    trap 'rm -rf -- "$tmpdir"' EXIT HUP INT TERM

    local nc_input="$nc_u"
    if [ -n "$nc_v" ] && [ -s "$nc_v" ] && [ "$nc_v" != "$nc_u" ]; then
        if ! cdo -O -s merge "$nc_u" "$nc_v" "$tmpdir/merged.nc" >/dev/null 2>&1 || [ ! -s "$tmpdir/merged.nc" ]; then
            echo "    convert: failed to merge U/V NetCDF files" >&2
            return 1
        fi
        nc_input="$tmpdir/merged.nc"
    fi

    local varlist
    varlist=$(cdo -s showname "$nc_input" 2>/dev/null) || varlist=""
    [ -n "$varlist" ] || { echo "    convert: cannot read NetCDF variable names" >&2; return 1; }

    if echo "$varlist" | grep -qw -- ocu && echo "$varlist" | grep -qw -- ocv && ! echo "$varlist" | grep -qw -- water_u; then
        if ! cdo -O -s chname,ocu,water_u,ocv,water_v "$nc_input" "$tmpdir/renamed.nc" >/dev/null 2>&1 || [ ! -s "$tmpdir/renamed.nc" ]; then
            echo "    convert: failed to normalise RTOFS ocu/ocv names" >&2
            return 1
        fi
        nc_input="$tmpdir/renamed.nc"
        varlist=$(cdo -s showname "$nc_input" 2>/dev/null) || varlist=""
    fi

    local uvar="" vvar="" n
    for n in water_u ucurr uo uogrd ocu ucur usurf surf_u u; do
        if echo "$varlist" | grep -qw -- "$n"; then uvar="$n"; break; fi
    done
    for n in water_v vcurr vo vogrd ocv vcur vsurf surf_v v; do
        if echo "$varlist" | grep -qw -- "$n"; then vvar="$n"; break; fi
    done
    if [ -z "$uvar" ] || [ -z "$vvar" ]; then
        echo "    convert: U/V not identified" >&2
        echo "    variables present: $varlist" >&2
        return 1
    fi
    echo "    convert: U='$uvar'  V='$vvar'"

    if ! python3 - "$nc_input" "$tmpdir/clean.nc" "$uvar" "$vvar" <<'PYTHON_EOF'
import sys
import numpy as np
import xarray as xr

src, dst, u_name, v_name = sys.argv[1:5]
fill = np.float32(9.96921e36)
ds = xr.open_dataset(src, decode_times=False, mask_and_scale=False)
try:
    for name in (u_name, v_name):
        if name not in ds:
            raise SystemExit(f"missing variable: {name}")
        var = ds[name]
        a = np.asarray(var.values, dtype=np.float32).copy()
        bad = ~np.isfinite(a)
        bad |= np.abs(a) > np.float32(1.0e10)
        nbad = int(bad.sum())
        a[bad] = fill
        ds[name].values = a
        attrs = dict(ds[name].attrs)
        attrs.pop("_FillValue", None)
        attrs.pop("missing_value", None)
        ds[name].attrs = attrs
        enc = dict(ds[name].encoding)
        enc.pop("_FillValue", None)
        enc.pop("missing_value", None)
        enc["_FillValue"] = fill
        ds[name].encoding = enc
        print(f"    sanitizer: {name}: {nbad} missing/fill points", file=sys.stderr)
    ds.to_netcdf(dst, engine="netcdf4", format="NETCDF4")
finally:
    ds.close()
PYTHON_EOF
    then
        echo "    convert: failed to sanitise current data" >&2
        return 1
    fi

    local uout="$tmpdir/u.grb1" vout="$tmpdir/v.grb1"
    echo "    convert: encoding GRIB1 U=49 V=50 ..."
    if ! cdo -O -f grb1 -setparam,49 -selname,"$uvar" "$tmpdir/clean.nc" "$uout" 2>"$tmpdir/u.err"; then
        cat "$tmpdir/u.err" >&2
        echo "    convert: GRIB1 write failed for U" >&2
        return 1
    fi
    [ -s "$uout" ] || { echo "    convert: GRIB1 U output is empty" >&2; return 1; }
    if ! cdo -O -f grb1 -setparam,50 -selname,"$vvar" "$tmpdir/clean.nc" "$vout" 2>"$tmpdir/v.err"; then
        cat "$tmpdir/v.err" >&2
        echo "    convert: GRIB1 write failed for V" >&2
        return 1
    fi
    [ -s "$vout" ] || { echo "    convert: GRIB1 V output is empty" >&2; return 1; }

    local ufix="$tmpdir/u_fix.grb" vfix="$tmpdir/v_fix.grb"
    # Keep the GRIB1 header deliberately close to the known-good Saildocs
    # RTOFS product.  XyGrib is an old GRIB1 reader and is much less
    # forgiving than ecCodes/OpenCPN.  In particular, the Saildocs RTOFS
    # files use centre=7, process=0, grid=255, table=2, surface=0,
    # hour time units, TRI=0, P2=10 and decimal scale=2.
    #
    # IMPORTANT: decimalScaleFactor is part of the packing algorithm. It
    # cannot safely be changed as a header-only edit. v2.20 produced the
    # correct current direction but zero speed because the CDO-packed data
    # were not repacked when D was changed to 2. v2.21 uses grib_set -r so
    # the decoded U/V values are preserved while the Saildocs D=2 identity
    # is applied.
    #
    # NOTE: an earlier version forced generatingProcessIdentifier=45.
    # That is the NOAA/OpenCPN RTOFS model identity, but it is NOT what is
    # actually present in the working Saildocs GRIB1 files supplied for this
    # job.  For maximum XyGrib compatibility we reproduce Saildocs here.
    local common="edition=1,centre=7,subCentre=0,table2Version=2,indicatorOfTypeOfLevel=1,level=0,packingType=grid_simple,indicatorOfUnitOfTimeRange=1,timeRangeIndicator=0,P2=10,decimalScaleFactor=2"
    local uset="$common,indicatorOfParameter=49"
    local vset="$common,indicatorOfParameter=50"
    if [ "$source_model" = "rtofs" ]; then
        uset="$uset,generatingProcessIdentifier=0,gridDefinition=255"
        vset="$vset,generatingProcessIdentifier=0,gridDefinition=255"
        echo "    convert: applying Saildocs-compatible RTOFS GRIB1 identity (centre=7, process=0, grid=255)"
    fi
    if ! grib_set -r -s "$uset" "$uout" "$ufix" 2>"$tmpdir/u_set.err"; then
        cat "$tmpdir/u_set.err" >&2
        echo "    convert: grib_set failed for U" >&2
        return 1
    fi
    if ! grib_set -r -s "$vset" "$vout" "$vfix" 2>"$tmpdir/v_set.err"; then
        cat "$tmpdir/v_set.err" >&2
        echo "    convert: grib_set failed for V" >&2
        return 1
    fi
    [ -s "$ufix" ] && [ -s "$vfix" ] || { echo "    convert: fixed GRIB1 output is empty" >&2; return 1; }

    # v2.17 compared indicatorOfTypeOfLevel to numeric 1. ecCodes
    # returns the human-readable typeOfLevel (surface), so that check
    # rejected every record. Validate the human-readable key instead.
    local bad_u bad_v
    bad_u=$(grib_get -p edition,indicatorOfParameter,typeOfLevel,level,gridType,packingType "$ufix" 2>/dev/null | awk 'NF && !($1==1 && $2==49 && $3=="surface" && $4==0 && $5=="regular_ll" && $6=="grid_simple"){n++} END{print n+0}')
    bad_v=$(grib_get -p edition,indicatorOfParameter,typeOfLevel,level,gridType,packingType "$vfix" 2>/dev/null | awk 'NF && !($1==1 && $2==50 && $3=="surface" && $4==0 && $5=="regular_ll" && $6=="grid_simple"){n++} END{print n+0}')
    [ "${bad_u:-1}" -eq 0 ] && [ "${bad_v:-1}" -eq 0 ] || {
        echo "    convert: GRIB1 validation failed (bad U=$bad_u bad V=$bad_v)" >&2
        return 1
    }

    if [ "$source_model" = "rtofs" ]; then
        # v2.21 checked every message against timeRangeIndicator==0 and
        # P2==10. A byte-level dump of an actual working Saildocs RTOFS
        # file shows timeRangeIndicator=10 with P2 holding the forecast
        # hour itself (0/24/48/72...), never a fixed 10. So this check
        # could not pass on real data -- it rejected 96/96 messages and
        # discarded otherwise-good output, which is why RTOFS failed
        # while HYCOM (which never runs this rtofs-only block) worked.
        # Reduced to checking only the fields confirmed correct from
        # that same byte-level dump (centre/process/grid), as a
        # non-fatal note rather than a hard failure.
        local bad_id
        bad_id=$(grib_get -p centre,generatingProcessIdentifier,gridDefinition "$ufix" 2>/dev/null | awk 'NF && !($1=="kwbc" && $2==0 && $3==255){n++} END{print n+0}')
        [ "${bad_id:-0}" -eq 0 ] || \
            echo "    convert: note - $bad_id record(s) have unexpected centre/process/grid (continuing)" >&2
    fi

    cat "$ufix" "$vfix" > "$out_grb" || { rm -f "$out_grb"; return 1; }
    [ -s "$out_grb" ] || { rm -f "$out_grb"; return 1; }
    local records ucount vcount
    records=$(grib_get -p indicatorOfParameter "$out_grb" 2>/dev/null | awk 'NF{n++} END{print n+0}')
    ucount=$(grib_get -p indicatorOfParameter "$ufix" 2>/dev/null | awk '$1==49{n++} END{print n+0}')
    vcount=$(grib_get -p indicatorOfParameter "$vfix" 2>/dev/null | awk '$1==50{n++} END{print n+0}')
    [ "$ucount" -gt 0 ] && [ "$vcount" -gt 0 ] || {
        echo "    convert: missing U or V records after validation" >&2
        rm -f "$out_grb"
        return 1
    }
    echo "    convert: OK — $records GRIB1 records (U=$ucount, V=$vcount)"
    return 0
)

# ============================================================
# SECTION 3 - Server probing
# ============================================================
probe_one() {
    local url="$1"
    local out
    out=$(curl -s -o /dev/null -w "%{http_code}|%{time_connect}" \
                -A "$UA" --max-time 8 --connect-timeout 5 "$url" 2>/dev/null)
    local code="${out%%|*}"
    local tc="${out##*|}"
    local rtt; rtt=$(awk -v t="$tc" 'BEGIN{printf "%d", t*1000}')
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ] || [ "$code" = "206" ]; then
        echo "online|$code|$rtt"
    elif [ "$code" = "000" ]; then
        echo "offline|timeout|0"
    else
        echo "offline|$code|$rtt"
    fi
}

probe_all() {
    echo "Probing servers..."
    {
        echo "# GRIB status - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "TS=$(date -u +%s)"
        for srv in "NOMADS|https://nomads.ncep.noaa.gov/" \
                   "NOMADS_CGI|https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl" \
                   "NOMADS_WAVE|https://nomads.ncep.noaa.gov/cgi-bin/filter_gfswave.pl" \
                   "HYCOM|https://ncss.hycom.org/thredds/ncss/grid/FMRC_ESPC-D-V02_uv3z/FMRC_ESPC-D-V02_uv3z_best.ncd/dataset.html" \
                   "DWD|https://opendata.dwd.de/weather/nwp/icon/grib/" \
                   "ECMWF|https://data.ecmwf.int/forecasts/"; do
            local name="${srv%%|*}"
            local url="${srv##*|}"
            local res; res=$(probe_one "$url")
            echo "${name}=${res}"
        done
        python3 -c "import ecmwf.opendata" 2>/dev/null \
            && echo "ECMWF_LIB=ready|||" || echo "ECMWF_LIB=missing|||"
        command -v cdo >/dev/null 2>&1 \
            && echo "CDO=ready|||" || echo "CDO=not installed|||"
        command -v wgrib2 >/dev/null 2>&1 \
            && echo "WGRIB2=ready|||" || echo "WGRIB2=not installed|||"
        if command -v grib_copy >/dev/null 2>&1 && command -v grib_set >/dev/null 2>&1; then
            echo "GRIB_TOOLS=ready|||"
        else
            echo "GRIB_TOOLS=missing|||"
        fi
    } > "$STATUS"
    echo "Done."
}

status_age() {
    [ -f "$STATUS" ] || { echo "never"; return; }
    local ts; ts=$(grep '^TS=' "$STATUS" | cut -d= -f2)
    [ -z "$ts" ] && { echo "never"; return; }
    local d=$(( $(date -u +%s) - ts ))
    if [ "$d" -lt 60 ]; then echo "${d}s ago"
    elif [ "$d" -lt 3600 ]; then echo "$((d/60))m ago"
    else echo "$((d/3600))h ago"; fi
}
status_value() {
    [ -f "$STATUS" ] || { echo "?|?|?"; return; }
    local line; line=$(grep "^$1=" "$STATUS")
    [ -z "$line" ] && { echo "?|?|?"; return; }
    echo "${line#*=}"
}
status_symbol() {
    case "$1" in
        online*|ready*) echo -e "\033[32m●\033[0m" ;;
        missing*|not\ installed*) echo -e "\033[33m◐\033[0m" ;;
        offline*) echo -e "\033[31m○\033[0m" ;;
        *) echo "?" ;;
    esac
}

# ============================================================
# SECTION 4 - Cycle detection
# ============================================================
detect_latest_cycle() {
    local today; today=$(date -u +%Y%m%d)
    local yesterday; yesterday=$(date -u -d "yesterday" +%Y%m%d)
    local lastf; lastf=$(printf "f%03d" "$FORECAST_HOURS")
    local OFFSET_DATE CYCLE
    for OFFSET_DATE in "$today" "$yesterday"; do
        for CYCLE in 18 12 06 00; do
            local url="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl?dir=/gfs.${OFFSET_DATE}/${CYCLE}/atmos"
            local html; html=$(curl -s -A "$UA" --max-time 10 "$url")
            if echo "$html" | grep -q "gfs.t${CYCLE}z.pgrb2.0p25.${lastf}"; then
                echo "${OFFSET_DATE} ${CYCLE}"
                return 0
            fi
        done
    done
    return 1
}

cycle_age_hours() {
    local d="${1% *}" c="${1##* }"
    local ts
    ts=$(date -u -d "${d:0:4}-${d:4:2}-${d:6:2} ${c}:00:00" +%s 2>/dev/null)
    [ -z "$ts" ] && { echo 0; return; }
    echo $(( ( $(date -u +%s) - ts ) / 3600 ))
}

next_cycle_eta() {
    local h=$((10#$(date -u +%H)))
    local nh
    if   [ "$h" -lt 4 ];  then nh=00
    elif [ "$h" -lt 10 ]; then nh=06
    elif [ "$h" -lt 16 ]; then nh=12
    elif [ "$h" -lt 22 ]; then nh=18
    else nh=00; fi
    local rm
    case "$nh" in
        00) rm=$((4*60+30)) ;; 06) rm=$((10*60+30)) ;;
        12) rm=$((16*60+30)) ;; 18) rm=$((22*60+30)) ;;
    esac
    local nd; nd=$(date -u +%Y%m%d)
    local nm=$(( h * 60 + 10#$(date -u +%M) ))
    local wm=$(( rm - nm ))
    if [ "$wm" -lt 0 ]; then wm=$(( wm + 1440 )); nd=$(date -u -d "tomorrow" +%Y%m%d); fi
    echo "${nd} ${nh}|$(( wm * 60 ))"
}

# ============================================================
# SECTION 5 - Local inventory
# ============================================================
atm_dir()  { echo "$OUTPUT_DIR/atmos"; }
wave_dir() { echo "$OUTPUT_DIR/waves"; }
# Final, app-ready destination folders. Raw per-source downloads (atmos/,
# waves/, hycom/, rtofs/) are untouched by this; these two only receive
# the finished products combine_all() builds for each application.
opencpn_dir() { echo "$OUTPUT_DIR/OpenCPN"; }
xygrib_dir()  { echo "$OUTPUT_DIR/Xygrib"; }

count_local() {
    local kind="${1:-atmos}" cycle="${2:-}"
    local have=0 total=0
    local rtok; rtok=$(res_token)
    local H F found c
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        total=$((total + 1))
        F=$(printf "%03d" "$H")
        found=""
        if [ "$kind" = "wave" ]; then
            if [ -n "$cycle" ]; then
                c="${cycle##* }"
                found=$(ls "$(wave_dir)"/gfswave.t${c}z.global.${WAVE_RES}.f${F}.grib2 2>/dev/null | head -1)
            else
                found=$(ls "$(wave_dir)"/gfswave.t*z.global.${WAVE_RES}.f${F}.grib2 2>/dev/null | head -1)
            fi
        else
            if [ -n "$cycle" ]; then
                c="${cycle##* }"
                found=$(ls "$(atm_dir)"/gfs.t${c}z.pgrb2*.${rtok}.f${F}.* 2>/dev/null | head -1)
            else
                found=$(ls "$(atm_dir)"/gfs.t*z.pgrb2*.${rtok}.f${F}.* 2>/dev/null | head -1)
            fi
        fi
        [ -s "$found" ] && have=$((have + 1))
    done
    echo "$have $total"
}

# ============================================================
# SECTION 6 - URL building
# ============================================================
build_atmos_url() {
    local FILE="$1" d="$2" c="$3" rtok="$4"
    local URL="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_${rtok}.pl"
    URL+="?file=${FILE}&dir=/gfs.${d}/${c}/atmos"
    [ "$VAR_WIND" = "y" ]     && URL+="&var_UGRD=on&var_VGRD=on"
    [ "$VAR_GUST" = "y" ]     && URL+="&var_GUST=on"
    [ "$VAR_TEMP" = "y" ]     && URL+="&var_TMP=on"
    [ "$VAR_CAPE" = "y" ]     && URL+="&var_CAPE=on"
    [ "$VAR_CLOUD" = "y" ]    && URL+="&var_TCDC=on"
    [ "$VAR_PRECIP" = "y" ]   && URL+="&var_APCP=on"
    [ "$VAR_HUMIDITY" = "y" ] && URL+="&var_RH=on"
    URL+="&lev_10_m_above_ground=on&lev_surface=on&lev_2_m_above_ground=on"
    URL+="&subregion=&leftlon=${LEFT_LON}&rightlon=${RIGHT_LON}"
    URL+="&toplat=${TOP_LAT}&bottomlat=${BOTTOM_LAT}"
    echo "$URL"
}

build_wave_url() {
    local FILE="$1" d="$2" c="$3"
    local URL="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfswave.pl?file=${FILE}&dir=/gfs.${d}/${c}/wave/gridded"
    [ "$VAR_WAVES" = "y" ] && URL+="&var_HTSGW=on&var_PERPW=on&var_DIRPW=on&var_WVHGT=on&var_WVPER=on&var_WVDIR=on"
    [ "$VAR_SWELL" = "y" ] && URL+="&var_SWELL=on&var_SWDIR=on&var_SWPER=on"
    URL+="&subregion=&leftlon=${LEFT_LON}&rightlon=${RIGHT_LON}"
    URL+="&toplat=${TOP_LAT}&bottomlat=${BOTTOM_LAT}"
    echo "$URL"
}

# ============================================================
# SECTION 7 - Size estimation
# ============================================================
estimate_size() {
    local kind="$1" cycle="$2"
    local c="${cycle##* }"
    local rtok; rtok=$(res_token)
    local dir
    if [ "$kind" = "wave" ]; then dir=$(wave_dir); else dir=$(atm_dir); fi
    local sample_sum=0 sample_n=0 missing=0
    local H F found
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        F=$(printf "%03d" "$H")
        found=""
        if [ "$kind" = "wave" ]; then
            found=$(ls "$dir"/gfswave.t${c}z.global.${WAVE_RES}.f${F}.grib2 2>/dev/null | head -1)
        else
            found=$(ls "$dir"/gfs.t${c}z.pgrb2*.${rtok}.f${F}.* 2>/dev/null | head -1)
        fi
        if [ -s "$found" ]; then
            if [ "$sample_n" -lt 5 ]; then
                sample_sum=$((sample_sum + $(size_of "$found")))
                sample_n=$((sample_n + 1))
            fi
        else
            missing=$((missing + 1))
        fi
    done
    if [ "$sample_n" -eq 0 ]; then
        local pattern f
        if [ "$kind" = "wave" ]; then
            pattern="$dir/gfswave.t*z.global.${WAVE_RES}.f*.grib2"
        else
            pattern="$dir/gfs.t*z.pgrb2*.${rtok}.f*.*"
        fi
        for f in $(ls -1t "$pattern" 2>/dev/null | head -5); do
            [ -s "$f" ] || continue
            sample_sum=$((sample_sum + $(size_of "$f")))
            sample_n=$((sample_n + 1))
        done
    fi
    if [ "$sample_n" -eq 0 ]; then
        if [ "$kind" = "wave" ]; then echo "$(( 15000 * missing )) $missing"
        else echo "$(( 10000 * missing )) $missing"; fi
        return
    fi
    local avg=$((sample_sum / sample_n))
    echo "$(( avg * missing )) $missing"
}

# ============================================================
# SECTION 8 - Download primitives
# ============================================================
do_download() {
    local url="$1" out="$2" magic="${3:-GRIB}" max_timeout="${4:-$MAX_TIMEOUT}" retries="${5:-$RETRIES}" connect_timeout="${6:-$CONNECT_TIMEOUT}"
    if [ -s "$out" ]; then
        if head -c 4 "$out" 2>/dev/null | grep -q "$magic"; then return 0; fi
        rm -f "$out"
    fi
    local attempt=1 total=$((retries + 1)) rc=1 delay=3
    while [ "$attempt" -le "$total" ]; do
        local -a args=(-L --fail --connect-timeout "$connect_timeout" --max-time "$max_timeout" -A "$UA" -o "$out" --no-progress-meter)
        [ "$COMPRESS" = "y" ] && args+=(--compressed)
        [ "$RESUME" = "y" ] && args+=(-C -)
        curl "${args[@]}" "$url" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ] && [ -s "$out" ] && head -c 4 "$out" 2>/dev/null | grep -q "$magic"; then return 0; fi
        if [ "$attempt" -lt "$total" ]; then
            echo "  Download failed (attempt $attempt/$total, curl=$rc). Retrying in ${delay}s ..." >&2
            sleep "$delay"
            delay=$(( delay < 60 ? delay * 2 : 60 ))
        fi
        attempt=$((attempt + 1))
    done
    rm -f "$out"
    return "$rc"
}

server_reachable() {
    local url="$1" name="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -A "$UA" --max-time 5 "$url")
    case "$code" in
        200|301|302|206) return 0 ;;
        *) echo "  $name unreachable (HTTP $code). Aborting."; return 1 ;;
    esac
}

show_progress() {
    local dn="$1" tot="$2" st="$3" er="$4"
    local pct=0
    [ "$tot" -gt 0 ] && pct=$(( dn * 100 / tot ))
    local bar=""; local fl=$(( pct / 5 ))
    local i
    for ((i=0; i<fl; i++)); do bar+="#"; done
    for ((i=fl; i<20; i++)); do bar+="-"; done
    local el=$(( $(date +%s) - st ))
    local eta="-"
    if [ "$dn" -gt 0 ]; then
        eta=$(secs_to_hms $(( (el / dn) * (tot - dn) )))
    fi
    echo "  [$bar] $dn / $tot  ($pct %)   elapsed $(secs_to_hms $el)   ETA $eta   err $er" >&2
}

download_with_progress() {
    local url="$1" out="$2" magic="$3" label="$4"
    local max_timeout="${5:-$MAX_TIMEOUT}" retries="${6:-$RETRIES}" connect_timeout="${7:-$CONNECT_TIMEOUT}"
    [ -f "$out" ] && [ ! -s "$out" ] && rm -f "$out"
    do_download "$url" "$out" "$magic" "$max_timeout" "$retries" "$connect_timeout" &
    local cpid=$!
    local st; st=$(date +%s)
    local spin='|/-\'; local si=0
    printf "\033[?25l" >&2
    while kill -0 "$cpid" 2>/dev/null; do
        local el=$(( $(date +%s) - st ))
        local cs; cs=$(size_of "$out")
        local r=0; [ "$el" -gt 0 ] && r=$(( cs / el ))
        local c="${spin:$si:1}"; si=$(( (si + 1) % 4 ))
        printf "\r    %s %s   %s   %s/s   (elapsed %s)   " \
               "$c" "$label" "$(human "$cs")" "$(human "$r")" "$(secs_to_hms "$el")" >&2
        sleep 1
    done
    wait "$cpid"
    local rc=$?
    printf "\033[?25h" >&2
    local fs; fs=$(size_of "$out")
    local te=$(( $(date +%s) - st ))
    if [ "$rc" -eq 0 ] && [ "$fs" -gt 0 ]; then
        local rf=0; [ "$te" -gt 0 ] && rf=$(( fs / te ))
        printf "\r    OK %s   %s   in %s (%s/s)                    \n" \
               "$label" "$(human "$fs")" "$(secs_to_hms "$te")" "$(human "$rf")" >&2
    else
        printf "\r    FAIL %s   after %s                    \n" \
               "$label" "$(secs_to_hms "$te")" >&2
    fi
    return $rc
}

run_batch_download() {
    local bp="$1"; shift
    local -a entries=("$@")
    local total="${#entries[@]}"
    local dn=0 er=0 st; st=$(date +%s)
    local -a pids=()
    local fbc=0
    local entry
    for entry in "${entries[@]}"; do
        local URL="${entry%%|*}" OUT="${entry#*|}"
        if [ -s "$OUT" ] && head -c 4 "$OUT" 2>/dev/null | grep -q "GRIB"; then
            dn=$((dn + 1)); continue
        fi
        do_download "$URL" "$OUT" &
        pids+=($!)
        if [ ${#pids[@]} -ge "$bp" ]; then
            local p be=0
            for p in "${pids[@]}"; do wait "$p" || { er=$((er + 1)); be=$((be + 1)); }; done
            local bs=${#pids[@]}
            dn=$((dn + bs))
            pids=()
            if [ "$fbc" -eq 0 ] && [ "$be" -eq "$bs" ]; then
                echo >&2
                echo "  Entire first batch failed. Cycle likely still publishing," >&2
                echo "  or resolution not available." >&2
                [ "$RESOLUTION" != "0.25" ] && echo "  Hint: try 0.25 in [2]." >&2
                BATCH_BYTES=0; BATCH_ERRORS=$er; return
            fi
            fbc=1
            [ "$SLEEP" != "0" ] && sleep "$SLEEP"
            show_progress "$dn" "$total" "$st" "$er"
        fi
    done
    if [ ${#pids[@]} -gt 0 ]; then
        local p
        for p in "${pids[@]}"; do wait "$p" || er=$((er + 1)); done
        dn=$((dn + ${#pids[@]}))
    fi
    show_progress "$dn" "$total" "$st" "$er"
    local et; et=$(date +%s)
    local el=$(( et - st )); [ "$el" -eq 0 ] && el=1
    local tb=0
    for entry in "${entries[@]}"; do tb=$(( tb + $(size_of "${entry#*|}") )); done
    BATCH_BYTES=$(( tb / el ))
    BATCH_ERRORS=$er
}

# ============================================================
# SECTION 9 - Product downloads
# ============================================================
download_gfs() {
    server_reachable "https://nomads.ncep.noaa.gov/" "NOMADS" || return 1
    local cycle="${1:-}"
    if [ -z "$cycle" ]; then
        cycle=$(detect_latest_cycle) || { echo "No cycle found."; return 1; }
    fi
    LAST_CYCLE="$cycle"
    local d="${cycle% *}" c="${cycle##* }"
    local rtok; rtok=$(res_token)
    local ap; ap=$(effective_parallel atmos)
    echo "Using cycle ${cycle} (atmos, ${RESOLUTION}°, $(($FORECAST_HOURS/24)) days, parallel $ap)"
    local ATM; ATM=$(atm_dir); mkdir -p "$ATM"
    local -a entries=()
    local H F FILE OUT URL
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        F=$(printf "%03d" "$H")
        FILE="gfs.t${c}z.pgrb2.${rtok}.f${F}"
        OUT="$ATM/${FILE}.grib2"
        URL=$(build_atmos_url "$FILE" "$d" "$c" "$rtok")
        entries+=("$URL|$OUT")
    done
    run_batch_download "$ap" "${entries[@]}"
    LAST_RATE="$BATCH_BYTES"
    [ "$BATCH_ERRORS" != "0" ] && echo "  $BATCH_ERRORS atmospheric file(s) failed."
    save_config
    return 0
}

download_gfswave() {
    server_reachable "https://nomads.ncep.noaa.gov/" "NOMADS" || return 1
    local cycle="${1:-}"
    if [ -z "$cycle" ]; then
        cycle=$(detect_latest_cycle) || { echo "No cycle found."; return 1; }
    fi
    LAST_CYCLE="$cycle"
    local d="${cycle% *}" c="${cycle##* }"
    local wp; wp=$(effective_parallel wave)
    echo "Using cycle ${cycle} (wave, global $(pretty_res "$WAVE_RES")°, parallel $wp)"
    local WAV; WAV=$(wave_dir); mkdir -p "$WAV"
    local -a entries=()
    local H F FILE OUT URL
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        F=$(printf "%03d" "$H")
        FILE="gfswave.t${c}z.global.${WAVE_RES}.f${F}.grib2"
        OUT="$WAV/${FILE}"
        URL=$(build_wave_url "$FILE" "$d" "$c")
        entries+=("$URL|$OUT")
    done
    run_batch_download "$wp" "${entries[@]}"
    [ "$BATCH_ERRORS" != "0" ] && echo "  $BATCH_ERRORS wave file(s) failed."
    save_config
    return 0
}

rtofs_find_date_and_listing() {
    local OFFSET trydate trylist trycount
    for OFFSET in 0 1 2 3; do
        trydate=$(date -u -d "-$OFFSET days" +%Y%m%d)
        trylist=$(curl -s -A "$UA" --max-time 15 \
                  "https://nomads.ncep.noaa.gov/pub/data/nccf/com/rtofs/prod/rtofs.${trydate}/")
        trycount=$(echo "$trylist" | \
                   grep -oE 'rtofs_glo\.t00z\.[nf][0-9]{3}_trop_paci[a-z_]*_std\.grb2' \
                   | sort -u | wc -l)
        if [ "$trycount" -gt 0 ]; then
            echo "$trydate"
            echo "$trylist"
            return 0
        fi
    done
    return 1
}

download_rtofs() {
    server_reachable "https://nomads.ncep.noaa.gov/" "NOMADS" || return 1

    local probe
    probe=$(rtofs_find_date_and_listing) || {
        echo "No RTOFS data in last 4 days."; return 1
    }
    local DATE listing
    DATE=$(echo "$probe" | head -1)
    listing=$(echo "$probe" | tail -n +2)

    local files
    files=$(echo "$listing" | \
            grep -oE 'rtofs_glo\.t00z\.[nf][0-9]{3}_trop_paci[a-z_]*_std\.grb2' | sort -u)
    [ -z "$files" ] && { echo "  No trop_paci files for $DATE."; return 1; }
    echo "Using RTOFS date: $DATE (00z, parallel 1)"
    echo "  Files available:"
    echo "$files" | sed 's/^/    /'; echo

    local OUT="$OUTPUT_DIR/rtofs"; mkdir -p "$OUT"
    local -a dl=()
    local FILE DEST URL
    while IFS= read -r FILE; do
        [ -z "$FILE" ] && continue
        DEST="$OUT/$FILE"
        if [ -s "$DEST" ]; then
            echo "    OK $FILE (already present)"; dl+=("$DEST"); continue
        fi
        URL="https://nomads.ncep.noaa.gov/pub/data/nccf/com/rtofs/prod/rtofs.${DATE}/${FILE}"
        download_with_progress "$URL" "$DEST" "GRIB" "$FILE" && dl+=("$DEST")
    done <<< "$files"
    [ ${#dl[@]} -eq 0 ] && { echo "  No files downloaded."; return 1; }

    local FINAL="$OUTPUT_DIR/RTOFS_Currents.grib2"
    rm -f "$FINAL"
    local f
    for f in "${dl[@]}"; do [ -s "$f" ] && cat "$f" >> "$FINAL"; done
    [ -s "$FINAL" ] && echo "  RTOFS GRIB2 → $FINAL ($(human $(size_of "$FINAL")))"

    local XYGRIB_GRB="$OUTPUT_DIR/RTOFS_Currents_XyGrib.grb"
    rm -f "$XYGRIB_GRB"
    if [ -s "$FINAL" ] && check_cdo && check_gribcpy && check_gribset; then
        echo "  Building XyGrib GRIB1 companion ..."
        local NC="$OUT/rtofs_uv.nc"
        if cdo -f nc copy "$FINAL" "$NC" 2>/dev/null && [ -s "$NC" ]; then
            if convert_nc_to_xygrib_grib1 "$NC" "" "$XYGRIB_GRB" rtofs; then
                echo "  XyGrib GRIB1 → $XYGRIB_GRB ($(human $(size_of "$XYGRIB_GRB")))"
                echo "  Verification:"
                grib_ls -p edition,centre,subCentre,table2Version,indicatorOfParameter,shortName,typeOfLevel,level,gridType \
                    "$XYGRIB_GRB" 2>/dev/null | head -4 | sed 's/^/    /'
            else
                echo "  XyGrib GRIB1 conversion failed — see messages above."
                rm -f "$XYGRIB_GRB"
            fi
        else
            echo "  Could not convert GRIB2 to NetCDF for XyGrib."
        fi
    fi
}

download_hycom() {
    server_reachable "https://ncss.hycom.org/thredds/ncss/grid/FMRC_ESPC-D-V02_uv3z/FMRC_ESPC-D-V02_uv3z_best.ncd/dataset.html" "HYCOM" || return 1
    if ! check_cdo; then
        echo "  HYCOM requires cdo. Install: sudo apt install cdo"; return 1
    fi
    if ! python3 -c "import xarray, netCDF4" 2>/dev/null; then
        echo "  HYCOM requires Python: xarray, netCDF4"
        read -r -p "  Install now? [y/N]: " inst
        if [ "$inst" = "y" ] || [ "$inst" = "Y" ]; then
            pip install --user xarray netCDF4 || return 1
        else return 1; fi
    fi
    local OUT="$OUTPUT_DIR/hycom"; mkdir -p "$OUT"
    local NCSS_UV="https://ncss.hycom.org/thredds/ncss/grid/FMRC_ESPC-D-V02_uv3z/FMRC_ESPC-D-V02_uv3z_best.ncd"
    local NCSS_T="https://ncss.hycom.org/thredds/ncss/grid/FMRC_ESPC-D-V02_ts3z/FMRC_ESPC-D-V02_ts3z_best.ncd"
    local span="$HYCOM_DAYS"
    [ "$span" -gt 8 ] && { echo "  Clamping to 8-day max."; span=8; }
    [ "$span" -lt 1 ] && span=1
    local T_START T_END
    T_START=$(date -u +%Y-%m-%dT%H:00:00Z)
    T_END=$(date -u -d "+${span} days" +%Y-%m-%dT%H:00:00Z)
    echo "Downloading HYCOM NetCDF (${T_START} → ${T_END}, parallel 1)"
    echo "  Region: ${BOTTOM_LAT}..${TOP_LAT} N, ${LEFT_LON}..${RIGHT_LON} E"

    local OUT_CURR="$OUTPUT_DIR/HYCOM_Currents.grib2"
    local OUT_SST="$OUTPUT_DIR/HYCOM_SeaTemp.grib2"
    rm -f "$OUT_CURR" "$OUT_SST"

    local want_uv="n" want_sst="n"
    [ "$VAR_CURRENTS" = "y" ] && want_uv="y"
    [ "$VAR_SEATEMP" = "y" ] && want_sst="y"
    [ "$want_uv" = "n" ] && [ "$want_sst" = "n" ] && want_uv="y"

    local NC_U="$OUT/hycom_water_u.nc" NC_V="$OUT/hycom_water_v.nc"

    if [ "$want_uv" = "y" ]; then
        local ok_uv=1
        local comp NC_FILE URL
        for comp in water_u water_v; do
            [ "$comp" = "water_u" ] && NC_FILE="$NC_U" || NC_FILE="$NC_V"
            URL="${NCSS_UV}?var=${comp}"
            URL+="&north=${TOP_LAT}&west=${LEFT_LON}&east=${RIGHT_LON}&south=${BOTTOM_LAT}"
            URL+="&horizStride=1"
            URL+="&time_start=${T_START}&time_end=${T_END}&timeStride=1"
            URL+="&vertCoord=0&disableProjSubset=on&disableLLSubset=on"
            URL+="&addLatLon=true&accept=netcdf4"
            if ! download_with_progress "$URL" "$NC_FILE" "HDF" "$comp" "$HYCOM_MAX_TIMEOUT" "$HYCOM_RETRIES" "$HYCOM_CONNECT_TIMEOUT"; then
                ok_uv=0; break
            fi
        done
        if [ "$ok_uv" = "1" ]; then
            local GRIB_U="$OUT/hycom_u.grib2" GRIB_V="$OUT/hycom_v.grib2"
            echo "  Converting currents NetCDF → GRIB2 with cdo ..."
            if cdo -f grb2 copy "$NC_U" "$GRIB_U" 2>/tmp/cdo_u_err.log \
               && cdo -f grb2 copy "$NC_V" "$GRIB_V" 2>/tmp/cdo_v_err.log; then
                if command -v grib_set >/dev/null 2>&1; then
                    grib_set -s discipline=10,parameterCategory=1,parameterNumber=2 \
                             "$GRIB_U" "${GRIB_U}.fix" 2>/dev/null && mv "${GRIB_U}.fix" "$GRIB_U"
                    grib_set -s discipline=10,parameterCategory=1,parameterNumber=3 \
                             "$GRIB_V" "${GRIB_V}.fix" 2>/dev/null && mv "${GRIB_V}.fix" "$GRIB_V"
                fi
                if command -v wgrib2 >/dev/null 2>&1; then
                    echo "  Re-packing to simple packing (qtVlm compatible) ..."
                    wgrib2 "$GRIB_U" -set_grib_type s -grib_out "${GRIB_U}.s" 2>/dev/null \
                        && mv "${GRIB_U}.s" "$GRIB_U"
                    wgrib2 "$GRIB_V" -set_grib_type s -grib_out "${GRIB_V}.s" 2>/dev/null \
                        && mv "${GRIB_V}.s" "$GRIB_V"
                fi
                cat "$GRIB_U" "$GRIB_V" >> "$OUT_CURR"
                echo "  HYCOM GRIB2 → $OUT_CURR ($(human $(size_of "$OUT_CURR")))"
            else
                echo "  cdo failed on currents."
            fi
        fi
    fi

    if [ "$want_sst" = "y" ]; then
        local NC_T="$OUT/hycom_water_temp.nc"
        local URL="${NCSS_T}?var=water_temp"
        URL+="&north=${TOP_LAT}&west=${LEFT_LON}&east=${RIGHT_LON}&south=${BOTTOM_LAT}"
        URL+="&horizStride=1"
        URL+="&time_start=${T_START}&time_end=${T_END}&timeStride=1"
        URL+="&vertCoord=0&addLatLon=true&accept=netcdf4"
        if download_with_progress "$URL" "$NC_T" "HDF" "water_temp" "$HYCOM_MAX_TIMEOUT" "$HYCOM_RETRIES" "$HYCOM_CONNECT_TIMEOUT"; then
            local GRIB_T="$OUT/hycom_water_temp.grib2"
            echo "  Converting sea temp NetCDF → GRIB2 with cdo ..."
            if cdo -f grb2 copy "$NC_T" "$GRIB_T" 2>/tmp/cdo_t_err.log; then
                if command -v grib_set >/dev/null 2>&1; then
                    grib_set -s discipline=10,parameterCategory=3,parameterNumber=0 \
                             "$GRIB_T" "${GRIB_T}.fix" 2>/dev/null && mv "${GRIB_T}.fix" "$GRIB_T"
                fi
                if command -v wgrib2 >/dev/null 2>&1; then
                    wgrib2 "$GRIB_T" -set_grib_type s -grib_out "${GRIB_T}.s" 2>/dev/null \
                        && mv "${GRIB_T}.s" "$GRIB_T"
                fi
                cat "$GRIB_T" >> "$OUT_SST"
                echo "  HYCOM SeaTemp GRIB2 → $OUT_SST ($(human $(size_of "$OUT_SST")))"
            fi
        fi
    fi

    local XYGRIB_GRB="$OUTPUT_DIR/HYCOM_Currents_XyGrib.grb"
    rm -f "$XYGRIB_GRB"
    if [ -s "$NC_U" ] && [ -s "$NC_V" ]; then
        echo "  Building XyGrib GRIB1 companion ..."
        if convert_nc_to_xygrib_grib1 "$NC_U" "$NC_V" "$XYGRIB_GRB" hycom; then
            echo "  XyGrib GRIB1 → $XYGRIB_GRB ($(human $(size_of "$XYGRIB_GRB")))"
            echo "  Verification:"
            grib_ls -p edition,centre,subCentre,table2Version,indicatorOfParameter,shortName,typeOfLevel,level,gridType \
                "$XYGRIB_GRB" 2>/dev/null | head -4 | sed 's/^/    /'
        else
            echo "  XyGrib GRIB1 conversion failed — see messages above."
            rm -f "$XYGRIB_GRB"
        fi
    fi

    local produced=0
    [ -s "$OUT_CURR" ] && produced=1
    [ -s "$OUT_SST" ]  && produced=1
    [ "$produced" = "0" ] && { echo "  No HYCOM output produced."; return 1; }
    return 0
}

download_ecmwf() {
    server_reachable "https://data.ecmwf.int/forecasts/" "ECMWF" || return 1
    python3 -c "import ecmwf.opendata" 2>/dev/null || \
        pip install --user ecmwf-opendata || return 1
    local total_gb; total_gb=$(estimate_ecmwf_gb)
    echo
    echo "  ECMWF total download: ~${total_gb} GB (no area cropping)"
    read -r -p "  Proceed? [y/N]: " go
    [ "$go" != "y" ] && [ "$go" != "Y" ] && return 1
    local OUT="$OUTPUT_DIR/ecmwf"; mkdir -p "$OUT"
    python3 - "$OUT" "$FORECAST_HOURS" "$INTERVAL" <<'PY'
import sys, os
from ecmwf.opendata import Client
out, hours, interval = sys.argv[1:4]
hours = int(hours); interval = int(interval)
client = Client(source="ecmwf")
for h in range(0, hours + 1, interval):
    target = os.path.join(out, f"ecmwf_f{h:03d}.grib2")
    if os.path.exists(target) and os.path.getsize(target) > 0:
        print(f"skip {h}"); continue
    try:
        client.retrieve(step=h, type="fc", param=["10u","10v","2t","msl"], target=target)
        print(f"ok {h}")
    except Exception as e:
        print(f"fail {h} {e}")
PY
    local FINAL="$OUTPUT_DIR/ECMWF_10day.grib2"; rm -f "$FINAL"
    local H F
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        F=$(printf "%03d" "$H")
        [ -s "$OUT/ecmwf_f${F}.grib2" ] && cat "$OUT/ecmwf_f${F}.grib2" >> "$FINAL"
    done
    [ -s "$FINAL" ] && echo "  ECMWF → $FINAL ($(human $(size_of "$FINAL")))"
}

download_icon() {
    server_reachable "https://opendata.dwd.de/weather/nwp/icon/grib/" "DWD" || return 1
    if ! check_cdo || ! check_wgrib2; then
        echo "  ICON requires cdo and wgrib2."; return 1
    fi
    local total_gb; total_gb=$(estimate_icon_gb)
    echo
    echo "  ICON total download: ~${total_gb} GB (no area cropping)"
    read -r -p "  Proceed? [y/N]: " go
    [ "$go" != "y" ] && [ "$go" != "Y" ] && return 1
    local OUT="$OUTPUT_DIR/icon" RAW="$OUTPUT_DIR/icon/raw"
    mkdir -p "$OUT" "$RAW"
    local CYCLE="" C
    for C in 18 12 06 00; do
        local CODE
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -A "$UA" --max-time 10 \
                    "https://opendata.dwd.de/weather/nwp/icon/grib/${C}/t_2m/")
        [ "$CODE" = "200" ] && { CYCLE="$C"; break; }
    done
    [ -z "$CYCLE" ] && { echo "  No ICON run found."; return 1; }
    echo "  Using ICON run: ${CYCLE}z"
    local TODAY; TODAY=$(date -u +%Y%m%d)
    local PARAMS=()
    [ "$VAR_TEMP" = "y" ]     && PARAMS+=("t_2m")
    [ "$VAR_WIND" = "y" ]     && PARAMS+=("u_10m" "v_10m")
    [ "$VAR_GUST" = "y" ]     && PARAMS+=("gust_10m")
    [ "$VAR_CAPE" = "y" ]     && PARAMS+=("cape_ml")
    [ "$VAR_CLOUD" = "y" ]    && PARAMS+=("clct")
    [ "$VAR_PRECIP" = "y" ]   && PARAMS+=("tot_prec")
    [ ${#PARAMS[@]} -eq 0 ] && { echo "  No compatible variables."; return 1; }
    echo "  Parameters: ${PARAMS[*]}"
    local param H F FILE DEST
    for param in "${PARAMS[@]}"; do
        echo "  $param:"
        for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
            F=$(printf "%03d" "$H")
            FILE="icon_global_icosahedral_single-level_${TODAY}${CYCLE}_${F}_${param}.grib2.bz2"
            DEST="$RAW/$FILE"
            [ -s "$DEST" ] && continue
            do_download "https://opendata.dwd.de/weather/nwp/icon/grib/${CYCLE}/${param}/${FILE}" \
                        "$DEST" 2>/dev/null || true
        done
    done
    echo "  Regridding ..."
    local GRIB_OUT="$OUTPUT_DIR/ICON_10day.grib2"; rm -f "$GRIB_OUT"
    local f
    for f in "$RAW"/*.bz2; do
        [ -s "$f" ] || continue
        local base; base=$(basename "$f" .bz2)
        local dec="$RAW/$base"
        bunzip2 -k -f -c "$f" > "$dec" 2>/dev/null
        [ -s "$dec" ] || continue
        local rg="$OUT/regridded_$base"
        cdo -f grb2 remapbil,r720x361 "$dec" "$rg" 2>/dev/null
        if [ -s "$rg" ]; then
            local cp="$OUT/cropped_$base"
            wgrib2 "$rg" -small_grib "${LEFT_LON}:${RIGHT_LON}" \
                          "${BOTTOM_LAT}:${TOP_LAT}" "$cp" 2>/dev/null
            [ -s "$cp" ] && cat "$cp" >> "$GRIB_OUT"
        fi
        rm -f "$dec" "$rg" "$cp"
    done
    rm -rf "$RAW"
    [ -s "$GRIB_OUT" ] && echo "  ICON → $GRIB_OUT ($(human $(size_of "$GRIB_OUT")))"
}

# ============================================================
# SECTION 10 - Combine
# ============================================================
combine_atmos() {
    local cycle="${1:-}" c="" rtok; rtok=$(res_token)
    [ -n "$cycle" ] && c="${cycle##* }"
    local dir; dir=$(atm_dir)
    local final="$OUTPUT_DIR/GFS_Area_10day.grib2"; rm -f "$final"
    local H F namepat f
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        F=$(printf "%03d" "$H")
        if [ -n "$c" ]; then namepat="gfs.t${c}z.pgrb2*.${rtok}.f${F}.grib2"
        else namepat="gfs.t*z.pgrb2*.${rtok}.f${F}.grib2"; fi
        while IFS= read -r -d '' f; do
            [ -s "$f" ] && cat "$f" >> "$final"
        done < <(find "$dir" -maxdepth 1 -name "$namepat" -print0 2>/dev/null)
    done
    [ -s "$final" ] && echo "  Atmos → $final ($(human $(size_of "$final")))"
}

combine_waves() {
    local cycle="${1:-}" c=""
    [ -n "$cycle" ] && c="${cycle##* }"
    local dir; dir=$(wave_dir)
    local final="$OUTPUT_DIR/GFS_Wave_10day.grib2"; rm -f "$final"
    local H F namepat f
    for ((H=0; H<=FORECAST_HOURS; H+=INTERVAL)); do
        F=$(printf "%03d" "$H")
        if [ -n "$c" ]; then namepat="gfswave.t${c}z.global.${WAVE_RES}.f${F}.grib2"
        else namepat="gfswave.t*z.global.${WAVE_RES}.f${F}.grib2"; fi
        while IFS= read -r -d '' f; do
            [ -s "$f" ] && cat "$f" >> "$final"
        done < <(find "$dir" -maxdepth 1 -name "$namepat" -print0 2>/dev/null)
    done
    [ -s "$final" ] && echo "  Waves → $final ($(human $(size_of "$final")))"
}

combine_all() {
    # IMPORTANT:
    # A combined environmental GRIB contains at most ONE current
    # source.  The old code appended both RTOFS and HYCOM whenever
    # both stale files happened to exist in OUTPUT_DIR.  That produced
    # ambiguous duplicate current fields.
    #
    # The selected MODEL determines the current source:
    #   gfs_plus_wave_rtofs -> RTOFS
    #   gfs_plus_wave_hycom -> HYCOM
    #   rtofs                -> RTOFS
    #   hycom*               -> HYCOM
    #
    # Standalone GFS/GFS+wave contains no current source.
    #
    # Two destination folders, two different app requirements:
    #   OpenCPN/  - one merged GRIB2, currents included (GRIB2-native
    #               readers: OpenCPN, qtVlm).
    #   Xygrib/   - wind/wave GRIB2 and the GRIB1 currents companion
    #               kept as SEPARATE files (XyGrib can't read GRIB2
    #               currents at all, and needs its own GRIB1 file).
    local -a parts=() tags=()        # everything -> OpenCPN
    local -a ww_parts=() ww_tags=()  # wind/wave only, no currents -> Xygrib

    # One wind/atmos source only.
    case "$MODEL" in
        gfs|gfs_wave|gfs_plus_wave|gfs_plus_wave_rtofs|gfs_plus_wave_hycom|gfs_plus_wave_seatemp)
            [ -s "$OUTPUT_DIR/GFS_Area_10day.grib2" ] && {
                parts+=("$OUTPUT_DIR/GFS_Area_10day.grib2"); tags+=("GFS-wind")
                ww_parts+=("$OUTPUT_DIR/GFS_Area_10day.grib2"); ww_tags+=("GFS-wind")
            }
            ;;
        ecmwf)
            [ -s "$OUTPUT_DIR/ECMWF_10day.grib2" ] && {
                parts+=("$OUTPUT_DIR/ECMWF_10day.grib2"); tags+=("ECMWF")
                ww_parts+=("$OUTPUT_DIR/ECMWF_10day.grib2"); ww_tags+=("ECMWF")
            }
            ;;
        icon)
            [ -s "$OUTPUT_DIR/ICON_10day.grib2" ] && {
                parts+=("$OUTPUT_DIR/ICON_10day.grib2"); tags+=("ICON")
                ww_parts+=("$OUTPUT_DIR/ICON_10day.grib2"); ww_tags+=("ICON")
            }
            ;;
        rtofs|hycom|hycom_seatemp)
            # Current-only selections intentionally contain no wind.
            ;;
    esac

    # Waves belong to the GFS family only.
    case "$MODEL" in
        gfs_wave|gfs_plus_wave|gfs_plus_wave_rtofs|gfs_plus_wave_hycom|gfs_plus_wave_seatemp)
            [ -s "$OUTPUT_DIR/GFS_Wave_10day.grib2" ] && {
                parts+=("$OUTPUT_DIR/GFS_Wave_10day.grib2"); tags+=("wave")
                ww_parts+=("$OUTPUT_DIR/GFS_Wave_10day.grib2"); ww_tags+=("wave")
            }
            ;;
    esac

    # Exactly ONE current source, selected by MODEL. Tracked separately
    # (not folded into ww_parts) so it never ends up merged into the
    # XyGrib wind/wave GRIB2.
    local current_file="" current_grib1="" current_tag=""
    case "$MODEL" in
        gfs_plus_wave_rtofs|rtofs)
            current_file="$OUTPUT_DIR/RTOFS_Currents.grib2"
            current_grib1="$OUTPUT_DIR/RTOFS_Currents_XyGrib.grb"
            current_tag="RTOFS"
            ;;
        gfs_plus_wave_hycom|hycom|hycom_seatemp)
            current_file="$OUTPUT_DIR/HYCOM_Currents.grib2"
            current_grib1="$OUTPUT_DIR/HYCOM_Currents_XyGrib.grb"
            current_tag="HYCOM"
            ;;
    esac

    if [ -n "$current_file" ] && [ -s "$current_file" ]; then
        parts+=("$current_file")
        tags+=("$current_tag")
    fi

    # Sea temperature is an optional HYCOM product. It is not a second
    # current source, so it may be included when explicitly requested.
    # It belongs in both the OpenCPN merge and the XyGrib wind/wave
    # GRIB2 (XyGrib reads GRIB2 sea temp fine -- only currents need the
    # GRIB1 workaround).
    if [ "$MODEL" = "hycom_seatemp" ] || [ "$MODEL" = "gfs_plus_wave_seatemp" ]; then
        [ -s "$OUTPUT_DIR/HYCOM_SeaTemp.grib2" ] && {
            parts+=("$OUTPUT_DIR/HYCOM_SeaTemp.grib2"); tags+=("HYCOM-SST")
            ww_parts+=("$OUTPUT_DIR/HYCOM_SeaTemp.grib2"); ww_tags+=("HYCOM-SST")
        }
    fi

    [ ${#parts[@]} -eq 0 ] && {
        echo "  No products selected/available to combine."
        return 1
    }

    local OPENCPN_D; OPENCPN_D=$(opencpn_dir); mkdir -p "$OPENCPN_D"
    local XYGRIB_D;  XYGRIB_D=$(xygrib_dir);   mkdir -p "$XYGRIB_D"

    local stamp; stamp=$(date -u +%Y%m%d-%H%M)
    local days=$(( FORECAST_HOURS / 24 ))
    local f

    # ---- OpenCPN: everything merged into one GRIB2, currents included ----
    # Human-readable filename.  Examples:
    #   GFS-wind-wave-HYCOM_10d_20260915-0200Z.grib2
    #   GFS-wind-wave-RTOFS_10d_20260915-0200Z.grib2
    #   GFS-wind-wave_10d_20260915-0200Z.grib2
    local tag; tag=$(IFS=- ; echo "${tags[*]}")
    local out="$OPENCPN_D/${tag}_${days}d_${stamp}Z.grib2"
    rm -f "$out"
    for f in "${parts[@]}"; do
        cat "$f" >> "$out" || {
            rm -f "$out"
            echo "  Combine failed while reading $f"
            return 1
        }
    done
    [ -s "$out" ] || {
        rm -f "$out"
        echo "  Combined file is empty."
        return 1
    }
    local latest="$OPENCPN_D/GFS_All_latest.grib2"
    rm -f "$latest"
    ln -s "$(basename "$out")" "$latest"

    echo
    echo "  OpenCPN / qtVlm  (merged GRIB2, currents included):"
    echo "    $out ($(human $(size_of "$out")))"
    echo "    latest -> OpenCPN/GFS_All_latest.grib2"

    # ---- XyGrib: wind/wave GRIB2 (no currents) + separate GRIB1 currents ----
    rm -f "$XYGRIB_D/HYCOM_Currents_XyGrib.grb" "$XYGRIB_D/RTOFS_Currents_XyGrib.grb"

    if [ ${#ww_parts[@]} -gt 0 ]; then
        local ww_tag; ww_tag=$(IFS=- ; echo "${ww_tags[*]}")
        local ww_out="$XYGRIB_D/${ww_tag}_${days}d_${stamp}Z.grib2"
        rm -f "$ww_out"
        for f in "${ww_parts[@]}"; do
            cat "$f" >> "$ww_out" || {
                rm -f "$ww_out"
                echo "  Combine failed while reading $f"
                return 1
            }
        done
        if [ -s "$ww_out" ]; then
            local ww_latest="$XYGRIB_D/GFS_WindWave_latest.grib2"
            rm -f "$ww_latest"
            ln -s "$(basename "$ww_out")" "$ww_latest"
            echo
            echo "  XyGrib  (wind/wave GRIB2, currents kept separate):"
            echo "    $ww_out ($(human $(size_of "$ww_out")))"
            echo "    latest -> Xygrib/GFS_WindWave_latest.grib2"
        fi
    fi

    if [ -n "$current_grib1" ] && [ -s "$current_grib1" ]; then
        cp -f "$current_grib1" "$XYGRIB_D/$(basename "$current_grib1")"
        echo "  XyGrib  (currents, GRIB1, NOT merged with wind/wave):"
        echo "    $XYGRIB_D/$(basename "$current_grib1") ($(human $(size_of "$current_grib1")))"
    fi

    echo
    echo "  CONTENTS → ${tags[*]}"
    echo "  CURRENT  → ${current_tag:-none}"
}

# ============================================================
# SECTION 11 - Clean
# ============================================================
run_clean() {
    local depth="$1"
    local ask_confirm="${2:-y}"
    local total=0 count=0
    local -a candidates=()
    local f

    case "$depth" in
        1)
            while IFS= read -r -d '' f; do
                candidates+=("$f"); total=$((total + $(size_of "$f"))); count=$((count+1))
            done < <(find "$OUTPUT_DIR" -type f \
                    \( -name '*.grib2' -o -name '*.grb2' -o -name '*.grb' -o -name '*.nc' \) \
                    -print0 2>/dev/null)
            ;;
        2)
            while IFS= read -r -d '' f; do
                local age_days=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
                if [ "$age_days" -ge 7 ]; then
                    candidates+=("$f"); total=$((total + $(size_of "$f"))); count=$((count+1))
                fi
            done < <(find "$OUTPUT_DIR" -type f \
                    \( -name '*.grib2' -o -name '*.grb2' -o -name '*.grb' -o -name '*.nc' \) \
                    -print0 2>/dev/null)
            ;;
        *) echo "  Unknown depth: $depth"; return 1 ;;
    esac

    if [ "$count" -eq 0 ]; then
        echo "  Nothing to clean (depth=$depth)."
        return 0
    fi

    echo "  Depth $depth: $count files, $(human "$total") reclaimable."
    if [ "$ask_confirm" = "y" ]; then
        echo "  Files:"
        for f in "${candidates[@]}"; do
            echo "    $(human $(size_of "$f"))  $f"
        done
        echo
        read -r -p "  Delete these? [y/N]: " ans
        [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "  Cancelled."; return 1; }
    fi

    local removed=0
    for f in "${candidates[@]}"; do rm -f "$f" && removed=$((removed + 1)); done
    find "$OUTPUT_DIR" -type l -xtype l -delete 2>/dev/null
    echo "  Deleted $removed files, freed $(human "$total")."
    return 0
}

clean_submenu() {
    while true; do
        clear
        echo "============================================================"
        echo "  CLEAN OPTIONS"
        echo "============================================================"
        echo
        echo "  [1] Auto-clean after download : $(yn "$AUTO_CLEAN")"
        echo "      When ON, a prompt appears after each successful download"
        echo "      asking whether to delete files older than 7 days."
        echo
        echo "  [2] Clean now: delete ALL GRIB files"
        echo "      Removes every .grib2, .grb2, .grb and .nc in the output"
        echo "      directory and all its subdirectories."
        echo
        echo "  [3] Clean now: delete files older than 7 days"
        echo "      Keeps recent downloads; removes anything a week or older."
        echo
        echo "  [4] Back to main menu"
        echo
        echo "============================================================"
        read -r -p "Choice: " c
        case "$c" in
            1)
                if [ "$AUTO_CLEAN" = "y" ]; then AUTO_CLEAN="n"; else AUTO_CLEAN="y"; fi
                save_config
                ;;
            2)
                echo
                read -r -p "  Delete ALL GRIB files? [y/N]: " conf
                if [ "$conf" = "y" ] || [ "$conf" = "Y" ]; then
                    run_clean 1 "n"
                fi
                read -r -p "  Press Enter."
                ;;
            3)
                echo
                read -r -p "  Delete files older than 7 days? [y/N]: " conf
                if [ "$conf" = "y" ] || [ "$conf" = "Y" ]; then
                    run_clean 2 "n"
                fi
                read -r -p "  Press Enter."
                ;;
            4) return ;;
        esac
    done
}

post_download_clean_prompt() {
    [ "$AUTO_CLEAN" = "y" ] || return 0

    local total=0 count=0
    local -a candidates=()
    local f
    while IFS= read -r -d '' f; do
        local ad=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
        if [ "$ad" -ge 7 ]; then
            candidates+=("$f")
            total=$((total + $(size_of "$f")))
            count=$((count + 1))
        fi
    done < <(find "$OUTPUT_DIR" -type f \
                   \( -name '*.grib2' -o -name '*.grb2' -o -name '*.grb' -o -name '*.nc' \) \
                   -print0 2>/dev/null)

    [ "$count" -eq 0 ] && return 0

    echo
    echo "============================================================"
    echo "  CLEANUP"
    echo "============================================================"
    echo "  Files older than 7 days : $count"
    echo "  Total size              : $(human "$total")"
    echo
    read -r -p "  Delete these old files? [y/N]: " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        local removed=0
        for f in "${candidates[@]}"; do rm -f "$f" && removed=$((removed + 1)); done
        find "$OUTPUT_DIR" -type l -xtype l -delete 2>/dev/null
        echo "  Deleted $removed files, freed $(human "$total")."
    else
        echo "  Skipped. Old files kept."
    fi
}

# ============================================================
# SECTION 12 - Pre-download check
# ============================================================
pre_download_check() {
    local kind="$1" cycle="${2:-}"
    if [ -z "$cycle" ]; then
        cycle=$(detect_latest_cycle) || true
    fi
    [ -z "$cycle" ] && { echo "No cycle available."; return 1; }
    echo
    echo "  PRE-DOWNLOAD CHECK ($kind)"
    echo "  Cycle: ${cycle}"
    local counts; counts=$(count_local "$kind" "$cycle")
    echo "  Local: ${counts% *} / ${counts##* }"
    local est; est=$(estimate_size "$kind" "$cycle")
    echo "  Missing: ${est##* } files, ~$(human "${est% *}")"
    [ "${est##* }" -eq 0 ] && { echo "  All present."; return 0; }
    return 0
}

pre_download_check_rtofs() {
    echo
    echo "  PRE-DOWNLOAD CHECK (rtofs)"
    local probe
    probe=$(rtofs_find_date_and_listing) || {
        echo "  No usable RTOFS data in last 4 days."; return 1
    }
    local DATE listing
    DATE=$(echo "$probe" | head -1)
    listing=$(echo "$probe" | tail -n +2)
    local nfiles
    nfiles=$(echo "$listing" | \
             grep -oE 'rtofs_glo\.t00z\.[nf][0-9]{3}_trop_paci[a-z_]*_std\.grb2' \
             | sort -u | wc -l)
    echo "  RTOFS date: $DATE ($nfiles matching files)"
    return 0
}

# ============================================================
# SECTION 13 - Menu
# ============================================================
show_menu() {
    clear
    local sat_label="OFF"
    [ "$SATELLITE" = "y" ] && sat_label="ON"
    echo "============================================================"
    echo "  GRIB DOWNLOADER  v2.17                       [SAT mode: ${sat_label}]"
    echo "============================================================"
    echo "  SERVERS                            checked $(status_age)"
    local srv
    for srv in NOMADS NOMADS_CGI NOMADS_WAVE HYCOM DWD ECMWF ECMWF_LIB CDO WGRIB2 GRIB_TOOLS; do
        local line; line=$(status_value "$srv")
        local st="${line%%|*}"
        local rest="${line#*|}"; local code="${rest%%|*}"; local rtt="${rest##*|}"
        local sym; sym=$(status_symbol "$st")
        local label
        case "$srv" in
            NOMADS) label="NOMADS ......" ;;
            NOMADS_CGI) label="NOMADS atmos ." ;;
            NOMADS_WAVE) label="NOMADS wave .." ;;
            HYCOM) label="HYCOM ......." ;;
            DWD) label="DWD ICON ...." ;;
            ECMWF) label="ECMWF ......." ;;
            ECMWF_LIB) label="ECMWF py-lib " ;;
            CDO) label="cdo ........." ;;
            WGRIB2) label="wgrib2 ......" ;;
            GRIB_TOOLS) label="grib tools .." ;;
        esac
        if [ "$srv" = "ECMWF_LIB" ] || [ "$srv" = "CDO" ] || \
           [ "$srv" = "WGRIB2" ] || [ "$srv" = "GRIB_TOOLS" ]; then
            printf "    %-14s %s %s\n" "$label" "$sym" "$st"
        else
            printf "    %-14s %s %-7s %s   RTT %s ms\n" "$label" "$sym" "$st" "$code" "$rtt"
        fi
    done
    echo
    echo "  AREA          : ${TOP_LAT}/${LEFT_LON}  →  ${BOTTOM_LAT}/${RIGHT_LON}"
    case "$MODEL" in
        ecmwf)
            echo "  MODEL         : ecmwf  (TOTAL ~$(estimate_ecmwf_gb) GB)"
            ;;
        icon)
            echo "  MODEL         : icon  (TOTAL ~$(estimate_icon_gb) GB)  GRID: $(pretty_res "$ICON_RES")°"
            ;;
        rtofs)
            echo "  MODEL         : rtofs"
            echo "  CURRENTS      : RTOFS 1°, single nowcast"
            echo "                  GRIB2: RTOFS_Currents.grib2 (OpenCPN, qtVlm)"
            echo "                  GRIB1: RTOFS_Currents_XyGrib.grb (XyGrib)"
            ;;
        hycom|hycom_seatemp)
            echo "  MODEL         : $MODEL"
            echo "  CURRENTS      : HYCOM 0.08°, ${HYCOM_DAYS}-day forecast"
            echo "                  GRIB2: HYCOM_Currents.grib2 (OpenCPN, qtVlm)"
            echo "                  GRIB1: HYCOM_Currents_XyGrib.grb (XyGrib)"
            [ "$VAR_SEATEMP" = "y" ] && echo "  SEATEMP       : HYCOM_SeaTemp.grib2"
            ;;
        gfs_plus_wave_rtofs)
            echo "  MODEL         : gfs_plus_wave_rtofs   RESOLUTION: ${RESOLUTION}°"
            echo "  WAVE GRID     : global $(pretty_res "$WAVE_RES")°"
            echo "  CURRENTS      : RTOFS 1°"
            echo "                  RTOFS_Currents.grib2 + RTOFS_Currents_XyGrib.grb"
            ;;
        gfs_plus_wave_hycom)
            echo "  MODEL         : gfs_plus_wave_hycom   RESOLUTION: ${RESOLUTION}°"
            echo "  WAVE GRID     : global $(pretty_res "$WAVE_RES")°"
            echo "  CURRENTS      : HYCOM 0.08°"
            echo "                  HYCOM_Currents.grib2 + HYCOM_Currents_XyGrib.grb"
            [ "$VAR_SEATEMP" = "y" ] && echo "  SEATEMP       : HYCOM_SeaTemp.grib2"
            ;;
        gfs_plus_wave_seatemp)
            echo "  MODEL         : gfs_plus_wave_seatemp   RESOLUTION: ${RESOLUTION}°"
            echo "  WAVE GRID     : global $(pretty_res "$WAVE_RES")°"
            echo "  SEATEMP       : HYCOM_SeaTemp.grib2"
            ;;
        gfs_wave|gfs_plus_wave)
            echo "  MODEL         : ${MODEL}   RESOLUTION: ${RESOLUTION}°"
            echo "  WAVE GRID     : global $(pretty_res "$WAVE_RES")°"
            ;;
        *)
            echo "  MODEL         : ${MODEL}   RESOLUTION: ${RESOLUTION}°"
            ;;
    esac
    echo "  FORECAST      : 0–${FORECAST_HOURS} h @ ${INTERVAL} h  ($(( FORECAST_HOURS / 24 )) days)"
    echo
    echo "  VARIABLES"
    printf "    %-8s %s   %-8s %s   %-8s %s   %-8s %s\n" \
        "precip" "$(yn $VAR_PRECIP)" "wind" "$(yn $VAR_WIND)" \
        "waves"  "$(yn $VAR_WAVES)"  "swell" "$(yn $VAR_SWELL)"
    printf "    %-8s %s   %-8s %s   %-8s %s   %-8s %s\n" \
        "gust" "$(yn $VAR_GUST)" "temp" "$(yn $VAR_TEMP)" \
        "cape" "$(yn $VAR_CAPE)" "cloud" "$(yn $VAR_CLOUD)"
    printf "    %-8s %s   %-8s %s   %-8s %s\n" \
        "humid" "$(yn $VAR_HUMIDITY)" \
        "current" "$(yn $VAR_CURRENTS)" \
        "SeaTemp" "$(yn $VAR_SEATEMP)"
    echo
    echo "  DOWNLOAD"
    echo "    Parallel : ${PARALLEL}   atmos/$(effective_parallel wave) wave/1 currents"
    echo "    Auto-clean: $(yn "$AUTO_CLEAN") (after download, >7 days)"
    echo "    Output   : ${OUTPUT_DIR}"
    echo
    echo "  STATUS"
    if [ -n "$LAST_CYCLE" ]; then
        local age; age=$(cycle_age_hours "$LAST_CYCLE")
        echo "    Last cycle : ${LAST_CYCLE}  (age ${age} h)"
    fi
    local next; next=$(next_cycle_eta)
    echo "    Next cycle : ${next%|*}  (in $(secs_to_hms "${next##*|}"))"
    echo
    echo "============================================================"
    echo "  [1] Area             [2] Model / resolution"
    echo "  [3] Variables        [4] Forecast"
    echo "  [5] Download opts    [6] Probe parallel limit"
    echo "  [7] Satellite mode   [8] Re-scan files"
    echo "  [N] Days             [M] Combine all"
    echo "  [C] Clean options    [S] Cycle schedule"
    echo "  [R] Refresh servers  [9] Aggressive mode"
    echo "  [H] Help             [D] Download"
    echo "  [Q] Quit"
    echo "============================================================"
}

# ============================================================
# SECTION 14 - Menu handlers
# ============================================================
change_area() {
    echo
    local lat1 lat2 lon1 lon2
    lat1=$(ask "Latitude 1"  "$TOP_LAT")
    lat2=$(ask "Latitude 2"  "$BOTTOM_LAT")
    lon1=$(ask "Longitude 1" "$LEFT_LON")
    lon2=$(ask "Longitude 2" "$RIGHT_LON")
    TOP_LAT=$(num_max "$lat1" "$lat2"); BOTTOM_LAT=$(num_min "$lat1" "$lat2")
    LEFT_LON=$(num_min "$lon1" "$lon2"); RIGHT_LON=$(num_max "$lon1" "$lon2")
    echo "  N=${TOP_LAT}  S=${BOTTOM_LAT}  W=${LEFT_LON}  E=${RIGHT_LON}"
    read -r -p "  Press Enter."
}

change_model() {
    local egb igb; egb=$(estimate_ecmwf_gb); igb=$(estimate_icon_gb)
    echo
    echo "  1) GFS                  2) GFS-Wave"
    echo "  3) GFS + Wave           4) GFS + Wave + RTOFS"
    echo "  5) GFS + Wave + HYCOM   6) GFS + Wave + SeaTemp"
    echo "  7) RTOFS                8) HYCOM"
    echo "  9) HYCOM + SeaTemp     10) ECMWF  (~${egb} GB total)"
    echo " 11) ICON  (~${igb} GB total)"
    case "$(ask "Choice" "3")" in
        1) MODEL="gfs" ;; 2) MODEL="gfs_wave" ;; 3) MODEL="gfs_plus_wave" ;;
        4) MODEL="gfs_plus_wave_rtofs" ;; 5) MODEL="gfs_plus_wave_hycom" ;;
        6) MODEL="gfs_plus_wave_seatemp" ;; 7) MODEL="rtofs" ;;
        8) MODEL="hycom" ;; 9) MODEL="hycom_seatemp" ;;
        10) MODEL="ecmwf" ;; 11) MODEL="icon" ;;
    esac
    case "$MODEL" in
        rtofs|hycom|hycom_seatemp)
            echo "  (Native grid - resolution not applicable)" ;;
        gfs_wave)
            echo "  Wave grid: 1) 0.16°  2) 0.25°"
            case "$(ask "Choice" "1")" in 1) WAVE_RES="0p16";; 2) WAVE_RES="0p25";; esac ;;
        ecmwf)
            echo "  ECMWF total: ~${egb} GB (no area cropping)"
            read -r -p "  Continue? [y/N]: " c
            [ "$c" != "y" ] && [ "$c" != "Y" ] && MODEL="gfs_plus_wave" ;;
        icon)
            echo "  ICON total: ~${igb} GB (no area cropping)"
            read -r -p "  Continue? [y/N]: " c
            [ "$c" != "y" ] && [ "$c" != "Y" ] && MODEL="gfs_plus_wave" ;;
        *)
            echo "  Resolution: 1) 0.25°  2) 0.50°  3) 1.00°"
            case "$(ask "Choice" "1")" in 1) RESOLUTION="0.25";; 2) RESOLUTION="0.5";; 3) RESOLUTION="1.0";; esac
            if [ "$MODEL" = "gfs_plus_wave" ] || [ "$MODEL" = "gfs_plus_wave_rtofs" ] || \
               [ "$MODEL" = "gfs_plus_wave_hycom" ] || [ "$MODEL" = "gfs_plus_wave_seatemp" ]; then
                echo "  Wave grid: 1) 0.16°  2) 0.25°"
                case "$(ask "Choice" "1")" in 1) WAVE_RES="0p16";; 2) WAVE_RES="0p25";; esac
            fi ;;
    esac
    case "$MODEL" in
        gfs_plus_wave_rtofs|gfs_plus_wave_hycom|rtofs|hycom)
            VAR_CURRENTS="y"; VAR_SEATEMP="n" ;;
        gfs_plus_wave_seatemp|hycom_seatemp)
            VAR_CURRENTS="y"; VAR_SEATEMP="y" ;;
        gfs|gfs_wave|gfs_plus_wave|ecmwf|icon)
            VAR_CURRENTS="n"; VAR_SEATEMP="n" ;;
    esac
    if [ "$MODEL" = "hycom" ] || [ "$MODEL" = "hycom_seatemp" ] || \
       [ "$MODEL" = "gfs_plus_wave_hycom" ] || [ "$MODEL" = "gfs_plus_wave_seatemp" ]; then
        check_cdo || { echo; echo "  Note: HYCOM requires cdo."; }
    fi
    if [ "$MODEL" = "icon" ]; then
        check_cdo && check_wgrib2 || { echo; echo "  Note: ICON requires cdo and wgrib2."; }
    fi
    read -r -p "  Press Enter."
}

model_supports() {
    local m="$1" v="$2"
    case "$m" in
        gfs) case "$v" in waves|swell|currents|seatemp) return 1;; *) return 0;; esac ;;
        gfs_wave) case "$v" in waves|swell) return 0;; *) return 1;; esac ;;
        gfs_plus_wave) case "$v" in currents|seatemp) return 1;; *) return 0;; esac ;;
        gfs_plus_wave_rtofs) [ "$v" = "seatemp" ] && return 1 || return 0 ;;
        gfs_plus_wave_hycom) return 0 ;;
        gfs_plus_wave_seatemp) [ "$v" = "currents" ] && return 1 || return 0 ;;
        rtofs) [ "$v" = "currents" ] && return 0 || return 1 ;;
        hycom) case "$v" in currents|seatemp) return 0;; *) return 1;; esac ;;
        hycom_seatemp) case "$v" in currents|seatemp) return 0;; *) return 1;; esac ;;
        ecmwf|icon) case "$v" in waves|swell|currents|seatemp) return 1;; *) return 0;; esac ;;
    esac
    return 1
}

change_variables() {
    echo
    local v
    for v in PRECIP WIND WAVES SWELL GUST TEMP CAPE CLOUD HUMIDITY CURRENTS SEATEMP; do
        local lc; lc=$(echo "$v" | tr 'A-Z' 'a-z')
        if model_supports "$MODEL" "$lc"; then
            eval "local cur=\$VAR_$v"
            local new; new=$(ask "  $lc (y/n)" "$cur")
            eval "VAR_$v=\$new"
        fi
    done
    read -r -p "  Press Enter."
}

change_forecast() {
    FORECAST_HOURS=$(ask "Forecast length (h)" "$FORECAST_HOURS")
    INTERVAL=$(ask "Interval (h)" "$INTERVAL")
}

change_days() {
    echo
    echo "  1) 1 day   2) 2 days  3) 3 days  4) 5 days  5) 7 days  6) 10 days"
    local days
    case "$(ask "Choice" "6")" in
        1) days=1;; 2) days=2;; 3) days=3;; 4) days=5;; 5) days=7;; 6) days=10;;
        *) days=10;;
    esac
    [ "$days" -gt 10 ] && days=10
    FORECAST_HOURS=$(( days * 24 ))
    echo "  Forecast: ${days} days = ${FORECAST_HOURS} h"
    read -r -p "  Press Enter."
}

change_download() {
    echo
    PARALLEL=$(ask "Parallel downloads (atmos target)" "$PARALLEL")
    SLEEP=$(ask "Sleep between batches (s)" "$SLEEP")
    OUTPUT_DIR=$(ask "Output directory" "$OUTPUT_DIR")
    COMPRESS=$(ask "gzip compression (y/n)" "$COMPRESS")
    RESUME=$(ask "Resume partial (y/n)" "$RESUME")
    CONNECT_TIMEOUT=$(ask "Connect timeout (s)" "$CONNECT_TIMEOUT")
    MAX_TIMEOUT=$(ask "Max download timeout (s)" "$MAX_TIMEOUT")
    HYCOM_DAYS=$(ask "HYCOM forecast days (1-8)" "$HYCOM_DAYS")
    HYCOM_MAX_TIMEOUT=$(ask "HYCOM max transfer timeout (s)" "$HYCOM_MAX_TIMEOUT")
    HYCOM_RETRIES=$(ask "HYCOM retries" "$HYCOM_RETRIES")
    WAVE_PARALLEL_MAX=$(ask "Wave parallel cap" "$WAVE_PARALLEL_MAX")
    ICON_PARALLEL_MAX=$(ask "ICON parallel cap" "$ICON_PARALLEL_MAX")
    ECMWF_PARALLEL_MAX=$(ask "ECMWF parallel cap" "$ECMWF_PARALLEL_MAX")
    read -r -p "  Press Enter."
}

toggle_satellite() {
    if [ "$SATELLITE" = "y" ]; then
        SATELLITE="n"; PARALLEL="4"; SLEEP="1"
        CONNECT_TIMEOUT="20"; MAX_TIMEOUT="300"; RETRIES="2"
    else
        SATELLITE="y"; PARALLEL="1"; SLEEP="2"
        CONNECT_TIMEOUT="60"; MAX_TIMEOUT="1200"; RETRIES="5"
        read -r -p "  Also 0.5° / 6 h? [y/N]: " r
        [ "$r" = "y" ] && { RESOLUTION="0.5"; INTERVAL="6"; }
    fi
    read -r -p "  Press Enter."
}

toggle_aggressive() {
    if [ "$AGGRESSIVE" = "y" ]; then
        AGGRESSIVE="n"; echo "Aggressive OFF."
    else
        AGGRESSIVE="y"; echo "Aggressive ON — Parallel=8, sleep=0"
        PARALLEL="8"; SLEEP="0"
    fi
    read -r -p "  Press Enter."
}

probe_parallel() {
    local mk="SAFE_PARALLEL_${MODEL}" bk="BANNED_PARALLEL_${MODEL}"
    local cs="${!mk}" cb="${!bk:-0}"
    local url=""
    local rtok; rtok=$(res_token)
    case "$MODEL" in
        gfs|gfs_plus_wave|gfs_plus_wave_rtofs|gfs_plus_wave_hycom|gfs_plus_wave_seatemp)
            url="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_${rtok}.pl?file=gfs.t00z.pgrb2.${rtok}.f000&dir=/gfs.$(date -u +%Y%m%d)/00/atmos" ;;
        gfs_wave)
            url="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfswave.pl?file=gfswave.t00z.global.${WAVE_RES}.f000.grib2&dir=/gfs.$(date -u +%Y%m%d)/00/wave/gridded" ;;
        rtofs) url="https://nomads.ncep.noaa.gov/pub/data/nccf/com/rtofs/prod/" ;;
        hycom|hycom_seatemp) url="https://ncss.hycom.org/thredds/ncss/grid/FMRC_ESPC-D-V02_uv3z/FMRC_ESPC-D-V02_uv3z_best.ncd/dataset.html" ;;
        *) echo "  Parallel probe not available."; read -r -p "  Enter."; return ;;
    esac
    echo
    echo "  Probing $MODEL (safe=$cs banned=$cb)"
    trap 'echo; trap - INT; return' INT
    local mt=16
    [ "$cb" -gt 0 ] && mt=$(( cb - 1 ))
    [ "$mt" -gt 16 ] && mt=16
    local n i
    for n in 2 4 6 8 10 12 14 16; do
        [ "$n" -gt "$mt" ] && break
        echo -n "  $n parallel ... "
        local t0; t0=$(date +%s)
        local -a pids=()
        for ((i=0;i<n;i++)); do
            curl -s -o /dev/null -r 0-0 -A "$UA" --max-time 25 "$url" &
            pids+=($!)
        done
        local to=0
        while true; do
            local al=0 p
            for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && al=$((al+1)); done
            [ "$al" -eq 0 ] && break
            [ $(( $(date +%s) - t0 )) -ge 30 ] && { to=1; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; break; }
            sleep 0.5
        done
        for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
        if [ "$to" = "1" ]; then
            echo "TIMEOUT"
            local ns=$(( n - 1 )); [ "$ns" -lt 1 ] && ns=1
            eval "$mk=\$ns"; eval "$bk=\$n"
            save_config; trap - INT; read -r -p "  Enter."; return
        fi
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -r 0-0 -A "$UA" --max-time 15 "$url")
        case "$code" in
            200|206) echo "OK"; eval "$mk=\$n" ;;
            429|403|503|000)
                echo "THROTTLED ($code)"
                local ns=$(( n - 1 )); [ "$ns" -lt 1 ] && ns=1
                eval "$mk=\$ns"; eval "$bk=\$n"
                save_config; trap - INT; read -r -p "  Enter."; return ;;
            *) echo "unexpected ($code)"; trap - INT; read -r -p "  Enter."; return ;;
        esac
        if [ "$n" -lt "$mt" ]; then
            read -r -p "  Continue? [Enter=yes/q=stop] " c
            [ "$c" = "q" ] && { save_config; trap - INT; read -r -p "  Enter."; return; }
        fi
    done
    save_config; trap - INT; read -r -p "  Enter."
}

show_cycle_schedule() {
    echo
    echo "CYCLE SCHEDULE (GFS)"
    echo "  00z  04:30 UTC   $(date -d 'today 04:30 UTC' '+%H:%M %Z' 2>/dev/null)"
    echo "  06z  10:30 UTC   $(date -d 'today 10:30 UTC' '+%H:%M %Z' 2>/dev/null)"
    echo "  12z  16:30 UTC   $(date -d 'today 16:30 UTC' '+%H:%M %Z' 2>/dev/null)"
    echo "  18z  22:30 UTC   $(date -d 'today 22:30 UTC' '+%H:%M %Z' 2>/dev/null)"
    read -r -p "  Press Enter."
}

show_help() {
    clear
    cat <<'EOF'
============================================================
  GRIB DOWNLOADER - HELP
============================================================

MENU
  [1] Area         - bounding box (auto-sorts lat/lon)
  [2] Model        - data source and resolution
  [3] Variables    - toggle fields per model
  [4] Forecast     - length (h) and interval (h)
  [5] Download     - parallel, sleep, output dir, timeouts
  [6] Probe        - parallel tolerance test (atmos only)
  [7] Satellite    - preset for slow links
  [8] Re-scan      - recount local files
  [N] Days         - quick forecast-length picker
  [M] Combine      - build selected wind/wave/current combination
  [C] Clean        - clean options (below)
  [S] Schedule     - GFS release times
  [R] Refresh      - re-probe servers
  [9] Aggressive   - parallel=8, sleep=0
  [H] Help         - this screen
  [D] Download     - run
  [Q] Quit         - save config and exit

CLEAN SUBMENU  [C]
  [1] Auto-clean after download - toggle y/n
  [2] Clean now: delete ALL GRIB files
  [3] Clean now: delete files older than 7 days
  [4] Back

CURRENT DATA OUTPUT
  Every model that produces currents creates TWO files:

    <MODEL>_Currents.grib2
        GRIB2 U/V. Read by OpenCPN and qtVlm.

    <MODEL>_Currents_XyGrib.grb
        GRIB1 U/V. Read by XyGrib.

  XyGrib reads currents from GRIB1 files only (edition 1, NCEP
  table 2, centre 7, params 49 ucurr / 50 vcurr at surface).

VIEWER COMPATIBILITY
  OpenCPN  - GRIB2: wind, waves, currents (U/V), sea temp
  qtVlm    - GRIB2: wind, waves, currents (U/V), sea temp
  XyGrib   - GRIB2: wind, waves.  GRIB1: currents.

OUTPUT FILES
  ~/Downloads/Gribs/
    atmos/ waves/ rtofs/ hycom/    raw per-source downloads
    GFS_Area_10day.grib2           atmos only (intermediate)
    GFS_Wave_10day.grib2           waves only (intermediate)
    HYCOM_Currents.grib2           HYCOM U/V, GRIB2 (intermediate)
    HYCOM_Currents_XyGrib.grb      HYCOM U/V, GRIB1 (intermediate)
    HYCOM_SeaTemp.grib2            HYCOM sea temp (intermediate)
    RTOFS_Currents.grib2           RTOFS U/V, GRIB2 (intermediate)
    RTOFS_Currents_XyGrib.grb      RTOFS U/V, GRIB1 (intermediate)
    ECMWF_10day.grib2              ECMWF (intermediate)
    ICON_10day.grib2               ICON (intermediate)

    OpenCPN/     <- point OpenCPN / qtVlm at this folder
      <tags>_<days>d_<stamp>Z.grib2   everything merged, currents included
      GFS_All_latest.grib2            -> symlink to the newest one above

    Xygrib/      <- point XyGrib at this folder
      <tags>_<days>d_<stamp>Z.grib2   wind/wave GRIB2 only, NO currents
      GFS_WindWave_latest.grib2       -> symlink to the newest one above
      <MODEL>_Currents_XyGrib.grb     currents, GRIB1, kept as its own file

  The intermediate per-model files above stay where they've always
  been; only the two folders receive finished, app-ready output.

PARALLEL LIMITS
  atmos    : user-set (NOMADS 120 hits/min)
  wave     : min(user, cap)
  currents : 1 (RTOFS: 1 file/day, HYCOM: 1 conn/IP policy)
  ICON     : 4 (DWD no documented limit)
  ECMWF    : 2 (500 shared global connections)

REQUIRED TOOLS
  cdo, grib_copy, grib_set, wgrib2
  Install: sudo apt install cdo wgrib2 libeccodes-tools

CONFIG
  ~/.grib_downloader.conf

============================================================
EOF
    read -r -p "  Press Enter to return."
}

# ============================================================
# SECTION 15 - Dispatcher
# ============================================================
run_download() {
    local cycle
    if [ "$MODEL" = "hycom" ] || [ "$MODEL" = "hycom_seatemp" ] || \
       [ "$MODEL" = "gfs_plus_wave_hycom" ] || [ "$MODEL" = "gfs_plus_wave_seatemp" ]; then
        check_cdo || { echo "  HYCOM needs cdo."; read -r -p "  Enter."; return; }
    fi
    if [ "$MODEL" = "icon" ]; then
        check_cdo && check_wgrib2 || { echo "  ICON needs cdo + wgrib2."; read -r -p "  Enter."; return; }
    fi

    trap 'echo; echo; echo "  Cancelled. Partial files kept. Next [D] resumes."; trap - INT; return' INT

    case "$MODEL" in
        gfs)
            cycle=$(detect_latest_cycle) || { echo "No cycle."; trap - INT; read -r -p "  Enter."; return; }
            pre_download_check "atmos" "$cycle" || { trap - INT; return; }
            download_gfs "$cycle"; combine_atmos "$cycle" ;;
        gfs_wave)
            cycle=$(detect_latest_cycle) || { echo "No cycle."; trap - INT; read -r -p "  Enter."; return; }
            pre_download_check "wave" "$cycle" || { trap - INT; return; }
            download_gfswave "$cycle"; combine_waves "$cycle" ;;
        gfs_plus_wave|gfs_plus_wave_rtofs|gfs_plus_wave_hycom|gfs_plus_wave_seatemp)
            cycle=$(detect_latest_cycle) || { echo "No cycle."; trap - INT; read -r -p "  Enter."; return; }
            pre_download_check "atmos" "$cycle" || { trap - INT; return; }
            download_gfs "$cycle"; combine_atmos "$cycle"
            echo
            pre_download_check "wave" "$cycle" || { trap - INT; return; }
            download_gfswave "$cycle"; combine_waves "$cycle"
            if [ "$MODEL" = "gfs_plus_wave_rtofs" ]; then
                echo; pre_download_check_rtofs || { trap - INT; return; }; download_rtofs
            elif [ "$MODEL" = "gfs_plus_wave_hycom" ] || [ "$MODEL" = "gfs_plus_wave_seatemp" ]; then
                echo; download_hycom
            fi ;;
        rtofs)
            pre_download_check_rtofs || { trap - INT; return; }
            download_rtofs ;;
        hycom|hycom_seatemp)
            download_hycom ;;
        ecmwf)  download_ecmwf ;;
        icon)   download_icon ;;
    esac

    combine_all
    echo
    echo "============================================================"
    echo "  DOWNLOAD COMPLETE"
    echo "============================================================"
    echo

    post_download_clean_prompt

    trap 'save_config; exit 0' INT TERM
    read -r -p "  Press Enter to return to menu."
}

# ============================================================
# SECTION 16 - Main loop
# ============================================================
load_config
# Migrate the historical typo automatically.
if [ "$OUTPUT_DIR" = "$HOME/Downloads/Grips" ]; then OUTPUT_DIR="$HOME/Downloads/Gribs"; fi
mkdir -p "$OUTPUT_DIR" "$(opencpn_dir)" "$(xygrib_dir)"
probe_all
trap 'save_config; exit 0' INT TERM

while true; do
    show_menu
    read -r -p "Choice: " choice
    case "$choice" in
        1) change_area ;;
        2) change_model ;;
        3) change_variables ;;
        4) change_forecast ;;
        5) change_download ;;
        6) probe_parallel ;;
        7) toggle_satellite ;;
        8) count_local "atmos" >/dev/null; read -r -p "  Enter." ;;
        n|N) change_days ;;
        m|M) combine_all; read -r -p "  Enter." ;;
        c|C) clean_submenu ;;
        s|S) show_cycle_schedule ;;
        r|R) probe_all ;;
        h|H) show_help ;;
        9) toggle_aggressive ;;
        d|D) run_download ;;
        q|Q) save_config; exit 0 ;;
    esac
    save_config
done