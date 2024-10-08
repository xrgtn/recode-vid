#!/bin/sh

usage() {
    PROG="$1"
    echo "USAGE: $PROG [opts] in out
    or: $PROG [opts] -id in [out]
    $PROG opts:
	-ac	X	use audio codec X [libvorbis]
	-af	F	append audio filter F
	-afpre	F	prepend audio filter F
	-aid	X	audio stream selector [default|0]
	-alang	L	set audio stream language L
	-arate	R	set audio rate R
	-asd	S	set asyncts min_delta to S [0.3]
	-h	H	scale to height H, for example:
			-h 480	means scale to 480 lines exactly
			-h 720-	to 720 at most (downscale if necessary)
			-h 400+ to 400 at least (upscale if necessary)
	-hqdn3d L:C:T	set hqdn3d parameters [2:1:2]
	-id		print info on audio/subs IDs
	-n		don't overwrite output file [-y]
	-noass		don't use \"ass\" filter for subs
	-psar		preserve original SAR
	-sdir	D	external subtitles subdirectory
	-sid	X	subtitles stream selector [default|0]
	-subcp	X	assume codepage X for input subtitles [auto]
	-subss	X	force subs style X (e.g. 'fontsize=24')
	-tvol	T	set volume threshold at T dB [-0.1]
	-vc	X	use video codec X [libx264]
	-vf	F	append video filter F
	-vfpre	F	prepend video filter F
	-vid	N	select Nth video stream [0]
	-vol	A	increase volume by A dB
	-w	W	scale to width W (same semantics as -h H)
	-x264opts O	set x264 options [subme=9:ref=4:bframes=1:
			me=umh:partitions=all:no8x8dct:
			b-pyramid=strict:bluray-compat]
	-y		overwrite output file [-y]"
    exit 1
}

# check file for utf8 encoding: 0-utf8 1-other
check_fileencoding() {
    perl -ws -- - "$1" "$2" <<EOF
	use Encode qw(encode decode);
	my (\$fn, \$enc, \$thresh) = @ARGV;
	die "check_fileencoding: filename is required\\n"
	    if not defined \$fn;
	my \$bom;
	\$enc = "utf8" if not defined \$enc;
	\$thresh = 0.01 if not defined \$thresh;
	open my \$fh, "<", \$fn or die \$!;
	my (\$bad, \$total) = (0, 0);
	while (<\$fh>) {
	    if (\$total == 0 and \$enc =~ /\\Autf-?8\\z/i) {
		my \$b2 = substr(\$_, 0, 2);
		if (\$b2 eq "\\xff\\xfe") {
		    \$bom = "utf16le BOM \\"fffe\\" detected";
		} elsif (\$b2 eq "\\xfe\\xff") {
		    \$bom = "utf16be BOM \\"feff\\" detected";
		};
	    };
	    \$total += length(\$_);
	    decode(\$enc, \$_, sub {\$bad++; return "\\x{FFFD}"});
	};
	close \$fh;
	if (defined \$bom) {
	    printf "%s: %s\\n", \$fn, \$bom;
	    exit 1;
	};
	if (\$bad / \$total < \$thresh) {
	    if (\$bad) {
		printf "%s: %i bad char%s (%.2f%%), assuming %s\\n",
		    \$fn, \$bad, ((\$bad > 1) ? "s" : ""),
		    \$bad * 100 / \$total, \$enc;
	    };
	    exit 0;
	} else {
	    exit 1;
	};
EOF
    return $?
}

# Prepend missing [Event] and Format headers in broken ASS streams:
prepend_missing_event_and_format() {
    perl -ws -- - "$1" "$2" <<'EOF'
open my $infh, "<", $ARGV[0] or die $!;
my $outfh;
if (not open $outfh, ">", $ARGV[1]) {
    my $err = $!;
    close $infh;
    die $err;
};

my $section = "";
my $sectlines = 0;
my $lastevfmt;

while (<$infh>) {
    if (/\A[\r\n]*\z/) {
	$section = "";
	$sectlines = -1;
    } elsif (/\A\s*\[\s*(.*\S)\s*\]\s*\z/) {
	$section = lc($1);
	$sectlines = -1;
    } elsif ($section eq "events" and $sectlines == 0
    and /\A\s*format\s*:/i) {
	$lastevfmt = $_;
    } elsif ($section eq "" and $sectlines == 0
    and /\A\s*(comment|dialog(:?ue)?)\s*:/i) {
	print {$outfh} "[Events]\n";
	$section = "events";
	if (defined $lastevfmt) {
	    print {$outfh} $lastevfmt;
	} else {
	    print {$outfh} "Format: Layer, Start, End, Style, Name, "
		."MarginL, MarginR, MarginV, Effect, Text\n";
	};
    };
    $sectlines++;
    print {$outfh} $_;
};

close $outfh;
close $infh;
EOF
    return $?
}


SCRIPT_BNAME="${0##*/}"
SCRIPT_BNAME_S="`perl -wsle \
   '$ARGV[0] =~ s/[^A-Za-z0-9_.-]/_/g; print $ARGV[0]' \
   -- "$SCRIPT_BNAME"`"
TMPF="/tmp/${SCRIPT_BNAME_S}.$$"
TMP_OUT="${TMPF}.out"
TMP_PASS=""	; # temporary file for 2- or 3-pass encoding
TMP_SUBS=""	; # temporary file or symlink for subtitles

die() {
    rm -rf "${TMPF}".*
    E=1
    if [ 0 -lt $# ] && expr "z$1" : 'z[0-9][0-9]*$' >/dev/null ; then
	E="$1"
	shift
    fi
    if [ 0 -lt $# ] ; then
	echo "ERROR:" "$@" 1>&2
    fi
    exit "$E"
}

eint() {
    rm -rf "${TMPF}".*
    # revert to default INT handler and resend INT to self:
    trap - INT
    kill -INT $$
}
trap eint INT

# video/subtitles params:
VID="0:v:0"
OUTVC=""	; # user forced output video codec
HQDN3D="2:1:2"	; # parameters for hqdn3d filter
X264OPTS="subme=9:ref=4:bframes=1:me=umh:partitions=all:no8x8dct"
X264OPTS="$X264OPTS:b-pyramid=strict:bluray-compat"
SID=""		; # subtitles stream id
SIDX=""		; # subtitles stream selector expression
SIDTYPE=""	; # subtitles type: "ass" or "srt"
SUBCP=""	; # subtitles codepage
SDIR=""		; # external subtitles subdirectory
SUBSS=""	; # forced subtitles style
SUBS_FILTER=""	; # "ass" "or subtitles"
VF_SUBS=""	; # "subtitles"/"ass" video filter with params
SCALEW=""
SCALEH=""
NORMALIZE_SAR=1
VF_SCALE=""
VF_OTHER=""	; # other video filters to append
VFPRE_OTHER=""	; # other video filters to prepend
PIXFMT=""
EMBEDDED_FONTS=1 ; # use embedded fonts
# audio params:
OUTAC=""	; # user forced output audio codec
AID=""		; # audio stream id
AIDX=""		; # audio stream selector expression
ARATE=""
ASD="0.3"	; # asyncts min_delta [0.3s]. You need to increase it
		  # if you get messages like "[Parsed_asyncts_0 @
		  # 0x1719be0] Non-monotonous timestamps, dropping
		  # whole buffer." XXX
ALANG=""	; # output audio language tag
ADD_VOL=""	; # additional audio volume
THRESH_VOL="-0.1" ; # volume threshold for autoincrease
AF_VOL=""	; # "volume" audio filter
AF_OTHER=""	; # other audio filters to append
AFPRE_OTHER=""	; # other audio filters to prepend
# other params:
ANALYZEDURATION="-analyzeduration 9223370000000000000"
		  # analyzeduration: [0 - 9.22337e+18]
PROBESIZE="-probesize 9223370000000000000"
		  # probesize: [32 - 9.22337e+18]
ID_MODE=""	; # "identify AIDs/SIDs" mode (-id)
OVWR_OUT="-y"	; # "overwrite output file" option
ARG_CNT=0	; # arguments counter
CUR_OPT="none"	; # current option
# in/out/tail argument groups:
GRPC=0		; # argument groups counter
ARGC=0		; # group arguments counter
INC=0		; # input groups counter
OUTC=0		; # output groups counter
TGRPN=""	; # tail group number
# video/audio/subs streams:
VIDC=0		; # video streams counter
AIDC=0		; # audio streams counter
SIDC=0		; # subtitles streams counter
FIDC=0		; # embedded/attached fonts counter

incr() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    eval "$1=\"\`expr 1 + \"\$$1\"\`\""
}

next_grp() {
    eval "G${GRPC}TYP=\"\$1\""
    eval "G${GRPC}ARGC=\"\$ARGC\""
    incr GRPC
    ARGC=0
}

add_in_file() {
    fname="$1"
    bname="${fname##*/}"
    dir="${fname%/*}"
    if [ "z$dir" = "z$fname" ] ; then
	dir="."
    fi
    dir="$dir/"
    if ! [ -e "$fname" ] ; then
	die "$fname doesn't exist"
    fi
    if ! [ -f "$fname" ] && ! [ -l "$fname" ] ; then
	die "$fname isn't a file or symlink"
    fi
    if ! [ -d "$dir" ] ; then
	die "$dir isn't a dir"
    fi
    eval "IN${INC}GRP=\"\$GRPC\""
    eval "IN${INC}=\"\$fname\""
    eval "IN${INC}BNAME=\"\$bname\""
    eval "IN${INC}DIR=\"\$dir\""
    next_grp "IN${INC}"
    incr INC
    TGRPN=""
}

add_out_file() {
    case "$1" in
	*/)
	    if [ "z$INC" = "z0" ] ; then
		die "at least one input file name required"\
		    "to generate output file name in $1"
	    fi
	    last_in="`expr \( "$INC" \) - 1`"
	    eval "in_bname=\"\$IN{$last_in}BNAME\""
	    # XXX: assume matroska (.mkv) format for the output file:
	    fname="$1${in_bname%.*}.mkv"
	    ;;
	*)  fname="$1" ;;
    esac
    dir="${fname%/*}"
    if [ "z$dir" = "z$fname" ] ; then
	dir="."
    fi
    dir="$dir/"
    if ! [ -d "$dir" ] ; then
	die "$dir isn't a dir"
    fi
    eval "OUT${OUTC}GRP=\"\$GRPC\""
    eval "OUT${OUTC}=\"\$fname\""
    case "$fname" in
	*.[mM][pP]4)
	    #eval "OUT${OUTC}AC=\"libfaac\""
	    eval "OUT${OUTC}AC=\"aac\""
	    eval "OUT${OUTC}VC=\"libx264\""
	    eval "OUT${OUTC}MUX=\"mp4\""
	    ;;
	*.[wW][eE][bB][mM])
	    eval "OUT${OUTC}AC=\"libvorbis\""
	    eval "OUT${OUTC}VC=\"vp8\""
	    eval "OUT${OUTC}MUX=\"webm\""
	    ;;
	*.[mM][kK][vV]|*)
	    eval "OUT${OUTC}AC=\"libvorbis\""
	    eval "OUT${OUTC}VC=\"libx264\""
	    eval "OUT${OUTC}MUX=\"matroska\""
	    ;;
    esac
    if [ "z$OUTAC" != "z" ] ; then
	eval "OUT${OUTC}AC=\"\$OUTAC\""
    fi
    if [ "z$OUTVC" != "z" ] ; then
	eval "OUT${OUTC}VC=\"\$OUTVC\""
    fi
    next_grp "OUT${OUTC}"
    incr OUTC
    TGRPN=""
}

append_grp2cmd() {
    if ! expr "z$1" : 'z[0-9][0-9]*$' >/dev/null ; then
	die "invalid group number - $1"
    fi
    if ! expr "z$2" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $2"
    fi
    eval "agrpargc=\"\$G${1}ARGC\""
    aj=0
    while [ "$aj" -lt "$agrpargc" ] ; do
	eval "$2=\"\$$2 \\\"\\\$G${1}A$aj\\\"\""
	incr aj
    done
    if [ "z$3" = "zfull" ] ; then
	eval "agrptyp=\"\$G${1}TYP\""
	case "$agrptyp" in
	    IN*)  eval "$2=\"\$$2 -i \\\"\\\$$agrptyp\\\"\"" ;;
	    OUT*) eval "$2=\"\$$2 \\\"\\\$$agrptyp\\\"\"" ;;
	esac
    fi
}

append_ins2cmd() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    ai=0
    while [ "$ai" -lt "$INC" ] ; do
	eval "$1=\"\$$1 -i \\\"\\\$IN$ai\\\"\""
	incr ai
    done
}

append_ingrps2cmd() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    ai=0
    while [ "$ai" -lt "$INC" ] ; do
	eval "ag=\"\$IN${ai}GRP\""
	append_grp2cmd "$ag" "$1" "full"
	incr ai
    done
}

append_tgrp2cmd() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    if [ "z$TGRPN" != "z" ] ; then
	append_grp2cmd "$TGRPN" "$1"
    fi
}

# parse_stream_id AID 0:1
parse_stream_id() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    fre='\([0-9][0-9]*:\)\{0,1\}'		; # optional file id
    hre='\([0-9][0-9]*\|0x[0-9a-fA-F]\{1,\}\)'	; # dec/hex
    wre='[A-Za-z_][A-Za-z_0-9]*'		; # word
    if [ "z$A" = "znone" ] ; then
	# none
	eval "$1=\"\$2\""
    elif expr "z$A" : 'z[0-9][0-9]*:[0-9][0-9]*$' \
    >/dev/null ; then
	# 0:0
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre[avs]\\(:[0-9][0-9]*\\)\\{0,1\\}\$" \
    >/dev/null ; then
	# 1:v:1, a:2, 2:s, a
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre[p]\\(:[0-9][0-9]*\\)\\{1,2\\}\$" \
    >/dev/null ; then
	# 3:p:1:3, p:2:4, 4:p:3, p:4
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre\\(#\\|i:\\):$hre\$" \
    >/dev/null ; then
	# #0x1100, i:0x1101, #231, i:232, 5:#0x1102, 6:i:0x1103,
	# 7:#234, 8:i:235
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre[m]:$wre\\(:.*\\)\\{0,1\\}\$" \
    >/dev/null ; then
	# m:LANGUAGE:jpn, 9:m:LANGUAGE:rus, m:ENCODER, 10:m:ENCODER
	eval "$1=\"\$2\""
    else
	# 0, rus, !default, 5:rus!default & so on
	eval "${1}X=\"\$2\""
    fi
}

bc2() {
    bc <<EOF
$1
$2
EOF
}

# closest_std WH SZ CONSTR MAXDIFF R
#
# WH		indicates W or H ("w", "width", "h", "height")
# SZ		original size (e.g. "701")
# CONSTR	std size constraint (e.g. "720-", "700+", "")
# MAXDIFF	max diff between orig SZ and std size (e.g. "16")
# R		round to R pixels if std size is not found
#
# return	closest standard width/height found conforming to the
#		given CONSTR & MAXDIFF, or SZ rounded to R
closest_std() {
    # Minimum diff so far:
    _m=""
    # Closest std size so far:
    _c=""
    while read _f _s; do
	# Skip empty/invalid sizes:
	case "$_s" in [1-9]*x[1-9]*);; *) continue;; esac
	# Strip xH suffix or Wx prefix
	case "$1" in
	w|W|width)  _s="${_s%x*}";;
	h|H|height) _s="${_s#*x}";;
	esac
	# Skip std sizes not fitting into constraint:
	case "$3" in
	*-) if [ "$_s" -gt "${3%[+-]}" ]; then continue; fi;;
	*+) if [ "$_s" -lt "${3%[+-]}" ]; then continue; fi;;
	esac
	# Get diff:
	_d="`expr "$_s" - "$2"`"
	# Compare abs(_d) with abs(_m):
	if [ "z$_m" = "z" ] || [ "${_d#-}" -lt "${_m#-}" ]; then
	    _m="$_d"
	    _c="$_s"
	fi
    done <<EOF
ntsc	720x480
pal	720x576
qntsc	352x240
qpal	352x288
sntsc	640x480
spal	768x576
film	352x240
ntsc-film	352x240
sqcif	128x96
qcif	176x144
cif	352x288
4cif	704x576
16cif	1408x1152
qqvga	160x120
qvga	320x240
vga	640x480
svga	800x600
xga	1024x768
uxga	1600x1200
qxga	2048x1536
sxga	1280x1024
qsxga	2560x2048
hsxga	5120x4096
wvga	852x480
wxga	1366x768
wsxga	1600x1024
wuxga	1920x1200
woxga	2560x1600
wqsxga	3200x2048
wquxga	3840x2400
whsxga	6400x4096
whuxga	7680x4800
cga	320x200
ega	640x350
hd480	852x480
hd720	1280x720
hd1080	1920x1080
2k	2048x1080
2kflat	1998x1080
2kscope	2048x858
4k	4096x2160
4kflat	3996x2160
4kscope	4096x1716
nhd	640x360
hqvga	240x160
wqvga	400x240
fwqvga	432x240
hvga	480x320
qhd	960x540
2kdci	2048x1080
4kdci	4096x2160
uhd2160	3840x2160
uhd4320	7680x4320
-	720x400
EOF
    if [ "z$_m" != "z" ] && [ "${_m#-}" -gt "$4" ] ; then
	_c=""
    fi
    case "z$_c" in z)
	# Set _c as SZ rounded to multiple of R:
	_c=`bc2 "scale=0" "$2 / $5 * $5"`
	# Check rounding against CONSTR and add ±R if needed:
	case "$3" in
	*-) if [ "$_c" -gt "${3%-}" ]; then
		_c=`expr "$_c" - "$5"`
	    fi;;
	*+) if [ "$_c" -lt "${3%+}" ]; then
		_c=`expr "$_c" + "$5"`
	    fi;;
	esac
    esac
    printf %s "$_c"
    unset _c _m _s _f
}

parse_args() {
    while [ 0 -lt $# ] ; do
	A="$1"
	shift
	case "$CUR_OPT" in
	    -ac)
		OUTAC="$A"
		CUR_OPT="none"
		;;
	    -af)
		AF_OTHER="$AF_OTHER,$A"
		CUR_OPT="none"
		;;
	    -afpre)
		AFPRE_OTHER="$AFPRE_OTHER$A,"
		CUR_OPT="none"
		;;
	    -aid)
		parse_stream_id AID "$A"
		CUR_OPT="none"
		;;
	    -alang)
		ALANG="$A"
		CUR_OPT="none"
		;;
	    -arate)
		ARATE="$A:"
		CUR_OPT="none"
		;;
	    -asd)
		ASD="$A"
		CUR_OPT="none"
		;;
	    -h)
		if ! expr "z$A" : 'z[0-9][0-9]*[+-]\?$' \
			>/dev/null ; then
		    die "invalid height $A"
		fi
		SCALEH="$A"
		CUR_OPT="none"
		;;
	    -hqdn3d)
		if expr "z$A" : \
		    'z[0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*$' \
		    >/dev/null ; then
		    HQDN3D="$A"
		else
		    die "invalid -hqdn3d $A"
		fi
		CUR_OPT="none"
		;;
	    -pix_fmt)
		PIXFMT="$A"
		CUR_OPT="none"
		;;
	    -sid)
		parse_stream_id SID "$A"
		CUR_OPT="none"
		;;
	    -subcp)
		SUBCP="$A"
		CUR_OPT="none"
		;;
	    -subsd|-sdir)
		SDIR="$A"
		CUR_OPT="none"
		;;
	    -subss)
		SUBSS="$A"
		# XXX: when -subss contains commas or colons,
		# it must be enclosed in single quotes:
		case "$SUBSS" in
		    \'*) ;;	#XXX'
		    *[:,]*) SUBSS="'$SUBSS'" ;;
		esac
		CUR_OPT="none"
		;;
	    -tvol)
		THRESH_VOL="$A"
		CUR_OPT="none"
		;;
	    -vc)
		OUTVC="$A"
		CUR_OPT="none"
		;;
	    -vf)
		VF_OTHER="$VF_OTHER,$A"
		CUR_OPT="none"
		;;
	    -vfpre)
		VFPRE_OTHER="$VFPRE_OTHER$A,"
		CUR_OPT="none"
		;;
	    -vid)
		case "$A" in
		    *:v:*|*:\#*:*|none) VID="$A" ;;
		    *:*:*) die "invalid -vid $A" ;;
		    \#*:*) VID="0:$A" ;;
		    *) VID="0:v:$A" ;;
		esac
		CUR_OPT="none"
		;;
	    -vol)
		ADD_VOL="$A"
		CUR_OPT="none"
		;;
	    -w)
		if ! expr "z$A" : 'z[0-9][0-9]*[+-]\?$' \
			>/dev/null ; then
		    die "invalid width $A"
		fi
		SCALEW="$A"
		CUR_OPT="none"
		;;
	    -x264opts)
		X264OPTS="$A"
		CUR_OPT="none"
		;;
	    -*)
		case "$CUR_OPT" in
		    -b:v)
			# use 2pass encoding when desired
			# bitrate is known
			TMP_PASS="${TMPF}.pass"
			;;
		    -crf)
			# don't use 2pass encoding with -crf
			TMP_PASS=""
			;;
		esac
		case "$CUR_OPT" in
		    -i) add_in_file "$A" ;;
		    *)  eval "G${GRPC}A${ARGC}=\"\$CUR_OPT\""
			incr ARGC
			eval "G${GRPC}A${ARGC}=\"\$A\""
			incr ARGC
			;;
		esac
		CUR_OPT="none"
		;;
	    none)
		case "$A" in
		    -id)
			ID_MODE="1"
			;;
		    -n) OVWR_OUT="-n" ;;
		    -noass)
			SUBS_FILTER="subtitles"
			;;
		    -psar)
			NORMALIZE_SAR=0
			;;
		    -y) OVWR_OUT="-y" ;;
		    -fix_sub_duration)
			eval "G${GRPC}A${ARGC}=\"\$A\""
			incr ARGC
			;;
		    -*)
			CUR_OPT="$A"
			;;
		    *)
			CUR_OPT="none"
			case $ARG_CNT in
			    0)
				add_in_file "$A"
				ARG_CNT="1"
				;;
			    1)
				add_out_file "$A"
				ARG_CNT="2"
				;;
			    *)
				usage "${0##*/}"
				;;
			esac
			;;
		esac
		;;
	esac
    done
    if [ "z$ARGC" != "z0" ] ; then
	TGRPN="$GRPC"
	next_grp "tail"
    fi
    if [ "z$ID_MODE" = "z1" ] ; then
	if [ "z$IN0" = "" ] ; then
	    usage "${0##*/}"
	fi
    else
	if [ "z$ARG_CNT" != "z2" ] ; then
	    usage "${0##*/}"
	fi
    fi
}

# Read data with leading whitespace:
readw() {
    readw_ifs0="$IFS"
    IFS="
"
    read "$@"
    readw_ret="$?"
    IFS="$readw_ifs0"
    return "$readw_ret"
}

# Match stream vs selector:
match() {
    match="$2"
    matchtype=':'
    while [ "z$match" != "z" ] ; do
	matchtail="${match#*[:!]}"
	matchhead="${match%%[:!]*}"
	if [ "z$matchhead" != "z" ] ; then
	    if expr "z$matchhead" : 'z[0-9][0-9]*$' >/dev/null ; then
		matchno="$matchhead"
	    else
		case "$1" in
		    *"$matchhead"*) matchres=':';;
		    *) matchres='!';;
		esac
		if [ "z$matchres" != "z$matchtype" ] ; then
		    return 1
		fi
	    fi
	fi
	# set type of match for the next iteration:
	if [ "z$matchhead" = "z${match%%!*}" ] ; then
	    matchtype='!'
	else
	    matchtype=':'
	fi
	if [ "z$matchtail" = "z$match" ] ; then
	    match=""
	else
	    match="$matchtail"
	fi
    done
    return 0
}

# Run ffmpeg commandline (first argument) with stderr/stdout redirected
# to the filename passed as 2nd argument. If ffmpeg fails, send its
# logged output to stderr and die().
run_ffmpeg() {
    case "$3" in
	[012]|"") ;;
	[34]|*) echo "$1";;
    esac
    case "$3" in
	[01]) ;;
	""|[234]|*) eval "echo $1";;
    esac
    if [ "z$2" != "z" ] ; then
	case "$3" in
	    [0123]|"") eval "$1 </dev/null >\"\$2\" 2>&1";;
	    [4]|*) eval "$1 </dev/null 2>&1 | tee \"\$2\"";;
	esac
    else
	case "$3" in
	    [0123]|"") eval "$1 </dev/null >/dev/null 2>&1";;
	    [4]|*) eval "$1 </dev/null";;
	esac
    fi
    E="$?"
    if [ "z$E" != "z0" ] ; then
	case "$3" in
	    0)
		# XXX: ignore ffmpeg errors when verbosity is 0
		;;
	    [123]|"")
		if [ "z$2" != "z" ] ; then
		    cat "$2" 1>&2
		fi
		die "$E"
		;;
	    [4]|*) die "$E";;
	esac
    fi
}

ifs0="$IFS"
IFS=":"
for f in bc cat cp expr ffmpeg find grep iconv mkdir mv perl pwd rm \
    sed sort tee ; do
    x=0
    for p in $PATH ; do
	if [ -x "$p/$f" ] ; then
	    x=1
	fi
    done
    if [ "z$x" = "z0" ] ; then
	die "'$f' not found"
    fi
done
IFS="$ifs0"
parse_args "$@"

# Detect internal & external stream IDs:
if [ "z$AID" != "znone" ] || [ "z$SID" != "znone" ] \
	|| [ "z$VID" != "znone" ] || [ "z$ID_MODE" = "z1" ] \
	|| [ "z$EMBEDDED_FONTS" = "z1" ]; then
    # Detect internal video/audio/subtitles stream IDs:
    ffmpeg="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
    append_ins2cmd ffmpeg
    # This will fail with "At least one output file must be specified",
    # but produce nice listing of all input streams:
    run_ffmpeg "$ffmpeg" "$TMP_OUT" 0
    state=""
    while readw L ; do
	# Stream #0:1(rus): Audio: aac (HE-AAC), 44100 Hz, 5.1,
	# fltp (default)
	#
	# Stream #0:1[0x1100]: Audio: pcm_bluray (HDMV / 0x564D4448),
	# 48000 Hz, stereo, s16, 1536 kb/s
	#
	# Stream #0:1: Audio: mp3 (U[0][0][0] / 0x0055), 48000 Hz,
	# stereo, s16p, 160 kb/s
	# Metadata:
	#   title           : Suzaku
	case "z$L" in
	    "z    Stream #"*": Video: "*);&
	    "z  Stream #"*": Video: "*)
		state="Video"
		;;
	    "z    Stream #"*": Audio: "*);&
	    "z  Stream #"*": Audio: "*)
		state="Audio"
		;;
	    "z    Stream #"*": Subtitle: "*);&
	    "z  Stream #"*": Subtitle: "*)
		state="Subtitle"
		;;
	    "z    Stream #"*": Attachment: "*);&
	    "z  Stream #"*": Attachment: "*)
		state="Attachment"
		;;
	    "z    Stream #"*": Data: "*);&
	    "z  Stream #"*": Data: "*)
		state="Data"
		;;
	    "z    Metadata:");&
	    "z  Metadata:")
		if ! expr "z$state" : 'z[AVSF]ID[0-9][0-9]*DESC$' \
		    >/dev/null ; then
		    state="meta"
		    unset desc
		    unset id
		fi
		;;
	    "z      "????????????????": "*)
		if expr "z$state" : 'z[AVSF]ID[0-9][0-9]*DESC$' \
		    >/dev/null ; then
		    key="${L%%:*}"
		    val="${L#*: }"
		    i=0
		    while [ "$i" -lt 22 ] ; do
			key="${key% }"
			key="${key# }"
			incr i
		    done
		    # E.g. if state=VID0DESC, key:val will be appended
		    # to VID0DESC:
		    eval "$state=\"\$$state, \$key:\$val\""
		    case "$key" in
			filename)
			    eval "${state%DESC}FNAME=\"\$val\""
			    ;;
		    esac
		    unset key
		    unset val
		fi
		;;
	    *)  state=""
		unset desc
		unset id
		;;
	esac
	case "$state" in
	    Video|Audio|Subtitle|Attachment)
		case "z$L" in
		    "z    S"*)desc="${L#    Stream #}";;
		    "z  S"*)  desc="${L#  Stream #}";;
		esac
		# idx is extended id, with (lang) and [hex] suffixes
		# if present:
		idx="${desc%%: $state: *}"
		desc="${desc#*: $state: }"
		# id is plain input_no:stream_no id:
		id="${idx%%(*}"
		id="${id%%\[*}"
		if ! expr "z$id" : 'z[0-9][0-9]*:[0-9][0-9]*$' \
			>/dev/null ; then
		    die "invalid input stream <$id> in '$L'"
		fi
		# input no:
		input_no="${id%:*}"
		# stream no:
		stream_no="${id#*:}"
		eval "bname=\"\$IN${input_no}BNAME\""
		;;
	esac
	case "$state" in
	    Video)
		eval "I${input_no}N${stream_no}=\"VID$VIDC\""
		eval "VID$VIDC=\"\$id\""
		eval "VID${VIDC}DESC=\"\$bname, int.stream#\$idx," \
		    "\$desc\""
		unset idx
		case "$desc" in *" (default)") VIDDEF="$VIDC" ;; esac
		state="VID${VIDC}DESC"
		incr VIDC
		;;
	    Audio)
		eval "I${input_no}N${stream_no}=\"AID$AIDC\""
		eval "AID$AIDC=\"\$id\""
		eval "AID${AIDC}DESC=\"\$bname, int.stream#\$idx," \
		    "\$desc\""
		unset idx
		case "$desc" in *" (default)") AIDDEF="$AIDC" ;; esac
		state="AID${AIDC}DESC"
		incr AIDC
		;;
	    Subtitle)
		eval "I${input_no}N${stream_no}=\"SID$SIDC\""
		eval "SID$SIDC=\"\$id\""
		case "$desc" in
		    ass[,\ ]*|ass)
			eval "SID${SIDC}TYPE=\"ass\"";;
		    subrip[,\ ]*|subrip)
			desc="srt${desc#subrip}"
			eval "SID${SIDC}TYPE=\"srt\"";;
		esac
		case "$desc" in *" (default)") SIDDEF="$SIDC" ;; esac
		eval "SID${SIDC}DESC=\"\$bname, int.stream#\$idx," \
		    "\$desc\""
		unset idx
		state="SID${SIDC}DESC"
		incr SIDC
		;;
	    Attachment)
		case "$desc" in
		    [ot]tf)
			eval "I${input_no}N${stream_no}=\"FID$FIDC\""
			eval "FID$FIDC=\"\$id\""
			eval "FID${FIDC}TYPE=\"\$desc\""
			eval "FID${FIDC}DESC=\"\$bname," \
			    "int.stream#\$idx, \$desc\""
			state="FID${FIDC}DESC"
			# Append $FIDC to list of fids of the
			# corresponding INPUT file:
			eval "fids=\"\$IN${input_no}FIDS\""
			if [ "z$fids" != "z" ] ; then
			    fids="$fids "
			fi
			fids="${fids}$FIDC"
			eval "IN${input_no}FIDS=\"\$fids\""
			unset fids
			incr FIDC
			;;
		esac
		unset idx
		;;
	esac
    done <"$TMP_OUT"

    # Find external audio/subtitles streams:
    i=0
    inxc="$INC"	; # input + ext files counter
    while [ "$i" -lt "$INC" ] ; do
	eval "ibname=\"\$IN${i}BNAME\""
	eval "idir=\"\$IN${i}DIR\""
	if [ "z$ADIR" != "z" ] ; then
	    # XXX: run "find" for audio files only once for ADIR:
	    if [ "z$i" = "z0" ] ; then
		adir="$ADIR"
	    else
		adir=""
	    fi
	else
	    adir="$idir"
	fi
	if [ "z$SDIR" != "z" ] ; then
	    # XXX: run "find" for subtitle files only once for SDIR:
	    if [ "z$i" = "z0" ] ; then
		sdir="$SDIR"
	    else
		sdir=""
	    fi
	else
	    sdir="$idir"
	fi
	# Create search pattern for find ... -name ... Note: when the
	# old-style `` substitution is used, \$, \` and \\ sequences
	# _are_ expanded before subshell is forked to execute the
	# command:
	find_prefix="`perl -wse \
	    '$ARGV[0] =~ s/([]*?[])/\\\\$1/g; print $ARGV[0]' \
	    -- "${ibname%.*}"`"
	# Look for .flac, .mka, .mp3 & .ogg files:
	if [ "z$adir" != "z" ] ; then
	    find "$adir" -name "$find_prefix*.flac" \
		-o -name "$find_prefix*.FLAC" \
		-o -name "$find_prefix*.mka" \
		-o -name "$find_prefix*.MKA" \
		-o -name "$find_prefix*.mp3" \
		-o -name "$find_prefix*.MP3" \
		-o -name "$find_prefix*.ogg" \
		-o -name "$find_prefix*.OGG" | sort >"$TMP_OUT"
	    while readw f ; do
		if [ -f "$f" ] || [ -h "$f" ] ; then
		    # store audio file info in AIDxx/AIDxxDESC
		    # variables:
		    eval "AID$AIDC=\"\$inxc:0\""
		    eval "AID${AIDC}DESC=\"\$f, ext.stream#\$inxc:0\""
		    eval "AID${AIDC}EXTF=\"\$f\""
		    incr AIDC
		    incr inxc
		fi
	    done <"$TMP_OUT"
	fi
	# Look for .ass and .srt files:
	if [ "z$sdir" != "z" ] ; then
	    find "$sdir" -name "$find_prefix*.ass" \
		-o -name "$find_prefix*.ASS" \
		-o -name "$find_prefix*.ssa" \
		-o -name "$find_prefix*.SSA" \
		-o -name "$find_prefix*.srt" \
		-o -name "$find_prefix*.SRT" | sort >"$TMP_OUT"
	    while readw f ; do
		if [ -f "$f" ] || [ -h "$f" ] ; then
		    # store .ass/.srt file name in SUBSxx variable:
		    case "$f" in
			*.ass|*.ASS|*.ssa|*.SSA) typ="ass";;
			*.srt|*.SRT) typ="srt";;
		    esac
		    if [ "z$typ" != "z" ] ; then
			eval "SID${SIDC}TYPE=\"\$typ\""
			t=", $typ"
		    else
			t=""
		    fi
		    eval "SID$SIDC=\"\$inxc:0\""
		    eval "SID${SIDC}DESC=\"\$f," \
			"ext.stream#\$inxc:0\$t\""
		    eval "SID${SIDC}EXTF=\"\$f\""
		    incr SIDC
		    incr inxc
		fi
	    done <"$TMP_OUT"
	fi
	incr i
    done
fi

# Find AID by AIDX/ALANG or select it by default:
aidm=""		; # matching aid
aidmc=0		; # count of matching aids
matchno=""	; # selected index in array of matching aids
if [ "z$AIDX" != "z" ] ; then
    aidx="$AIDX"
elif [ "z$ALANG" != "z" ] ; then
    aidx="($ALANG)"
else
    aidx=""
fi
if [ "z$AID" = "z" ] ; then
    if [ "z$aidx" != "z" ] ; then
	i=0
	while [ "$i" -lt "$AIDC" ] ; do
	    eval "desc=\"\$AID${i}DESC\""
	    if match "$desc" "$aidx" ; then
		eval "aidm$aidmc=$i"
		incr aidmc
	    fi
	    incr i
	done
	if [ 0 -lt "$aidmc" ] ; then
	    if [ "z$matchno" = "z" ] ; then
		# XXX: it's possible to add all matching streams to
		# output file, but ATM we select only the 1st one:
		matchno=0
	    fi
	    if [ "$matchno" -lt 0 ] ; then
		matchno="`expr "$aidmc" + "$matchno"`"
	    fi
	    if [ 0 -le "$matchno" ] \
		&& [ "$matchno" -lt "$aidmc" ] ; then
		eval "aidm=\"\$aidm$matchno\""
	    fi
	fi
    elif [ "$AIDC" -gt 0 ] ; then
	# Select default AID or AID0 if no -aid was given on cmdline
	# and there is at least one AID stream there:
	if [ "z$AIDDEF" != "z" ] ; then
	    aidm="$AIDDEF"
	else
	    aidm=0
	fi
    fi
    # Convert aidm to AID:
    if [ "z$aidm" != "z" ] ; then
	eval "AID=\"\$AID$aidm\""
	eval "AIDEXTF=\"\$AID${aidm}EXTF\""
	if [ "z$AIDEXTF" != "z" ] ; then
	    # add external file to list of inputs and
	    # re-calculate resulting AID:
	    AID="$INC:${AID#*:}"
	    add_in_file "$AIDEXTF"
	fi
    fi
fi
# Print all AIDs:
if [ "z$AID" != "znone" ] || [ "z$ID_MODE" = "z1" ] ; then
    i=0
    while [ "$i" -lt "$AIDC" ] ; do
	eval "desc=\"\$AID${i}DESC\""
	eval "id=\"\$AID$i\""
	if [ "z$aidm" = "z$i" ] ; then
	    mark=" *"
	else
	    mark=""
	fi
	echo "aid#$i: $desc$mark"
	incr i
    done
fi
# Abort if requested AID has not been found:
if [ "z$AID" = "z" ] && [ "z$aidx" != "z" ] ; then
    if [ "z$ID_MODE" != "z1" ] ; then
	die "\"$aidx\" audio stream not found"
    else
	echo "WARNING: \"$aidx\" audio stream not found" 1>&2
    fi
fi

# Find SID by SIDX or select it by default:
sidm=""		; # matching sid
sidmc=0		; # count of matching sids
matchno=""	; # selected index in array of matching sids
if [ "z$SID" = "z" ] ; then
    if [ "z$SIDX" != "z" ] ; then
	i=0
	while [ "$i" -lt "$SIDC" ] ; do
	    eval "desc=\"\$SID${i}DESC\""
	    if match "$desc" "$SIDX" ; then
		eval "sidm$sidmc=$i"
		incr sidmc
	    fi
	    incr i
	done
	if [ 0 -lt "$sidmc" ] ; then
	    if [ "z$matchno" = "z" ] ; then
		matchno=0
	    fi
	    if [ "$matchno" -lt 0 ] ; then
		matchno="`expr "$sidmc" + "$matchno"`"
	    fi
	    if [ 0 -le "$matchno" ] \
		&& [ "$matchno" -lt "$sidmc" ] ; then
		eval "sidm=\"\$sidm$matchno\""
	    fi
	fi
    elif [ "$SIDC" -gt 0 ] ; then
	# Select default SID or SID0 if no -sid was given on cmdline
	# and there is at least one SID stream there:
	if [ "z$SIDDEF" != "z" ] ; then
	    sidm="$SIDDEF"
	else
	    sidm=0
	fi
    fi
    # Convert sidm to SID:
    if [ "z$sidm" != "z" ] ; then
	eval "SID=\"\$SID$sidm\""
	eval "SIDEXTF=\"\$SID${sidm}EXTF\""
	eval "SIDTYPE=\"\$SID${sidm}TYPE\""
    fi
fi
# Print all SIDs:
if [ "z$SID" != "znone" ] || [ "z$ID_MODE" = "z1" ] ; then
    i=0
    while [ "$i" -lt "$SIDC" ] ; do
	eval "desc=\"\$SID${i}DESC\""
	eval "id=\"\$SID$i\""
	if [ "z$sidm" = "z$i" ] ; then
	    mark=" *"
	else
	    mark=""
	fi
	echo "sid#$i: $desc$mark"
	incr i
    done
fi
# Abort if requested SID has not been found:
if [ "z$SID" = "z" ] && [ "z$SIDX" != "z" ] ; then
    if [ "z$ID_MODE" != "z1" ] ; then
	die "\"$SIDX\" subtitles stream not found"
    else
	echo "WARNING: \"$SIDX\" subtitles stream not found" 1>&2
    fi
fi

# Extract/recode SID and setup SID filter:
if [ "z$SID" != "z" ] && [ "z$SID" != "znone" ] ; then
    # Extract/copy subtitles to TMP_SUBS:
    if [ "z$SIDEXTF" != "z" ] ; then
	if [ "z$SIDTYPE" = "z" ] ; then
	    die "unknown subs type for $SIDEXTF"
	fi
	TMP_SUBS="${TMPF}.$SIDTYPE"
	rm -f "$TMP_SUBS"
	cp "$SIDEXTF" "$TMP_SUBS"
	E="$?" ; if [ "z$E" != "z0" ] ; then die "$E" ; fi
    else
	# Extract subtitles to tmp file:
	ffmpeg="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
	append_ingrps2cmd ffmpeg
	ffmpeg="$ffmpeg -map_metadata -1 -map_chapters -1"
	ffmpeg="$ffmpeg -an -vn -map \"\$SID\" -c:s copy"
	if [ "z$SIDTYPE" = "z" ] ; then
	    # XXX: extract SID to temporary mkv file, detect type of
	    # its 1st subtitles stream and extract again to temporary
	    # .ass or .srt file:
	    TMP_MKV="${TMPF}.mkv"
	    ffmpeg1="$ffmpeg -y \"\$TMP_MKV\""
	    append_tgrp2cmd ffmpeg1
	    run_ffmpeg "$ffmpeg1" "$TMP_OUT" 1
	    state=""
	    while readw L ; do
		case "$state$L" in
		    "Output #0,"*)
			state="o"
			;;
		    "o    Stream #0:0"*": Subtitle: ass"*);&
		    "o  Stream #0:0"*": Subtitle: ass"*)
			SIDTYPE="ass"
			break
			;;
		    "o    Stream #0:0"*": Subtitle: subrip"*);&
		    "o  Stream #0:0"*": Subtitle: subrip"*)
			SIDTYPE="srt"
			break
			;;
		esac
	    done <"$TMP_OUT"
	    if [ "z$SIDTYPE" = "z" ] ; then
		die "unknown subs type for $SID"
	    fi
	    TMP_SUBS="${TMPF}.$SIDTYPE"
	    ffmpeg2="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
	    ffmpeg2="$ffmpeg2 -i \"\$TMP_MKV\""
	    ffmpeg2="$ffmpeg2 -map_metadata -1 -map_chapters -1"
	    ffmpeg2="$ffmpeg2 -an -vn -map 0:0 -c:s copy"
	    ffmpeg2="$ffmpeg2 -y \"\$TMP_SUBS\""
	    append_tgrp2cmd ffmpeg2
	    run_ffmpeg "$ffmpeg2" "$TMP_OUT" 1
	    if ! rm -f "$TMP_MKV" ; then
		die "cannot remove $TMP_MKV"
	    fi
	else
	    TMP_SUBS="${TMPF}.$SIDTYPE"
	    ffmpeg="$ffmpeg -y \"\$TMP_SUBS\""
	    append_tgrp2cmd ffmpeg
	    run_ffmpeg "$ffmpeg" "$TMP_OUT" 1
	fi
    fi
    if ! [ -f "$TMP_SUBS" ] ; then
	die "Cannot extract/copy to $TMP_SUBS"
    fi
    if [ "z$SUBS_FILTER" = "z" ] ; then
	case "$SIDTYPE" in
	    ass)   SUBS_FILTER="ass";;
	    srt|*) SUBS_FILTER="subtitles";;
	esac
    fi
    # Detect subs encoding unless SUBCP has been explicitly specified
    # on cmdline:
    if [ "z$SUBCP" != "z" ] ; then
	subcp="$SUBCP"
    else
	if check_fileencoding "$TMP_SUBS" utf8 ; then
	    subcp="utf-8"
	elif iconv -f utf-16 -t utf-8 <"$TMP_SUBS" \
	>/dev/null 2>&1 ; then
	    subcp="utf-16"
	elif iconv -f cp1251 -t utf-8 <"$TMP_SUBS" \
	>/dev/null 2>&1 ; then
	    subcp="cp1251"
	else
	    die "unknown encoding for subs $SID"
	fi
    fi
    # XXX: "ass" filter doesn't take charenc= option and sometimes srt
    # decoder fails with the next message:
    #   [srt @ 0x141b160] Unable to recode subtitle event "..." from
    #   utf-16 to UTF-8
    # Therefore we explicitly pass .ass/.srt files through iconv before
    # rendering subs:
    if [ "z$SUBS_FILTER" = "zass" ] \
    || [ "z$SUBS_FILTER" = "zsubtitles" ] ; then
	case $subcp in
	    utf-8|UTF-8|utf8|UTF8)
		echo "file $TMP_SUBS" \
		    "is already in $subcp"
		subcp=""
		;;
	    ?*)
		echo "recoding $TMP_SUBS" \
		    "from $subcp to utf-8"
		if [ "z$SUBCP" != "z" ] ; then
		    # force conversion:
		    iconv -f "$subcp" -t "utf-8" -c \
			<"$TMP_SUBS" >"$TMP_OUT"
		    mv "$TMP_OUT" "$TMP_SUBS"
		else
		    # attempt conversion:
		    if iconv -f "$subcp" -t "utf-8" \
		    <"$TMP_SUBS" >"$TMP_OUT" \
		    && mv "$TMP_OUT" "$TMP_SUBS" ; then
			true
		    else
			die "recoding $TMP_SUBS" \
			    "from $subcp to utf-8 failed"
		    fi
		fi
		subcp=""
		;;
	esac
    fi
    # convert to UNIX line endings:
    if perl -p -wse 's/\r*\n/\n/g' <"$TMP_SUBS" >"$TMP_OUT" \
    && mv "$TMP_OUT" "$TMP_SUBS" ; then
	true
    else
	die "converting $TMP_SUBS" \
	    "to UNIX line endings failed"
    fi
    if [ "z$SIDTYPE" = "zass" ] ; then
	if prepend_missing_event_and_format "$TMP_SUBS" "$TMP_OUT" \
	&& mv "$TMP_OUT" "$TMP_SUBS" ; then
	    true
	else
	    die "prepending missing [Event] and Format" \
		"in $TMP_SUBS failed"
	fi
    fi
    if [ "z$subcp" != "z" ] ; then
	subcp=":charenc=${subcp}"
    fi
    if [ "z$SUBSS" != "z" ] ; then
	# XXX: "ass" filter doesn't accept force_style
	# option, therefore we fallback to "subtitles":
	SUBS_FILTER="subtitles"
	SUBSS=":force_style=${SUBSS}"
    fi
    VF_SUBS=",$SUBS_FILTER=${TMP_SUBS}${subcp}${SUBSS}"
fi

# Extract embedded fonts:
if [ "z$EMBEDDED_FONTS" = "z1" ] && [ 0 -lt "$FIDC" ] ; then
    rm -rf "${TMPF}.fonts"
    rm -f "${TMPF}.fontcfg"
    mkdir "${TMPF}.fonts" || exit "$?"
    # Generate custom font config:
    cat >"${TMPF}.fontcfg" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
	<dir>${TMPF}.fonts</dir>
	<include ignore_missing="yes">/etc/fonts/fonts.conf</include>
</fontconfig>
EOF
    # Set and export FONTCONFIG_FILE variable in order
    # for libfontconfig to pick up the custom cfgfile:
    FONTCONFIG_FILE="${TMPF}.fontcfg"
    export FONTCONFIG_FILE
    # Extract all fonts in single run with multiple -dump_attachment
    # parameters per each input file and with multiple input files:
    ffmpeg="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
    i=0
    while [ "$i" -lt "$INC" ] ; do
	eval "fids=\"\$IN${i}FIDS\""
	if [ "z$fids" != "z" ] ; then
	    for j in $fids ; do
		# Append -dump_attachment parameter:
		eval "id=\"\$FID${j}\""
		ffmpeg="$ffmpeg -dump_attachment:${id#*:}"
		# Append attachment file name:
		eval "fname=\"\$FID${j}FNAME\""
		fname="${fname#**/}"
		if [ "z$fname" = "z" ] ; then
		    fname="foo.ttf"
		fi
		fname="${TMPF}.fonts/$id-$fname"
		eval "FID${j}F=\"\$fname\""
		ffmpeg="$ffmpeg \"\$FID${j}F\""
	    done
	fi
	ffmpeg="$ffmpeg -i \"\$IN${i}\""
	incr i
    done
    run_ffmpeg "$ffmpeg" "$TMP_OUT" 0
fi

# Detect VID stream size (WxH) and decide whether we need to do
# scaling:
if [ "z$VID" != "znone" ] ; then
    # Copy 0 seconds of the selected video stream ($VID)
    # from set of input files (IN GRP) to /dev/null,
    # and parse ffmpeg's output to find dimensions of
    # output video stream:
    ffmpeg="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
    append_ingrps2cmd ffmpeg
    ffmpeg="$ffmpeg -an -dn -sn"
    if [ "z$VID" != "z" ] ; then
	ffmpeg="$ffmpeg -map \"\$VID\""
    fi
    ffmpeg="$ffmpeg -c copy -t 0 -f matroska -y /dev/null"
    run_ffmpeg "$ffmpeg" "$TMP_OUT" 0

    # Stream mapping:
    #   Stream #1:0 -> #0:0 (copy)
    state=""
    while readw L ; do
	case "$state$L" in
	    "Stream mapping:"*) state="m";;
	    "m    Stream #"*:*" -> #"*:*);&
	    "m  Stream #"*:*" -> #"*:*)
		# id0 is input_no:istream_no
		id0="${L#*\#}"
		id0="${id0% -> \#*}"
		# id1 is output_no:ostream_no
		id1="${L#* -> \#}"
		id1="${id1%% *}"
		if ! expr "z$id0" : 'z[0-9][0-9]*:[0-9][0-9]*$' \
			>/dev/null ; then
		    die "invalid input stream <$id0> in '$L'"
		fi
		if ! expr "z$id1" : 'z[0-9][0-9]*:[0-9][0-9]*$' \
			>/dev/null ; then
		    die "invalid output stream <$id1> in '$L'"
		fi
		# input no:
		input_no="${id0%:*}"
		# stream no:
		istream_no="${id0#*:}"
		unset id0
		unset id1
		break
		;;
	    *) state="";;
	esac
    done <"$TMP_OUT"
    unset state
    case "${input_no}x$istream_no" in
	?*x?*);; # OK
	*)
	    cat "$TMP_OUT" 1>&2
	    die "unknown output video stream";;
    esac

    # Get stream name, aka VID0, SID1, AID0 etc:
    eval "sname=\"\$I${input_no}N${istream_no}\""
    case "$sname" in
	VID[0-9]*);; # OK
	*) die "#${input_no}:${istream_no} is not VIDx ($sname)";;
    esac
    unset input_no
    unset istream_no
    # Get stream description:
    eval "desc=\"\$${sname}DESC\""
    mark=""

    # Get WxH:
    sz_re='[1-9][0-9]{1,5}x[1-9][0-9]{1,5}'
    sz="`printf %s "$desc" | \
	sed -nr "s/^.*[, ]($sz_re)[, ].*\$/\\1/p"`"
    unset sz_re
    if [ "z$sz" == "z" ] ; then
	die "unknown WxH dimensions for video stream"
    fi
    W="${sz%x*}"
    H="${sz#*x}"
    unset sz
    # Get SAR:
    sar_re='[1-9][0-9]{0,5}:[1-9][0-9]{0,5}'
    sar="`printf %s "$desc" | \
	sed -nr "s/^.*[, []SAR ($sar_re)[], ].*\$/\\1/p"`"
    unset sar_re
    case "z$sar" in z) sar="1:1";; esac
    SARW="${sar%:*}"
    SARH="${sar#*:}"
    unset sar

    # Generate VF_SCALE filter string from SCALEW/SCALEH:
    scale=0
    W2="$W"
    H2="$H"
    aw=""
    ah=""
    # Normalize SAR first:
    if [ "z$NORMALIZE_SAR" = "z1" ] ; then
	# For example, 720x480 [SAR 8:9 DAR 4:3] video gets its H
	# upscaled to 720x540 on screen, because SARH (9) is greater
	# than SARW (8): H2=480*SARH/SARH=480*9/8=540
	if [ "$SARH" -gt "$SARW" ] ; then
	    H2="`bc2 "scale=0" "$H*$SARH/$SARW"`"
	    scale=1
	elif [ "$SARW" -gt "$SARH" ] ; then
	    W2="`bc2 "scale=0" "$W*$SARW/$SARH"`"
	    scale=1
	fi
	# P.S. `bc2 scale=0` means round to integer.
	aw="*$SARW"
	ah="*$SARH"
    fi
    case "${SCALEW}x${SCALEH}" in
    *[0-9]x*[0-9])
	W2="$SCALEW"
	H2="$SCALEH"
	# XXX: assume that scaling to fixed WxH also means setsar=sar=1
	NORMALIZE_SAR=1
	scale=1
	;;
    *[0-9]x*)
	H2="`bc2 "scale=0" "${SCALEW%[+-]}*$H$ah/($W$aw)"`"
	W2="$SCALEW"
	scale=1
	;;
    *x*[0-9])
	W2="`bc2 "scale=0" "${SCALEH%[+-]}*$W$aw/($H$ah)"`"
	H2="$SCALEH"
	scale=1
	;;
    x)	# no scaling needed
	;;
    *x*)
	case "z$SCALEW" in
	z*+)
	    if [ "$W2" -lt "${SCALEW%[+-]}" ] ; then
		H2="`bc2 "scale=0" "${SCALEW%[+-]}*$H$ah/($W$aw)"`"
		W2="${SCALEW%[+-]}"
		scale=1
	    fi
	    ;;
	z*-)
	    if [ "$W2" -gt "${SCALEW%[+-]}" ] ; then
		H2="`bc2 "scale=0" "${SCALEW%[+-]}*$H$ah/($W$aw)"`"
		W2="${SCALEW%[+-]}"
		scale=1
	    fi
	    ;;
	esac
	case "z$SCALEH" in
	z*+)
	    if [ "$H2" -lt "${SCALEH%[+-]}" ] ; then
		W2="`bc2 "scale=0" "${SCALEH%[+-]}*$W$aw/($H$ah)"`"
		H2="${SCALEH%[+-]}"
		scale=1
	    fi
	    ;;
	z*-)
	    if [ "$H2" -gt "${SCALEH%[+-]}" ] ; then
		W2="`bc2 "scale=0" "${SCALEH%[+-]}*$W$aw/($H$ah)"`"
		H2="${SCALEH%[+-]}"
		scale=1
	    fi
	    ;;
	esac
	;;
    esac
    unset aw ah

    # Check new W2xH2 against -w/-h constraints:
    if [ "z$scale" = "z1" ] ; then
	# Check if W2 fits -w:
	case "z$SCALEW" in
	z*+)
	    if [ "$W2" -lt "${SCALEW%[+-]}" ] ; then
		die "Can't scale ${W}x$H [SAR $SARW:$SARH]" \
			"=> $SCALEW x $SCALEH"
	    fi
	    ;;
	z*-)
	    if [ "$W2" -gt "${SCALEW%[+-]}" ] ; then
		die "Can't scale ${W}x$H [SAR $SARW:$SARH]" \
			"=> $SCALEW x $SCALEH"
	    fi
	    ;;
	esac
	# Check if H2 fits -h:
	case "z$SCALEH" in
	z*+)
	    if [ "$H2" -lt "${SCALEH%[+-]}" ] ; then
		die "Can't scale ${W}x$H [SAR $SARW:$SARH]" \
			"=> $SCALEW x $SCALEH"
	    fi
	    ;;
	z*-)
	    if [ "$H2" -gt "${SCALEH%[+-]}" ] ; then
		die "Can't scale ${W}x$H [SAR $SARW:$SARH]" \
			"=> $SCALEW x $SCALEH"
	    fi
	    ;;
	esac
    fi

    if [ "z$scale" = "z1" ] ; then
	# Round W2/H2 to nearest standard width/height if difference
	# is less than 8, otherwize round to 2 pixels.
	#
	# If -w doesn't set fixed width, round it:
	case "z$SCALEW" in z*[+-]|z)
	    W2="`closest_std width "$W2" "$SCALEW" 8 2`";;
	esac
	# If -h doesn't set fixed height, round it:
	case "z$SCALEH" in z*[+-]|z)
	    H2="`closest_std height "$H2" "$SCALEH" 8 2`";;
	esac

	# Append 'scale' and 'setsar' filters:
	VF_SCALE=",scale=h=$H2:w=$W2"
	mark="$mark ${W2}x$H2"
	if [ "z$NORMALIZE_SAR" = "z1" ] ; then
	    VF_SCALE="$VF_SCALE,setsar=sar=1"
	    mark="$mark [SAR 1:1]"
	#else
	#    VF_SCALE="$VF_SCALE,setsar=sar=$SARW/$SARH"
	fi
    fi

    unset W2 H2 SARW SARH scale W H

    # Ad-hoc fixes for 24000/1001, 30000/1001 & 60000/1001 rates:
    case "z,$VFPRE_OTHER$VF_OTHER" in
    z*,fps=*)
	# there's already an fps filter present, no action needed
	;;
    z*)
	case "z$desc" in
	z*[,\ ]"23.98 fps"[,\ ]*)
	    VF_OTHER="$VF_OTHER,fps=fps=24000/1001"
	    mark="$mark 24000/1001"
	    ;;
	z*[,\ ]"29.97 fps"[,\ ]*)
	    VF_OTHER="$VF_OTHER,fps=fps=30000/1001"
	    mark="$mark 30000/1001"
	    ;;
	z*[,\ ]"59.94 fps"[,\ ]*)
	    VF_OTHER="$VF_OTHER,fps=fps=60000/1001"
	    mark="$mark 60000/1001"
	    ;;
	esac
	;;
    esac

    # Mimic listing of AIDs/SIDs:
    case "z$mark" in z)mark=" *";; z?*)mark=" =>$mark";; esac
    echo "${sname/VID/vid\#}: $desc$mark"
    unset sname desc mark
fi
rm -f "$TMP_OUT"

if [ "z$ID_MODE" = "z1" ] ; then
    rm -rf "${TMPF}".*
    exit 0
fi

# The async=4000 (4000 samples) parameter to aresample filter is
# necessary to enable sound stretching/squeezing to match video
# timestamps. Otherwize the resulting video will more often than not
# have audible "clicks" every several seconds.
aresample="aresample=\${ARATE}osf=fltp:ochl=downmix:async=4000"
aresample="$aresample:min_comp=0.05"
#XXX:?#aresample="$aresample:min_comp=0.01:min_hard_comp=\${ASD}"
#XXX:?#aresample="$aresample:max_soft_comp=0.2"
#XXX:obsolete#asyncts="asyncts=min_delta=\${ASD}"

# Detect max volume and raise it if THRESH_VOL is set:
if [ "z$ADD_VOL" = "z" ] && [ "z$THRESH_VOL" != "z" ] \
	&& [ "z$THRESH_VOL" != "znone" ] \
	&& [ "z$AID" != "znone" ] ; then
    ffmpeg="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
    append_ingrps2cmd ffmpeg
    teelog="2>&1 | tee \"\$TMP_OUT\""
    ffmpeg="$ffmpeg -map_metadata -1 -map_chapters -1 -sn -vn -dn"
    ffmpeg="$ffmpeg -map \"\$AID\" -c:a \"\$OUT0AC\""
    ffmpeg="$ffmpeg -af \"\${AFPRE_OTHER}$aresample"
    ffmpeg="$ffmpeg,volumedetect\${AF_OTHER}\""
    append_grp2cmd "$OUT0GRP" ffmpeg
    ffmpeg="$ffmpeg -f \"\$OUT0MUX\" -y /dev/null"
    append_tgrp2cmd ffmpeg
    run_ffmpeg "$ffmpeg" "$TMP_OUT" 4
    MAX_VOL=""
    # [Parsed_volumedetect_1 @ 0xc92960] max_volume: -1.4 dB
    MAX_VOL="`sed -nr \
	's/^.* max_volume: *(-?)([0-9]+)(\.([0-9]+))?.*$/\1\2.\4/p' \
	<"$TMP_OUT"`"
    if [ "z$MAX_VOL" != "z" ] && [ "z1" = "z`bc <<EOF
	$MAX_VOL < $THRESH_VOL
EOF`" ] ; then
	ADD_VOL="`bc <<EOF
	-0.1 - $MAX_VOL
EOF`"
    fi
    # XXX : check for "asyncts dropping whole buffer" messages:
    if grep "asyncts.*drop.*whole buffer" "$TMP_OUT" >/dev/null ; then
	die "asyncts drops buffers, increase min_delay"
    fi
    # XXX : check for "[output stream 0:0 @ 0x7cbc80] 100 buffers queued
    # in output stream 0:0, something may be wrong." messages:
    if grep "something may be wrong" "$TMP_OUT" >/dev/null ; then
	die "something may be wrong"
    fi
fi
if [ "z$ADD_VOL" != "z" ] ; then
    case "$ADD_VOL" in
	[+-]*) add_vol="$ADD_VOL";;
	*)     add_vol="+$ADD_VOL";;
    esac
    add_vol="${add_vol%[dD][bB]}dB"
    AF_VOL=",volume=volume=$add_vol"
fi
rm -f "$TMP_OUT"

ffmpeg="ffmpeg -hide_banner $ANALYZEDURATION $PROBESIZE"
append_ingrps2cmd ffmpeg
ffmpeg="$ffmpeg -map_metadata -1"
ffmpeg="$ffmpeg -map_chapters -1"
ffmpeg="$ffmpeg -dn"
ffmpeg="$ffmpeg -filter_complex \"[$VID]\${VFPRE_OTHER}hqdn3d=\${HQDN3D}"
ffmpeg="$ffmpeg\${VF_SCALE}\${VF_SUBS}\${VF_OTHER}\""
ffmpeg="$ffmpeg -c:v \"\$OUT0VC\""
if [ "z$OUT0VC" = "zlibx264" ] && [ "z$X264OPTS" != "z" ] ; then
    ffmpeg="$ffmpeg -x264opts \"\$X264OPTS\""
fi
if [ "z$AID" != "znone" ] ; then
    ffmpeg="$ffmpeg -map \"\$AID\""
    ffmpeg="$ffmpeg -c:a \"\$OUT0AC\""
    ffmpeg="$ffmpeg -ac 2"
    ffmpeg="$ffmpeg -af \"\${AFPRE_OTHER}$aresample"
    ffmpeg="$ffmpeg\${AF_VOL}\${AF_OTHER}\""
    if [ "z$ALANG" != "z" ] ; then
	ffmpeg="$ffmpeg -metadata:s:a \"language=\$ALANG\""
    fi
fi
if [ "z$PIXFMT" != "z" ] ; then
    ffmpeg="$ffmpeg -pix_fmt \"\$PIXFMT\""
fi

if [ "z$TMP_PASS" = "z" ] ; then
    append_grp2cmd "$OUT0GRP" ffmpeg
    ffmpeg="$ffmpeg $OVWR_OUT \"\$OUT0\""
    append_tgrp2cmd ffmpeg
    run_ffmpeg "$ffmpeg" "" 4
else
    ffmpeg1="$ffmpeg -pass 1 -passlogfile \"\$TMP_PASS\""
    append_grp2cmd "$OUT0GRP" ffmpeg1
    ffmpeg1="$ffmpeg1 $OVWR_OUT \"\$OUT0\""
    ffmpeg2="$ffmpeg -pass 2 -passlogfile \"\$TMP_PASS\""
    append_grp2cmd "$OUT0GRP" ffmpeg2
    ffmpeg2="$ffmpeg2 -y \"\$OUT0\""
    append_tgrp2cmd ffmpeg1
    append_tgrp2cmd ffmpeg2
    run_ffmpeg "$ffmpeg1" "" 4
    run_ffmpeg "$ffmpeg2" "" 4
fi

if [ "z$TMP_PASS" != "z" ] ; then
    rm -f "$TMP_PASS"*
fi
if [ "z$TMP_SUBS" != "z" ] ; then
    rm -f "$TMP_SUBS"
fi
if [ "z$EMBEDDED_FONTS" = "z1" ] && [ 0 -lt "$FIDC" ] ; then
    rm -rf "${TMPF}.fonts"
    rm -f "${TMPF}.fontcfg"
fi

# vi:set sw=4 noet ts=8 tw=71:
