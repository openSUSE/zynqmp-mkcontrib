#!/bin/bash

function show_help() {
    OSCUSER=$(osc whois | cut -d : -f 1)

    cat <<EOF
		Xilinx Ultrascale+ MPSoC OpenSUSE/SLES image creator

Usage: mkcontrib.sh -H <hdf file> -p <OBS project> [OPTION]
Create or update an OBS project based on a hardware description file (hdf)
coming from the Vivado tool suite.

Mandatory parameters:

  -H <hdf file>		The hdf file describing your hardware

Optional parameters:

  -d <distribution>	Choose target distribution. Choices are:

				tumbleweed (default)
				sles15
				leap15

  -f			Regenerate all files, losing intermediate modifications
  -p <OBS project name>	The targeted OBS project name (e.g. home:$OSCUSER:ZCU102)
                        If nothing is specified, defaults to home:$OSCUSER:Zynq
  -h			Show this help text

EOF
    exit 1
}

# Set defaults

OVERWRITE=check
DISTRO=tumbleweed
PROJECT=
SHOW_HELP=

# Parse command line

while getopts hfp:d:H: opt
do
    case $opt in
        # Mandatory
        H) HDF="$OPTARG"; ;;

	# Optional
        d) DISTRO="$OPTARG" ;;
        f) OVERWRITE=force ;;
        h) SHOW_HELP=1 ;;
        p) PROJECT="$OPTARG" ;;
        *) echo "Unknown option $opt."; show_help; ;;
    esac
done

if [ ! "$HDF" ]; then
    SHOW_HELP=1
fi

# Check that all tools are available

function check_cmd() {
    if ! which $1 &>/dev/null; then
        echo "Please install $3$2."
        exit 1
    fi
}

check_cmd "osc" " (zypper in osc)" "the Open build Service Client"
check_cmd "unzip" " (zypper in unzip)" "Unzip"
check_cmd "pixz" " (zypper in pixz)" "Parallel XZip"
check_cmd "hsi" "" "Vivado and put its bin directories into PATH"

if [ ! -e ~/.oscrc ]; then
    osc whois
fi

OSCUSER=$(osc whois | cut -d : -f 1)
[ "$PROJECT" ] || PROJECT="home:$OSCUSER:Zynq"

if [ "$SHOW_HELP" ]; then
    show_help
fi

# Create and populate the project

function cleanup() {
    rm -rf "$TMPDIR"
}

TMPDIR=$(mktemp -d)
trap cleanup EXIT
set -ex

HDFDIR="$TMPDIR/hdf"
mkdir "$HDFDIR"
unzip "$HDF" -d "$HDFDIR"

cp "$HDF" $TMPDIR/system.hdf

# Generate firmware files (fsbl, pmufw, dts)

# XXX create upstream DTs by basing on upstream branch?
(
    mkdir "$TMPDIR/fw"
    cd "$TMPDIR/fw"
    git clone --depth=1 git://github.com/Xilinx/device-tree-xlnx.git
    hsi <<-EOF
	set hwdsgn [open_hw_design ../system.hdf]
	generate_app -hw \$hwdsgn -os standalone -proc psu_pmu_0 -app zynqmp_pmufw -compile -sw pmufw -dir pmufw
	generate_app -hw \$hwdsgn -os standalone -proc psu_cortexa53_0 -app zynqmp_fsbl -compile -sw fsbl -dir fsbl
	set_repo_path device-tree-xlnx
	create_sw_design device-tree -os device_tree -proc psu_cortexa53_0
	generate_target -dir dts
	exit
	EOF

    # Convert device tree into something upstream compatible
    for i in $(find dts -type f); do
        sed 's/xlnx,zynqmp-clk/fixed-clock/' < $i |
            grep -v 'power-domains =' > $i.tmp
        mv $i.tmp $i
    done

    # Package them up
    for i in fsbl pmufw dts; do
        tar c $i | pixz > $i.tar.xz
    done
)

# Create project

case "$DISTRO" in
    tumbleweed)		PPRJ=devel:ARM:Factory:Contrib:Zynq
			DISTRONAME="openSUSE Tumbleweed" ;;
    leap15)		PPRJ=devel:ARM:Leap:15.0:Contrib:Zynq
			DISTRONAME="openSUSE Leap 15.0" ;;
    sles15)		PPRJ=devel:ARM:SLES:15.0:Contrib:Zynq
			DISTRONAME="SLES 15" ;;
    *)			echo "Unknown distribution: $DISTRO"; exit 1 ;;
esac

if ! osc meta prj $PROJECT &>/dev/null; then
    # Project does not exist yet, add it

    osc meta prj -F - $PROJECT <<-EOF
	<project name="$PROJECT">
	  <title>$DISTRONAME images for a ZynqMP board</title>
	  <description>$DISTRONAME images for a ZynqMP board</description>
	  <person userid="$OSCUSER" role="maintainer"/>
	</project>
	EOF

    osc meta prjconf -F - $PROJECT <<-EOF
	%if "%_repository" == "images"
	Type: kiwi
	Repotype: staticlinks
	Patterntype: none
	%endif
	EOF
fi

PRJMETA="$(osc meta prj $PROJECT)"
if ! echo "$PRJMETA" | grep -q "repository name=standard"; then
    # Add package repo first ...
    PRJMETA_NOEND=`echo "$PRJMETA" | grep -v '</project>'`
    osc meta prj -F - $PROJECT <<-EOF
	$PRJMETA_NOEND
	  <repository name="standard">
	    <path project="$PPRJ" repository="standard"/>
	    <arch>aarch64</arch>
	  </repository>
	</project>
	EOF

    # Then add the image repo
    PRJMETA="$(osc meta prj $PROJECT)"
    PRJMETA_NOEND=`echo "$PRJMETA" | grep -v '</project>'`
    osc meta prj -F - $PROJECT <<-EOF
	$PRJMETA_NOEND
	  <repository name="images">
	    <path project="$PROJECT" repository="standard"/>
	    <arch>aarch64</arch>
	  </repository>
	</project>
	EOF
fi

# Add packages

function enable_pkg() {
    osc meta pkg $PROJECT $1 | grep -v 'disable repository' | grep -v '<disable/>' | osc meta pkg -F - $PROJECT $1
}

for i in zynqmp-bootbin zynqmp-fsbl zynqmp-hdf zynqmp-pmufw zynqmp-dts zynqmp-instsd; do
    osc linkpac -f $PPRJ $i $PROJECT
    enable_pkg $i
done

(
    cd "$TMPDIR/"

    for i in fsbl pmufw dts; do
        osc co $PROJECT/zynqmp-$i
        (
            cd $PROJECT/zynqmp-$i
            cp ../../fw/$i.tar.xz .
            osc add $i.tar.xz
            osc ci -m "Update $i binary"
        )
    done

    osc co $PROJECT/zynqmp-hdf
    cd $PROJECT/zynqmp-hdf
    cp ../../system.hdf .
    osc add system.hdf
    osc ci -m "Update hdf"
)

# Add image
IMG=JeOS-zynqmp

osc linkpac -f $PPRJ $IMG $PROJECT
enable_pkg $IMG

# Fix up contrib repo link
if [ $IMG = "JeOS-zynqmp" ]; then
    (
    cd "$TMPDIR/"

    osc co $PROJECT $IMG
    cd $PROJECT/$IMG

    rm -rf x y
    mkdir -p x/kiwi-hooks
    echo "$PROJECT" > x/kiwi-hooks/contrib_repo

    TGZ=contrib-repo-zynqmp.tgz
    tar -czf $TGZ --owner root --group root -C x kiwi-hooks
    rm -rf x
    )
fi
